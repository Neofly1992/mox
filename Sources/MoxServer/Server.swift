import Foundation
import MoxCore
import MoxShared

public final class MoxServer: @unchecked Sendable {
    public static let shared = MoxServer()
    
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let host: String
    private let port: Int
    
    public init(host: String = "127.0.0.1", port: Int = 8080) {
        self.host = host
        self.port = port
    }
    
    public func start() throws {
        guard !isRunning else { return }
        
        serverSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw HTTPError.socketCreationFailed
        }
        
        var reuseAddr: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
        
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        
        let addrSize = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, addrSize)
            }
        }
        
        guard bindResult >= 0 else {
            throw HTTPError.bindFailed
        }
        
        guard listen(serverSocket, 10) >= 0 else {
            throw HTTPError.listenFailed
        }
        
        isRunning = true
        print("Mox server started on http://\(host):\(port)")
        
        DispatchQueue.global(qos: .userInitiated).async {
            self.runLoop()
        }
    }
    
    private func runLoop() {
        while isRunning {
            var clientAddr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }
            
            guard clientSocket >= 0 else {
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }
            
            handleClient(clientSocket: clientSocket)
        }
    }
    
    private func handleClient(clientSocket: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let bytesRead = read(clientSocket, &buffer, buffer.count)
        
        guard bytesRead > 0 else {
            close(clientSocket)
            return
        }
        
        guard let requestStr = String(data: Data(bytes: buffer, count: bytesRead), encoding: .utf8) else {
            close(clientSocket)
            return
        }
        
        let lines = requestStr.components(separatedBy: "\r\n")
        guard let firstLine = lines.first else {
            close(clientSocket)
            return
        }
        
        let parts = firstLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            close(clientSocket)
            return
        }
        
        let method = parts[0]
        let path = parts[1]
        let bodyStart = requestStr.firstRange(of: "\r\n\r\n")
        let body = bodyStart.map { String(requestStr[$0.upperBound...]) } ?? ""
        
        if path == "/health" && method == "GET" {
            sendResponse(clientSocket: clientSocket, status: 200, body: "{\"status\":\"ok\"}")
            return
        }
        
        if path == "/v1/models" && method == "GET" {
            handleListModels(clientSocket: clientSocket)
            return
        }
        
        if path == "/v1/chat/completions" && method == "POST" {
            handleChatCompletion(clientSocket: clientSocket, body: body)
            return
        }
        
        sendResponse(clientSocket: clientSocket, status: 404, body: "{\"error\":\"Not found\"}")
    }
    
    private func handleListModels(clientSocket: Int32) {
        do {
            let models = try ModelManager.shared.listModels()
            let modelList = models.map { model -> [String: Any] in
                return [
                    "id": model.id,
                    "name": model.name,
                    "source": model.source.rawValue,
                    "size": model.size
                ]
            }
            
            let response: [String: Any] = [
                "object": "list",
                "data": modelList
            ]
            
            if let jsonData = try? JSONSerialization.data(withJSONObject: response),
               let jsonStr = String(data: jsonData, encoding: .utf8) {
                sendResponse(clientSocket: clientSocket, status: 200, body: jsonStr)
            }
        } catch {
            sendResponse(clientSocket: clientSocket, status: 500, body: "{\"error\":\"\(error.localizedDescription)\"}")
        }
    }
    
    private func handleChatCompletion(clientSocket: Int32, body: String) {
        guard let data = body.data(using: .utf8),
              let chatRequest = try? JSONDecoder().decode(ChatCompletionRequest.self, from: data) else {
            sendResponse(clientSocket: clientSocket, status: 400, body: "{\"error\":\"Invalid JSON\"}")
            return
        }
        
        let runner = ModelRunner.shared
        
        Task {
            do {
                let response = try await runner.chat(
                    modelId: chatRequest.model,
                    messages: chatRequest.messages,
                    maxTokens: chatRequest.maxTokens,
                    temperature: chatRequest.temperature,
                    topP: chatRequest.topP
                )
                
                let encoder = JSONEncoder()
                if let responseData = try? encoder.encode(response),
                   let responseStr = String(data: responseData, encoding: .utf8) {
                    sendResponse(clientSocket: clientSocket, status: 200, body: responseStr)
                }
            } catch {
                sendResponse(clientSocket: clientSocket, status: 500, body: "{\"error\":\"\(error.localizedDescription)\"}")
            }
        }
    }
    
    private func sendResponse(clientSocket: Int32, status: Int, body: String) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Unknown"
        }
        
        let header = "HTTP/1.1 \(status) \(statusText)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        let fullResponse = header + body
        
        fullResponse.withCString { ptr in
            _ = write(clientSocket, ptr, strlen(ptr))
        }
        
        close(clientSocket)
    }
    
    public func stop() {
        isRunning = false
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
    }
}

public enum HTTPError: Error, LocalizedError {
    case socketCreationFailed
    case bindFailed
    case listenFailed
    
    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed: return "Failed to create socket"
        case .bindFailed: return "Failed to bind socket"
        case .listenFailed: return "Failed to listen on socket"
        }
    }
}
