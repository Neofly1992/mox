import Foundation

/// v0.8 — single tool-call parser driven by a registry of `Envelope`
/// descriptors. Each envelope is a struct, not a type; the parser walks
/// the registry in priority order and dispatches per-envelope to a
/// small `extract` closure that knows how to turn the inner payload
/// into `[ParsedToolCall]`. Adding a new upstream model is a single
/// `Envelope` line in `EnvelopeRegistry.all`, no new type, no new
/// dispatch arm.
///
/// Envelope flavours shipped:
/// - `functionCalls`    — Qwen3.5
///                       (`<function_calls><invoke …/></function_calls>`).
/// - `pythonTag`        — Qwen2/Qwen3/DeepSeek fine-tunes
///                       (`<|python_tag|>{json}<|/python_tag|>`).
/// - `toolCall`         — generic `<tool_call>{json}</tool_call>`
///                       (Llama, GLM, Mistral, base models).
/// - `startOfTurn`      — Gemma
///                       (`<start_of_turn>tool_call\n{json}<end_of_turn>`).
/// - `bareJson`         — DeepSeek-V3/R1 tool fine-tunes that drop the
///                       markup; only matched when no other envelope fired.
public struct GenericToolCallParser: ToolCallParser {
    public let familyName: String

    public init(familyName: String = "generic") {
        self.familyName = familyName
    }

    public func parse(text: String) -> ToolCallParseResult {
        for envelope in EnvelopeRegistry.all {
            if let result = envelope.extract(text) {
                return result
            }
        }
        return ToolCallParseResult(visibleText: text, toolCalls: [])
    }
}

// MARK: - Envelope descriptor

/// Self-contained description of one tool-call envelope. The `kind`
/// is what callers see in logs; `extract` returns nil if the envelope
/// doesn't match the input text, otherwise the parsed result with
/// the envelope stripped from `visibleText`. The closure is the only
/// piece that's family-specific.
struct ToolCallEnvelope: Sendable {
    enum Kind: String, Sendable {
        case functionCalls = "function_calls"
        case pythonTag = "python_tag"
        case toolCall = "tool_call"
        case startOfTurn = "start_of_turn"
        case bareJson = "bare_json"
    }

    let kind: Kind
    /// Order in the registry determines match priority. Add new
    /// envelopes by inserting before `bareJson` (which is
    /// intentionally last as the most permissive matcher).
    let priority: Int
    /// Returns nil when the envelope doesn't apply to the input.
    let extract: @Sendable (String) -> ToolCallParseResult?
}

// MARK: - Registry

/// Table-driven envelope registry. Adding a new model family is one
/// line in `all` — the parsing code path is the same for every
/// envelope that emits a JSON `{name, arguments}` body.
enum EnvelopeRegistry {
    static let all: [ToolCallEnvelope] = [
        ToolCallEnvelope(
            kind: .functionCalls,
            priority: 0,
            extract: parseFunctionCalls
        ),
        ToolCallEnvelope(
            kind: .pythonTag,
            priority: 1,
            extract: parsePythonTag
        ),
        ToolCallEnvelope(
            kind: .toolCall,
            priority: 2,
            extract: parseGenericToolCall
        ),
        ToolCallEnvelope(
            kind: .startOfTurn,
            priority: 3,
            extract: parseStartOfTurn
        ),
        // Bare JSON is last because it has no markup to anchor on; it
        // would match any JSON in the text. Other envelopes must have
        // had a chance to claim the call first.
        ToolCallEnvelope(
            kind: .bareJson,
            priority: 99,
            extract: parseBareJson
        ),
    ]
}

// MARK: - Envelope extractors

/// `parseFunctionCalls` — Qwen3.5 envelope:
/// `<function_calls><invoke name="N"><parameter name="k">v</parameter>…</invoke>…</function_calls>`
private func parseFunctionCalls(_ text: String) -> ToolCallParseResult? {
    let openTag = "<function_calls>"
    let closeTag = "</function_calls>"
    guard let openRange = text.range(of: openTag),
          let closeRange = text.range(of: closeTag, range: openRange.upperBound..<text.endIndex)
    else { return nil }
    let inner = String(text[openRange.upperBound..<closeRange.lowerBound])
    var visible = text
    visible.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: "")
    let calls = extractInvokes(in: inner)
    return ToolCallParseResult(
        visibleText: visible.trimmingCharacters(in: .whitespacesAndNewlines),
        toolCalls: calls
    )
}

