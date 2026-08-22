import Foundation
import Testing
@testable import MoxShared

/// v0.8 — one generic parser handles every family by trying each
/// known envelope in priority order. These tests pin the parser
/// against the exact text shapes the upstream models emit, so a
/// regression in any envelope is caught by the right test fixture.
@Suite("GenericToolCallParser")
struct GenericToolCallParserTests {

    // MARK: Envelope coverage

    @Test("Qwen2/Qwen3 python_tag envelope")
    func qwen2PythonTag() {
        let result = GenericToolCallParser().parse(text: """
        Sure, calling now.<|python_tag|>{"name":"get_weather","arguments":{"location":"Tokyo"}}<|/python_tag|>
        """)
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].name == "get_weather")
        #expect(result.toolCalls[0].arguments.contains("Tokyo"))
        #expect(!result.visibleText.contains("<|"))
    }

    @Test("Generic <tool_call>{json}</tool_call> envelope (Llama/GLM/Mistral)")
    func genericEnvelope() {
        let result = GenericToolCallParser().parse(text: """
        Calling.<tool_call>{"name":"calc","arguments":{"x":2}}</tool_call>
        """)
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].name == "calc")
    }

    @Test("Qwen3.5 function_calls envelope")
    func qwen35Single() {
        let result = GenericToolCallParser().parse(text: """
        <function_calls>
        <invoke name="get_weather">
        <parameter name="location">Tokyo</parameter>
        <parameter name="unit">celsius</parameter>
        </invoke>
        </function_calls>
        """)
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].name == "get_weather")
        #expect(result.toolCalls[0].arguments.contains("Tokyo"))
        #expect(result.toolCalls[0].arguments.contains("celsius"))
    }

    @Test("Qwen3.5 multiple invokes in one envelope")
    func qwen35Multiple() {
        let result = GenericToolCallParser().parse(text: """
        <function_calls>
        <invoke name="first">
        <parameter name="x">1</parameter>
        </invoke>
        <invoke name="second">
        <parameter name="y">2</parameter>
        </invoke>
        </function_calls>
        """)
        #expect(result.toolCalls.count == 2)
        let names = Set(result.toolCalls.map(\.name))
        #expect(names == ["first", "second"])
    }

    @Test("GLM JSON inside tool_call markup")
    func glmSingle() {
        let result = GenericToolCallParser().parse(text: """
        Calling.<tool_call>{"name":"get_weather","arguments":{"location":"Paris"}}</tool_call>
        """)
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].name == "get_weather")
    }

    @Test("GLM multiple sequential tool calls")
    func glmMultiple() {
        let result = GenericToolCallParser().parse(text: """
        <tool_call>{"name":"a","arguments":{}}</tool_call><tool_call>{"name":"b","arguments":{}}</tool_call>
        """)
        #expect(result.toolCalls.count == 2)
    }

    @Test("Gemma start_of_turn envelope")
    func gemmaSingle() {
        let result = GenericToolCallParser().parse(text: """
        I'll call the function.<start_of_turn>tool_call
        {"name":"get_weather","arguments":{"location":"Berlin"}}<end_of_turn>
        """)
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].name == "get_weather")
        #expect(result.toolCalls[0].arguments.contains("Berlin"))
    }

    @Test("DeepSeek bare JSON object in plain text")
    func deepSeekBareJson() {
        let result = GenericToolCallParser().parse(text: """
        I'll call this:
        {"name":"get_time","arguments":{"zone":"UTC"}}
        And then stop.
        """)
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].name == "get_time")
        #expect(result.toolCalls[0].arguments.contains("UTC"))
        #expect(result.visibleText.contains("And then stop."))
    }

    // MARK: Robustness

    @Test("Plain text without tool markup passes through unchanged")
    func plainText() {
        let result = GenericToolCallParser().parse(text: "Hello, world!")
        #expect(result.toolCalls.isEmpty)
        #expect(result.visibleText == "Hello, world!")
    }

    @Test("Malformed envelope is dropped, no exception")
    func malformed() {
        let result = GenericToolCallParser().parse(text: "<tool_call>not closed")
        #expect(result.toolCalls.isEmpty)
        // We didn't find a closing tag, so the visible text still
        // contains the open tag — that's the conservative behaviour.
        #expect(result.visibleText.contains("<tool_call>"))
    }

    @Test("Bare JSON with no name field is not parsed as a tool call")
    func bareJsonNoName() {
        let result = GenericToolCallParser().parse(text: """
        {"foo":"bar"}
        """)
        #expect(result.toolCalls.isEmpty)
    }

    @Test("Empty arguments are encoded as {}")
    func emptyArgs() {
        let result = GenericToolCallParser().parse(text: """
        <tool_call>{"name":"noargs"}</tool_call>
        """)
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].arguments == "{}")
    }

    @Test("Tool call IDs are unique within a response")
    func uniqueIDs() {
        let result = GenericToolCallParser().parse(text: """
        <tool_call>{"name":"a"}</tool_call>
        <tool_call>{"name":"b"}</tool_call>
        """)
        let ids = result.toolCalls.map(\.id)
        #expect(Set(ids).count == 2)
    }

    // MARK: Registry

    @Test("Registry returns the generic parser for any family")
    func registryReturnsGeneric() {
        let qwen = GenericToolCallParserRegistry.parser(forFamily: "qwen3.5")
        #expect(qwen.familyName == "qwen3.5")
        let llama = GenericToolCallParserRegistry.parser(forFamily: "llama")
        #expect(llama.familyName == "llama")
        let unknown = GenericToolCallParserRegistry.parser(forFamily: nil)
        #expect(unknown.familyName == "generic")
    }
}