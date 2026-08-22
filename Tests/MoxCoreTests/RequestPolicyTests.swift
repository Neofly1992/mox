import Foundation
import Testing
@testable import MoxShared

/// Pure-function tests for the shared request resolver. No model directory,
/// no HTTP, no actor hops — keeps the contract tiny and the failure surface
/// obvious. v0.7 contract: chat / messages / completions endpoints must yield
/// identical resolved sampler values for the same effective input, and must
/// reject the same set of malformed inputs in the same priority order.
@Suite("RequestPolicy")
struct RequestPolicyTests {

    private let overrides = ServerDefaults(
        temperature: 0.42,
        topP: 0.55,
        maxTokens: 256
    )

    @Test("Client fields win over server and product defaults")
    func clientFieldsWin() throws {
        let resolved = try RequestPolicy.resolve(ResolutionInput(
            model: "Qwen/Qwen2.5-0.5B-Instruct",
            messages: [ChatMessage(role: "user", content: "hi")],
            rawTemperature: 0.3,
            rawTopP: 0.8,
            rawMaxTokens: 64,
            rawStream: true,
            apiKey: overrides
        ))
        #expect(resolved.sampler.temperature.value == 0.3)
        #expect(resolved.sampler.temperature.source == .client)
        #expect(resolved.sampler.topP.value == 0.8)
        #expect(resolved.sampler.topP.source == .client)
        #expect(resolved.sampler.maxTokens == 64)
        #expect(resolved.sampler.stream == true)
    }

    @Test("Omitted fields fall back to server apiKey, not product")
    func serverFallbackWinsOverProduct() throws {
        let resolved = try RequestPolicy.resolve(ResolutionInput(
            model: "Qwen/Qwen2.5-0.5B-Instruct",
            messages: [ChatMessage(role: "user", content: "hi")],
            apiKey: overrides
        ))
        #expect(resolved.sampler.temperature.value == 0.42)
        #expect(resolved.sampler.temperature.source == .server)
        #expect(resolved.sampler.topP.value == 0.55)
        #expect(resolved.sampler.topP.source == .server)
        #expect(resolved.sampler.maxTokens == 256)
        #expect(resolved.sampler.stream == false)
    }