/// `parsePythonTag` — Qwen2/Qwen3/DeepSeek:
/// `<|python_tag|>{json}<|/python_tag|>`.
private func parsePythonTag(_ text: String) -> ToolCallParseResult? {
    let openToken = "<|python_tag|>"
    let closeToken = "<|/python_tag|>"
    guard let openRange = text.range(of: openToken),
          let closeRange = text.range(of: closeToken, range: openRange.upperBound..<text.endIndex)
    else { return nil }
    let inner = String(text[openRange.upperBound..<closeRange.lowerBound])
    guard let call = parseJsonCall(inner) else { return nil }
    var visible = text
    visible.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: "")
    return ToolCallParseResult(
        visibleText: visible.trimmingCharacters(in: .whitespacesAndNewlines),
        toolCalls: [call]
    )
}

/// `parseGenericToolCall` — Llama/GLM/Mistral/base models:
/// `<tool_call>{json}</tool_call>` (one or more in sequence).
private func parseGenericToolCall(_ text: String) -> ToolCallParseResult? {
    let openTag = "<tool_call>"
    let closeTag = "</tool_call>"
    guard text.contains(openTag) else { return nil }
    var calls: [ParsedToolCall] = []
    var visible = text
    var safety = 0
    while safety < 1000 {
        safety += 1
        guard let open = visible.range(of: openTag) else { break }
        guard let close = visible.range(of: closeTag, range: open.upperBound..<visible.endIndex) else { break }
        let inner = String(visible[open.upperBound..<close.lowerBound])
        if let call = parseJsonCall(inner) {
            calls.append(call)
        }
        visible.replaceSubrange(open.lowerBound..<close.upperBound, with: "")
    }
    return ToolCallParseResult(
        visibleText: visible.trimmingCharacters(in: .whitespacesAndNewlines),
        toolCalls: calls
    )
}

/// `parseStartOfTurn` — Gemma: `<start_of_turn>tool_call\n{json}<end_of_turn>`.
private func parseStartOfTurn(_ text: String) -> ToolCallParseResult? {
    let marker = "<start_of_turn>tool_call\n"
    let endMarker = "<end_of_turn>"
    guard text.contains(marker) else { return nil }
    var calls: [ParsedToolCall] = []
    var visible = text
    var safety = 0
    while safety < 1000 {
        safety += 1
        guard let open = visible.range(of: marker) else { break }
        let after = open.upperBound
        let close = visible.range(of: endMarker, range: after..<visible.endIndex)
            ?? visible.endIndex..<visible.endIndex
        let inner = String(visible[after..<close.lowerBound])
        if let call = parseJsonCall(inner) {
            calls.append(call)
        }
        visible.replaceSubrange(open.lowerBound..<close.lowerBound, with: "")
    }
    return ToolCallParseResult(
        visibleText: visible.trimmingCharacters(in: .whitespacesAndNewlines),
        toolCalls: calls
    )
}

/// `parseBareJson` — DeepSeek-V3/R1 tool fine-tunes that drop the
/// markup. Depth-aware scan to find the matching `}`, then JSON-parse
/// just the balanced prefix. Only matches when the object has a
/// `name` field, so ordinary JSON in the response (e.g. the model
/// explaining its reasoning) is never misclassified.
private func parseBareJson(_ text: String) -> ToolCallParseResult? {
    var cursor = text.startIndex
    while cursor < text.endIndex {
        guard let open = text.range(of: "{", range: cursor..<text.endIndex) else { return nil }
        guard let endRange = endOfObject(in: text, from: open.lowerBound) else {
            cursor = open.upperBound
            continue
        }
        let objectText = String(text[open.lowerBound..<endRange.upperBound])
        guard let data = objectText.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = obj["name"] as? String, !name.isEmpty
        else {
            cursor = open.upperBound
            continue
        }
        var visible = text
        visible.replaceSubrange(open.lowerBound..<endRange.upperBound, with: "")
        return ToolCallParseResult(
            visibleText: visible.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: [ParsedToolCall(
                id: (obj["id"] as? String) ?? "call_\(UUID().uuidString.prefix(8))",
                name: name,
                arguments: serialiseArguments(obj["arguments"])
            )]
        )
    }
    return nil
}

// MARK: - Substructure helpers

