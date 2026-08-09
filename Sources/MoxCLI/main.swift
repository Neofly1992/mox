import Foundation
import MoxCore
import MoxServer
import MoxShared

@main
struct MoxCLI {
    static func main() async throws {
        let args = CommandLine.arguments

        guard args.count > 1 else {
            printHelp()
            return
        }

        let command = args[1]

        switch command {
        case "pull":
            try await handlePull(args: Array(args[2...]))
        case "list":
            try await handleList(args: Array(args[2...]))
        case "run":
            try await handleRun(args: Array(args[2...]))
        case "delete":
            try await handleDelete(args: Array(args[2...]))
        case "chat", "-m":
            try await handleChat(args: Array(args[2...]))
        case "ask":
            do { try await handleAsk(args: Array(args[2...])) } catch let e as AskError { exit(e == .notFound ? 1 : 2) } catch { exit(1) }
        case "help", "--help", "-h":
            printHelp()
        case "version", "--version":
            print("Mox v0.1.0")
        default:
            print("Unknown command: \(command)")
            printHelp()
        }
    }

    static func printHelp() {
        print("""
        Mox - Magic Box for MLX

        Usage: mox <command> [options]

        Commands:
          pull <model>     Download a model from HuggingFace or ModelScope
          list             List all locally installed models
          run <model>      Run a model as a local API server
          chat <model>     Chat with a model (or use -m)
          ask              One-shot prompt that emits OpenAI-style JSON
          -m <prompt>      Send a single message to the model
          delete <model>   Delete a locally installed model
          help             Show this help message
          version          Show version information

        Examples:
          mox pull Qwen/Qwen2.5-0.5B-Instruct
          mox pull Qwen/Qwen2.5-0.5B-Instruct --source huggingface
          mox pull Qwen/Qwen2.5-0.5B-Instruct --source modelscope
          mox list
          mox run Qwen/Qwen2.5-0.5B-Instruct
          mox run Qwen/Qwen2.5-0.5B-Instruct --port 8080
          mox chat Qwen/Qwen2.5-0.5B-Instruct
          mox ask --model Qwen/Qwen2.5-0.5B-Instruct --messages '[{"role":"user","content":"hi"}]'
          mox ask --model Qwen/Qwen2.5-0.5B-Instruct --messages '...' --stream
          mox -m "What is 2+2?"
          mox delete Qwen/Qwen2.5-0.5B-Instruct
        """)
    }