    @Test("No client value falls back to ServerDefaults (server source)")
    func apiKeyDefaultsApply() throws {
        let resolved = try RequestPolicy.resolve(ResolutionInput(
            model: "Qwen/Qwen2.5-0.5B-Instruct",
            messages: [ChatMessage(role: "user", content: "hi")]
        ))
        // Default apiKey is `.productFallback`; resolver cannot tell whether
        // the apiKey came from user config or the product fallback, so the
        // sampler source is `.server` in both cases.
        #expect(resolved.sampler.temperature.value == ServerDefaults.productFallback.temperature)
        #expect(resolved.sampler.temperature.source == .server)
        #expect(resolved.sampler.topP.value == ServerDefaults.productFallback.topP)
        #expect(resolved.sampler.topP.source == .server)
        #expect(resolved.sampler.maxTokens == ServerDefaults.productFallback.maxTokens)
    }
    @Test("Empty messages + empty prompt is rejected")
    func emptyPromptAndMessagesRejected() {
        #expect(throws: MoxError.emptyMessages) {
            _ = try RequestPolicy.resolve(ResolutionInput(
                model: "Qwen/Qwen2.5-0.5B-Instruct",
                messages: [],
                prompt: ""
            ))
        }
    }

    @Test("Prompt-only input becomes a user message")
    func promptBecomesUserMessage() throws {
        let resolved = try RequestPolicy.resolve(ResolutionInput(
            model: "Qwen/Qwen2.5-0.5B-Instruct",
            prompt: "Hello!"
        ))
        #expect(resolved.messages.count == 1)
        #expect(resolved.messages[0].role == "user")
        #expect(resolved.messages[0].content == "Hello!")
    }

    @Test("Tool entry without a name is rejected")
    func toolMissingNameRejected() {
        #expect(throws: MoxError.invalidTools(reason: "tools[0] missing required string field 'name'")) {
            _ = try RequestPolicy.resolve(ResolutionInput(
                model: "Qwen/Qwen2.5-0.5B-Instruct",
                messages: [ChatMessage(role: "user", content: "hi")],
                rawTools: [AnyCodable.object(["type": .string("function")])]
            ))
        }
    }

    @Test("Tool entry with valid name passes through")
    func toolWithNamePassesThrough() throws {
        let resolved = try RequestPolicy.resolve(ResolutionInput(
            model: "Qwen/Qwen2.5-0.5B-Instruct",
            messages: [ChatMessage(role: "user", content: "hi")],
            rawTools: [AnyCodable.object([
                "type": .string("function"),
                "name": .string("get_weather"),
            ])]
        ))
        #expect(resolved.tools.count == 1)
    }

    @Test("Non-finite temperature rejected before max_tokens")
    func nonFiniteTemperatureRejected() {
        let input = ResolutionInput(
            model: "Qwen/Qwen2.5-0.5B-Instruct",
            messages: [ChatMessage(role: "user", content: "hi")],
            rawTemperature: .nan,
            rawMaxTokens: -1
        )
        do {
            _ = try RequestPolicy.resolve(input)
            Issue.record("expected error")
        } catch let error as MoxError {
            if case .nonFiniteSampler(let field, _) = error {
                #expect(field == "temperature")
            } else {
                Issue.record("wrong error case")
            }
        } catch {
            Issue.record("wrong error type")
        }
    }

    @Test("Negative max_tokens rejected")
    func negativeMaxTokensRejected() {
        #expect(throws: MoxError.maxTokensOutOfRange(0)) {
            _ = try RequestPolicy.resolve(ResolutionInput(
                model: "Qwen/Qwen2.5-0.5B-Instruct",
                messages: [ChatMessage(role: "user", content: "hi")],
                rawMaxTokens: 0
            ))
        }
    }
    @Test("Empty model id rejected")
    func emptyModelRejected() {
        #expect(throws: MoxError.self) {
            _ = try RequestPolicy.resolve(ResolutionInput(
                model: "",
                messages: [ChatMessage(role: "user", content: "hi")]
            ))
        }
    }

    @Test("Chat / messages / completions agree on resolved sampler")
    func endpointsAgree() throws {
        let chat = try RequestPolicy.resolve(ResolutionInput(
            model: "Qwen/Qwen2.5-0.5B-Instruct",
            messages: [
                ChatMessage(role: "system", content: "You are mox."),
                ChatMessage(role: "user", content: "hi"),
            ],
            rawTemperature: 0.5,
            apiKey: overrides
        ))
        let anthropic = try RequestPolicy.resolve(ResolutionInput(
            model: "Qwen/Qwen2.5-0.5B-Instruct",
            messages: [
                ChatMessage(role: "user", content: "hi"),
            ],
            rawTemperature: 0.5,
            apiKey: overrides
        ))
        let completions = try RequestPolicy.resolve(ResolutionInput(
            model: "Qwen/Qwen2.5-0.5B-Instruct",
            prompt: "hi",
            rawTemperature: 0.5,
            apiKey: overrides
        ))
        // All three endpoints yield the same sampler when given the same
        // effective input. Chat includes a system turn but the system turn
        // doesn't influence sampler resolution.
        #expect(chat.sampler.temperature == anthropic.sampler.temperature)
        #expect(chat.sampler.topP == anthropic.sampler.topP)
        #expect(chat.sampler.maxTokens == anthropic.sampler.maxTokens)
        // And prompt-style completions resolve to the same effective sampler
        // because the prompt is wrapped into a single user message.
        #expect(anthropic.sampler.temperature == completions.sampler.temperature)
        #expect(anthropic.sampler.topP == completions.sampler.topP)
    }
}