/// `<invoke name="X"><parameter name="k">v</parameter>…</invoke>` → one
/// `ParsedToolCall` per `<invoke>`.
private func extractInvokes(in xml: String) -> [ParsedToolCall] {
    let invokeOpen = "<invoke "
    let invokeClose = "</invoke>"
    var calls: [ParsedToolCall] = []
    var cursor = xml.startIndex
    while let open = xml.range(of: invokeOpen, range: cursor..<xml.endIndex),
          let attrEnd = xml.range(of: ">", range: open.upperBound..<xml.endIndex),
          let close = xml.range(of: invokeClose, range: attrEnd.upperBound..<xml.endIndex) {
        let attrSection = String(xml[open.upperBound..<attrEnd.lowerBound])
        let body = String(xml[attrEnd.upperBound..<close.lowerBound])
        if let name = parseQuotedAttribute(named: "name", in: attrSection) {
            let arguments = collectParameters(in: body)
            calls.append(ParsedToolCall(
                id: "call_\(UUID().uuidString.prefix(8))",
                name: name,
                arguments: arguments
            ))
        }
        cursor = close.upperBound
    }
    return calls
}

private func parseQuotedAttribute(named name: String, in attrs: String) -> String? {
    let marker = "\(name)="
    guard let attrStart = attrs.range(of: marker) else { return nil }
    let after = attrs[attrStart.upperBound...]
    guard let quote = after.firstIndex(where: { $0 == "\"" || $0 == "'" }) else { return nil }
    let quoteChar = after[quote]
    let rest = after[after.index(after: quote)...]
    guard let endQuote = rest.firstIndex(of: quoteChar) else { return nil }
    return String(rest[..<endQuote])
}

private func collectParameters(in body: String) -> String {
    var dict: [String: String] = [:]
    let openTag = "<parameter "
    let closeTag = "</parameter>"
    var cursor = body.startIndex
    while let open = body.range(of: openTag, range: cursor..<body.endIndex),
          let attrEnd = body.range(of: ">", range: open.upperBound..<body.endIndex),
          let close = body.range(of: closeTag, range: attrEnd.upperBound..<body.endIndex) {
        let attrSection = String(body[open.upperBound..<attrEnd.lowerBound])
        if let key = parseQuotedAttribute(named: "name", in: attrSection) {
            dict[key] = String(body[attrEnd.upperBound..<close.lowerBound])
        }
        cursor = close.upperBound
    }
    guard let data = try? JSONSerialization.data(
        withJSONObject: dict,
        options: [.sortedKeys, .withoutEscapingSlashes]
    ), let str = String(data: data, encoding: .utf8) else {
        return "{}"
    }
    return str
}

/// Parse a JSON object shaped `{name, arguments}`. Returns nil on
/// parse failure or missing/empty `name`. Used by every envelope
/// whose payload is JSON (i.e. everything except the Qwen3.5
/// `function_calls` envelope).
private func parseJsonCall(_ raw: String) -> ParsedToolCall? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{") else { return nil }
    guard let data = trimmed.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    guard let name = obj["name"] as? String, !name.isEmpty else { return nil }
    return ParsedToolCall(
        id: (obj["id"] as? String) ?? "call_\(UUID().uuidString.prefix(8))",
        name: name,
        arguments: serialiseArguments(obj["arguments"])
    )
}

private func serialiseArguments(_ raw: Any?) -> String {
    if let dict = raw as? [String: Any],
       let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
        return String(data: data, encoding: .utf8) ?? "{}"
    }
    if let s = raw as? String { return s }
    return "{}"
}

/// Depth-aware scanner. Tracks string-literal state so a `}` inside a
/// JSON string doesn't unbalance the depth count.
private func endOfObject(in text: String, from start: String.Index) -> Range<String.Index>? {
    var depth = 0
    var idx = start
    var inString = false
    var escape = false
    while idx < text.endIndex {
        let c = text[idx]
        if inString {
            if escape {
                escape = false
            } else if c == "\\" {
                escape = true
            } else if c == "\"" {
                inString = false
            }
        } else {
            if c == "\"" {
                inString = true
            } else if c == "{" {
                depth += 1
            } else if c == "}" {
                depth -= 1
                if depth == 0 {
                    return start..<text.index(after: idx)
                }
            }
        }
        idx = text.index(after: idx)
    }
    return nil
}

// MARK: - Registry shim

/// Backwards-compatible dispatch entry-point. v0.8 — every family
/// routes to the same generic parser. The per-family parameter is
/// preserved so future per-family divergence (e.g. Anthropic's
/// `cache_control` blocks) can be added without changing call sites.
public enum GenericToolCallParserRegistry {
    public static func parser(forFamily family: String?) -> ToolCallParser {
        GenericToolCallParser(familyName: family ?? "generic")
    }
}