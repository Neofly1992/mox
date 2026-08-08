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
          -m <prompt>      Send a single message to the model
          delete <model>  Delete a locally installed model
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
            let progressHandler: (DownloadProgress) -> Void = { progress in
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
            let models = try modelManager.listModels()
            
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
        let config = (try? ConfigManager.shared.load()) ?? AppConfig()
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
        
        guard let modelInfo = try? modelManager.modelInfo(for: id) else {
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
        var modelId: String?
        var prompt: String?
        
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--model", "-m":
                i += 1
                if i < args.count {
                    if modelId == nil {
                        modelId = args[i]
                    } else {
                        prompt = args[i]
                    }
                }
            default:
                if modelId == nil {
                    modelId = args[i]
                } else if prompt == nil {
                    prompt = args[i]
                }
            }
            i += 1
        }
        
        guard let id = modelId else {
            print("Error: Model ID required")
            print("Usage: mox chat <model-id> [-m \"prompt\"]")
            return
        }
        
        if prompt == nil {
            print("Enter your message (Ctrl+D to finish input):")
            let input = readLine()
            prompt = input
        }
        
        guard let userPrompt = prompt, !userPrompt.isEmpty else {
            print("Error: Prompt cannot be empty")
            return
        }
        
        let modelManager = ModelManager.shared
        
        guard let modelInfo = try? modelManager.modelInfo(for: id) else {
            print("Model '\(id)' not found. Run 'mox pull \(id)' first.")
            return
        }
        
        print("Loading model: \(modelInfo.name)...")
        
        let runner = ModelRunner.shared
        let messages = [ChatMessage(role: "user", content: userPrompt)]
        
        do {
            let response = try await runner.chat(
                modelId: id,
                messages: messages
            )
            
            if let content = response.choices.first?.message.content {
                print("\n\(content)")
            }
        } catch {
            print("Error: \(error.localizedDescription)")
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
        
        guard let modelInfo = try? modelManager.modelInfo(for: modelId) else {
            print("Model '\(modelId)' not found.")
            return
        }
        
        print("Deleting model: \(modelInfo.name)")
        print("This will remove all files from: \(modelInfo.path)")
        
        do {
            try modelManager.deleteModel(id: modelId)
            print("Successfully deleted model: \(modelId)")
        } catch {
            print("Error deleting model: \(error.localizedDescription)")
        }
    }
}