    static func handlePull(args: [String]) async throws {
        var modelId: String?
        var source: ModelSource = .huggingface

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--source":
                i += 1
                if i < args.count {
                    let sourceStr = args[i]
                    switch sourceStr.lowercased() {
                    case "huggingface", "hf":
                        source = .huggingface
                    case "modelscope", "ms":
                        source = .modelscope
                    case "mlx-community", "mlx":
                        source = .mlxCommunity
                    default:
                        print("Unknown source: \(sourceStr)")
                        return
                    }
                }
            case "--id":
                i += 1
                if i < args.count {
                    modelId = args[i]
                }
            default:
                if modelId == nil {
                    modelId = args[i]
                }
            }
            i += 1
        }

        guard let id = modelId else {
            print("Error: Model ID required")
            print("Usage: mox pull <model-id> [--source huggingface|modelscope]")
            return
        }

        print("Pulling model: \(id) from \(source.rawValue)...")

        let modelManager = ModelManager.shared

        do {
            let progressHandler: @Sendable (DownloadProgress) -> Void = { progress in
                let percent = Int(progress.progress * 100)
                let downloaded = ByteCountFormatter.string(fromByteCount: progress.bytesDownloaded, countStyle: .file)
                let total = ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file)
                print("\rDownloading: \(percent)% (\(downloaded)/\(total))", terminator: "")
            }

            let modelInfo = try await modelManager.pullModel(id: id, source: source, progressHandler: progressHandler)
            print("\nSuccessfully pulled model: \(modelInfo.name)")
            print("Size: \(modelInfo.sizeDescription)")
            print("Location: \(modelInfo.path)")
        } catch {
            print("Error pulling model: \(error.localizedDescription)")
        }
    }

    static func handleList(args: [String]) async throws {
        let modelManager = ModelManager.shared

        do {
            let models = try await modelManager.listModels()

            if models.isEmpty {
                print("No models installed. Run 'mox pull <model>' to download a model.")
                return
            }

            print("Installed models:")
            print(String(format: "%-50s %-15s %-10s", "NAME", "SOURCE", "SIZE"))
            print(String(repeating: "-", count: 75))

            for model in models {
                let name = model.name.count > 48 ? String(model.name.prefix(45)) + "..." : model.name
                print(String(format: "%-50s %-15s %-10s", name, model.source.rawValue, model.sizeDescription))
            }
        } catch {
            print("Error listing models: \(error.localizedDescription)")
        }
    }

    static func handleRun(args: [String]) async throws {
        let config = (try? await ConfigManager.shared.load()) ?? AppConfig()
        var modelId: String?
        var port: Int = config.server.port
        var host: String = config.server.host
        var hostOverridden = false
        var portOverridden = false
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--port":
                i += 1
                if i < args.count, let p = Int(args[i]) {
                    port = p
                    portOverridden = true
                }
            case "--host":
                i += 1
                if i < args.count {
                    host = args[i]
                    hostOverridden = true
                }
            default:
                if modelId == nil {
                    modelId = args[i]
                }
            }
            i += 1
        }
        // CLI override flags are tracked so future revisions can warn when
        // they diverge from values persisted in `~/.mox/config.json`.
        _ = (hostOverridden, portOverridden)
        guard let id = modelId else {
            print("Error: Model ID required")
            print("Usage: mox run <model-id> [--port 8080]")
            return
        }

        let modelManager = ModelManager.shared

        guard let modelInfo = try? await modelManager.modelInfo(for: id) else {
            print("Model '\(id)' not found. Run 'mox pull \(id)' first.")
            return
        }

        let memoryGuard = MemoryGuard.shared
        let memoryStatus = memoryGuard.getMemoryStatus()

        print("Memory status: \(String(format: "%.1f", memoryStatus.availableGB)) GB available")

        if !memoryStatus.canAllocate {
            print("Warning: Low memory. Model may fail to load.")
        }

        print("Starting server for model: \(modelInfo.name)")
        print("API available at: http://\(host):\(port)")

        let server = MoxServer(host: host, port: port)
        try server.start()

        print("Server is running. Press Ctrl+C to stop.")

        try await Task.sleep(nanoseconds: UInt64.max)
    }

    static func handleChat(args: [String]) async throws {
        // Parse args: positional model id is required. Other flags (legacy
        // `-m <prompt>` one-shot usage) are intentionally ignored — REPL mode
        // supersedes the single-prompt form.
        var modelId: String?
        for token in args where !token.hasPrefix("-") {
            if modelId == nil {
                modelId = token
            }
            // Additional positional tokens are ignored in REPL mode.
        }

        guard let id = modelId else {
            print("Error: Model ID required")
            print("Usage: mox chat <model-id>")
            return
        }

        let modelManager = ModelManager.shared

        guard let modelInfo = try? await modelManager.modelInfo(for: id) else {
            print("Model '\(id)' not found. Run 'mox pull \(id)' first.")
            return
        }

        let runner = ModelRunner.shared

        // Banner — printed before the first prompt so the user sees model + commands.
        print("mox chat — \(modelInfo.name)")
        print("type /help for commands, /exit to quit")

        var messages: [ChatMessage] = []

        // REPL loop. readLine returns nil on EOF (Ctrl+D / closed pipe) — exit silently.
        while true {
            print("> ", terminator: "")
            guard let line = readLine(strippingNewline: true) else {
                break
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }

            switch trimmed {
            case "/exit", "/quit":
                return
            case "/clear":
                messages.removeAll()
                print("(conversation cleared)")
                continue
            case "/help":
                print("""
                Commands:
                  /exit, /quit   End the session
                  /clear         Clear conversation history
                  /help          Show this help

                Anything else is sent to the model as a user message.
                """)
                continue
            default:
                break
            }

            messages.append(ChatMessage(role: "user", content: trimmed))

            do {
                let response = try await runner.chat(
                    modelId: id,
                    messages: messages
                )

                if let content = response.choices.first?.message.content {
                    messages.append(ChatMessage(role: "assistant", content: content))
                    print("\n\(content)")
                }

                let usage = response.usage
                print("[tokens prompt=\(usage.promptTokens) completion=\(usage.completionTokens) total=\(usage.totalTokens)]")
                print("")
            } catch {
                // Pop the user message we just appended so a failed turn doesn't
                // poison subsequent context, but keep the REPL alive so the user
                // can retry or /exit.
                if !messages.isEmpty {
                    messages.removeLast()
                }
                print("Error: \(error.localizedDescription)")
                print("")
            }
        }
    }

    /// One-shot chat invocation. Designed to be spawned by MoxGUI rather than
    /// driven interactively — it reads no stdin after parsing and writes its
    /// result as a single JSON document (or, with `--stream`, one JSON document
    /// per OpenAI streaming chunk) to stdout.
    static func handleAsk(args: [String]) async throws {
        var modelId: String?
        var messagesJSON: String?
        var prompt: String?
        var stream = false
        var maxTokens: Int?
        var temperature: Double?
        var topP: Double?

        var i = 0
        while i < args.count {
            switch args[i] {
            case "--model", "-m":
                i += 1
                if i < args.count { modelId = args[i] }
            case "--messages":
                i += 1
                if i < args.count { messagesJSON = args[i] }
            case "--prompt", "-p":
                i += 1
                if i < args.count { prompt = args[i] }
            case "--stream", "-s":
                stream = true
            case "--max-tokens":
                i += 1
                if i < args.count, let v = Int(args[i]) { maxTokens = v }
            case "--temperature":
                i += 1
                if i < args.count, let v = Double(args[i]) { temperature = v }
            case "--top-p":
                i += 1
                if i < args.count, let v = Double(args[i]) { topP = v }
            default:
                break
            }
            i += 1
        }

        guard let id = modelId else {
            FileHandle.standardError.write(Data("Error: --model is required\nUsage: mox ask --model <id> [--messages <json> | --prompt <text>] [--stream]\n".utf8))
            throw AskError.usage
        }
        let messages: [ChatMessage]
        if let json = messagesJSON {
            let data = Data(json.utf8)
            do {
                messages = try JSONDecoder().decode([ChatMessage].self, from: data)
            } catch {
                FileHandle.standardError.write(Data("Error: invalid --messages JSON: \(error.localizedDescription)\n".utf8))
                throw AskError.usage
            }
        } else if let p = prompt {
            messages = [ChatMessage(role: "user", content: p)]
        } else {
            FileHandle.standardError.write(Data("Error: provide either --messages <json> or --prompt <text>\n".utf8))
            throw AskError.usage
        }

        if messages.isEmpty {
            FileHandle.standardError.write(Data("Error: message list is empty\n".utf8))
            throw AskError.usage
        }

        // Mirror the Chat REPL behaviour: confirm the model is installed before
        // trying to load it. A missing model should fail with a clear message
        // rather than a stack trace from the runner.
        if (try? await ModelManager.shared.modelInfo(for: id)) == nil {
            FileHandle.standardError.write(Data("Model '\(id)' not found. Run 'mox pull \(id)' first.\n".utf8))
            throw AskError.notFound
        }

        let runner = ModelRunner.shared
        let encoder = JSONEncoder()

        if stream {
            // OpenAI streaming responses are also single JSON objects per line;
            // the caller (HTTPAPIClient today, GUI tomorrow) decodes each line
            // and concatenates the assistant content. We emit the same shape
            // the daemon's /v1/chat/completions endpoint will emit once SSE
            // lands in MoxServer — keep the wire format aligned from day one.
            let chunk = ChatCompletionChunk(
                id: "chatcmpl-\(UUID().uuidString.prefix(8))",
                object: "chat.completion.chunk",
                created: Int64(Date().timeIntervalSince1970),
                model: id,
                choices: [
                    ChatCompletionChunk.Choice(
                        index: 0,
                        delta: ChatCompletionChunk.Delta(role: "assistant", content: ""),
                        finishReason: nil
                    )
                ]
            )
            if let data = try? encoder.encode(chunk), let line = String(data: data, encoding: .utf8) {
                print(line)
            }

            for await piece in await runner.chatStream(
                modelId: id,
                messages: messages,
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP
            ) {
                let payload = ChatCompletionChunk(
                    id: "chatcmpl-\(UUID().uuidString.prefix(8))",
                    object: "chat.completion.chunk",
                    created: Int64(Date().timeIntervalSince1970),
                    model: id,
                    choices: [
                        ChatCompletionChunk.Choice(
                            index: 0,
                            delta: ChatCompletionChunk.Delta(role: nil, content: piece),
                            finishReason: nil
                        )
                    ]
                )
                if let data = try? encoder.encode(payload), let line = String(data: data, encoding: .utf8) {
                    print(line)
                }
            }

            // Terminator chunk — finishReason "stop" with empty delta. Mirrors
            // the OpenAI stream so callers can stop without timing inference.
            let stop = ChatCompletionChunk(
                id: "chatcmpl-\(UUID().uuidString.prefix(8))",
                object: "chat.completion.chunk",
                created: Int64(Date().timeIntervalSince1970),
                model: id,
                choices: [
                    ChatCompletionChunk.Choice(
                        index: 0,
                        delta: ChatCompletionChunk.Delta(role: nil, content: ""),
                        finishReason: "stop"
                    )
                ]
            )
            if let data = try? encoder.encode(stop), let line = String(data: data, encoding: .utf8) {
                print(line)
            }
            return
        }
        do {
            let response = try await runner.chat(
                modelId: id,
                messages: messages,
                maxTokens: maxTokens,
                temperature: temperature,
                topP: topP
            )
            let data = try encoder.encode(response)
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("Error: \(error.localizedDescription)\n".utf8))
            throw error
        }
    }

    static func handleDelete(args: [String]) async throws {
        guard args.count > 0 else {
            print("Error: Model ID required")
            print("Usage: mox delete <model-id>")
            return
        }

        let modelId = args[0]
        let modelManager = ModelManager.shared

        guard let modelInfo = try? await modelManager.modelInfo(for: modelId) else {
            print("Model '\(modelId)' not found.")
            return
        }

        print("Deleting model: \(modelInfo.name)")
        print("This will remove all files from: \(modelInfo.path)")

        do {
            try await modelManager.deleteModel(id: modelId)
            print("Successfully deleted model: \(modelId)")
        } catch {
            print("Error deleting model: \(error.localizedDescription)")
        }
    }
}

/// `throw AskError(...)` works in `async throws` contexts.
private enum AskError: Error {
    case usage
    case notFound
}
