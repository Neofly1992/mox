import Foundation
import Testing
@testable import MoxShared

/// Wire-shape + extraction tests for the v0.8 tool-call parser family.
/// These cover the path that `/v1/chat/completions` will follow when the
/// client sends `tools`. The model emits control markup; the parser strips
/// it and emits OpenAI-shape tool_calls.
@Suite("ToolCallParser")
struct ToolCallParserTests {

    @Test("Plain text without tool markup passes through unchanged")
    func plainTextPassThrough() {
        let parser = XmlToolCallParser()
        let result = parser.parse(text: "Hello, world!")
        #expect(result.toolCalls.isEmpty)
        #expect(result.visibleText == "Hello, world!")
    }

    @Test("XML form extracts function name and parameters")
    func xmlFormExtraction() {
        let parser = XmlToolCallParser()
        let result = parser.parse(text: """
        I'll call the weather tool.

        <tool_call><function=get_weather><parameter=location>Tokyo</parameter><parameter=unit>celsius</parameter></function></tool_call>
        """)
        #expect(result.toolCalls.count == 1)
        let call = result.toolCalls[0]
        #expect(call.name == "get_weather")
        #expect(call.arguments.contains("Tokyo"))
        #expect(call.arguments.contains("celsius"))
        #expect(result.visibleText.contains("I'll call the weather tool"))
        #expect(!result.visibleText.contains("<tool_call>"))
    }

    @Test("JSON form extracts function name and arguments")
    func jsonFormExtraction() {
        let parser = XmlToolCallParser()
        let result = parser.parse(text: #"""
        Calling calculator:

        <tool_call>{"name":"add","arguments":{"a":1,"b":2}}</tool_call>
        """#)
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].name == "add")
        #expect(result.toolCalls[0].arguments.contains("\"a\":1"))
        #expect(result.toolCalls[0].arguments.contains("\"b\":2"))
    }

    @Test("Multiple tool calls in one response are all extracted")
    func multipleToolCalls() {
        let parser = XmlToolCallParser()
        let result = parser.parse(text: """
        <tool_call><function=first><parameter=x>1</parameter></function></tool_call>
        <tool_call><function=second><parameter=y>2</parameter></function></tool_call>
        """)
        #expect(result.toolCalls.count == 2)
        let names = result.toolCalls.map(\.name).sorted()
        #expect(names == ["first", "second"])
    }

    @Test("Registry returns LlamaJson for Llama family")
    func registryLlama() {
        let parser = ToolCallParserRegistry.parser(forFamily: "llama")
        #expect(parser.familyName.contains("llama"))
    }

    @Test("Registry returns generic parser for any family")
    func registryFallback() {
        let parser = ToolCallParserRegistry.parser(forFamily: "totally-unknown")
        #expect(parser.familyName == "totally-unknown")
    }

    @Test("Tool call IDs are unique within a response")
    func uniqueIDs() {
        let parser = XmlToolCallParser()
        let result = parser.parse(text: """
        <tool_call><function=a></function></tool_call>
        <tool_call><function=b></function></tool_call>
        <tool_call><function=c></function></tool_call>
        """)
        let ids = result.toolCalls.map(\.id)
        #expect(Set(ids).count == 3)
    }

    @Test("Empty arguments are encoded as {}")
    func emptyArgs() {
        let parser = XmlToolCallParser()
        let result = parser.parse(text: "<tool_call><function=noargs></function></tool_call>")
        #expect(result.toolCalls.count == 1)
        #expect(result.toolCalls[0].arguments == "{}")
    }

    @Test("Malformed markup is dropped, no exception")
    func malformedDropsSilently() {
        let parser = XmlToolCallParser()
        let result = parser.parse(text: "<tool_call>not closed")
        // No closing tag → no inner parse → no tool call emitted.
        #expect(result.toolCalls.isEmpty)
    }
}