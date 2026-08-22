import Foundation

/// A single tool call as emitted by a model. Mirrors OpenAI's `tool_calls`
/// element shape so the rest of the pipeline can stay format-agnostic.
public struct ParsedToolCall: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    /// JSON-encoded arguments string. The OpenAI wire format mandates
    /// `arguments` is a string of JSON; downstream consumers re-parse.
    public let arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// Parser protocol for model-family tool-call conventions. v0.8 ships
/// Llama / Qwen (XML `<tool_call>`) + GLM (XML `<arg_key>`); other
/// families land as separate conforming types. The contract is:
///
/// - Input is the model's raw text output.
/// - Output is the list of parsed tool calls + the cleaned visible text
///   (control markup stripped). Returns `[]` + original text on no-match.
public protocol ToolCallParser: Sendable {
    /// Stable identifier used in logs and for tool-call chunk attribution.
    var familyName: String { get }
    func parse(text: String) -> ToolCallParseResult
}

public struct ToolCallParseResult: Sendable, Equatable {
    public let visibleText: String
    public let toolCalls: [ParsedToolCall]

    public init(visibleText: String, toolCalls: [ParsedToolCall]) {
        self.visibleText = visibleText
        self.toolCalls = toolCalls
    }

    public static let empty = ToolCallParseResult(visibleText: "", toolCalls: [])

    public var isEmpty: Bool { toolCalls.isEmpty }
}

/// Shared XML `<tool_call>` parser used by Qwen (Qwen2/3), Llama-style
/// variants, GLM-4.x, and similar families that emit control markup in
/// two flavours:
///
/// - `<tool_call><function=name><parameter=k>v</parameter></function></tool_call>`
/// - `<tool_call>{...json...}</tool_call>`
///
/// The parser scans for `<tool_call>` / `</tool_call>` pairs and tries
/// the XML form first; on failure it parses the inner text as JSON.
public struct XmlToolCallParser: ToolCallParser {
    public let familyName: String
    private let startTag = "<tool_call>"
    private let endTag = "</tool_call>"

    public init(familyName: String = "xml") {
        self.familyName = familyName
    }

    public func parse(text: String) -> ToolCallParseResult {
        guard text.contains(startTag) else {
            return ToolCallParseResult(visibleText: text, toolCalls: [])
        }
        var calls: [ParsedToolCall] = []
        var visible = text
        var safety = 0
        while let openRange = visible.range(of: startTag),
              let closeRange = visible.range(of: endTag, range: openRange.upperBound..<visible.endIndex),
              safety < 1000 {
            safety += 1
            let inner = String(visible[openRange.upperBound..<closeRange.lowerBound])
            if let call = Self.parseInner(inner) {
                calls.append(call)
            }
            visible.replaceSubrange(openRange.lowerBound..<closeRange.upperBound, with: "")
        }
        return ToolCallParseResult(
            visibleText: visible.trimmingCharacters(in: .whitespacesAndNewlines),
            toolCalls: calls,
        )
    }


    private static func parseInner(_ inner: String) -> ParsedToolCall? {

        let trimmed = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        // JSON form first — wraps both XML and bare JSON cases.
        if trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) {
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let name = obj["name"] as? String ?? ""
                let arguments: String
                if let rawArgs = obj["arguments"] {
                    if let dict = rawArgs as? [String: Any],
                       let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) {
                        arguments = String(data: data, encoding: .utf8) ?? "{}"
                    } else if let s = rawArgs as? String {
                        arguments = s
                    } else {
                        arguments = "{}"
                    }
                } else {
                    arguments = "{}"
                }
                let id = "call_\(UUID().uuidString.prefix(8))"
                return ParsedToolCall(id: id, name: name, arguments: arguments)
            }
        }
        // XML form: <function=name><parameter=k>v</parameter>...
        if let nameStart = trimmed.range(of: "<function=") {
            let after = trimmed[nameStart.upperBound...]
            guard let gt = after.firstIndex(of: ">"), !after[..<gt].isEmpty else {
                return nil
            }
            let name = String(after[..<gt])
            let rest = String(after[after.index(after: gt)...])
            return ParsedToolCall(
                id: "call_\(UUID().uuidString.prefix(8))",
                name: name,
                arguments: Self.collectParameters(in: rest)
            )
        }
        return nil
    }

    private static func collectParameters(in xml: String) -> String {
        // Greedy collect `<parameter=k>v</parameter>` pairs and serialise
        // as a JSON object. v0.8 doesn't promise field order — downstream
        // consumers re-parse by name. Tag content between `<parameter=`
        // and the next `>` is the key; text up to the matching
        // `</parameter>` is the value.
        var dict: [String: String] = [:]
        let openTag = "<parameter="
        let closeTag = "</parameter>"
        var cursor = xml.startIndex
        while cursor < xml.endIndex,
              let open = xml.range(of: openTag, range: cursor..<xml.endIndex),
              let keyEnd = xml.range(of: ">", range: open.upperBound..<xml.endIndex),
              let close = xml.range(of: closeTag, range: keyEnd.upperBound..<xml.endIndex) {
            let key = String(xml[open.upperBound..<keyEnd.lowerBound])
            let value = String(xml[keyEnd.upperBound..<close.lowerBound])
            dict[key] = value
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
}

/// Registry that picks a parser based on the model's family / model_type.
/// v0.8 — every family routes to the generic parser; the family
/// parameter is preserved so future per-family divergence
/// (e.g. Anthropic's `cache_control` blocks) can be added without
/// changing call sites.
public enum ToolCallParserRegistry {
    public static func parser(forFamily family: String?) -> ToolCallParser {
        GenericToolCallParserRegistry.parser(forFamily: family)
    }
}