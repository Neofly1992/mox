import ArgumentParser
import Darwin
import Foundation
import MoxBootstrap
import MoxClient
import MoxDomain
import MoxProtocol

@main struct Mox: AsyncParsableCommand {
  static func main() async {
    do {
      var command = try await asyncParseAsRoot()
      if var asynchronous = command as? any AsyncParsableCommand {
        try await asynchronous.run()
      } else {
        try command.run()
      }
    } catch {
      let code = exitCode(for: error).rawValue
      if code == ExitCode.validationFailure.rawValue {
        diagnostic(fullMessage(for: error))
        Darwin.exit(2)
      }
      exit(withError: error)
    }
  }

  static let configuration = CommandConfiguration(
    commandName: "mox", abstract: "Local MLX text inference",
    version: "\(Wire.productVersion) \(Wire.buildID) (\(BuildInfo.configuration))", subcommands: [Chat.self, Serve.self, Models.self, API.self])
}
struct Chat: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Chat with a local MLX model directory or installed model alias.")
  @Option var dataRoot: String = ServiceFiles.defaultRoot
  @Option(help: "Absolute directory of a local MLX model.") var modelPath: String?
  @Option(help: "Installed model alias or installation UUID.") var model: String?
  @Option var prompt: String?
  @Option var maxTokens: Int?
  @Option var temperature: Float?
  @Option var topP: Float?
  mutating func run() async throws {
    guard (modelPath == nil) != (model == nil) else {
      diagnostic("Specify exactly one of --model-path or --model.")
      throw ExitCode(2)
    }
    let modelReference = GenerateBody.Model(kind: model == nil ? "localDirectory" : "installedAlias",
      path: model ?? modelPath!)
    let stdinFlags = fcntl(STDIN_FILENO, F_GETFL)
    let stdoutFlags = fcntl(STDOUT_FILENO, F_GETFL)
    let stderrFlags = fcntl(STDERR_FILENO, F_GETFL)
    _ = fcntl(STDIN_FILENO, F_SETFL, stdinFlags | O_NONBLOCK)
    _ = fcntl(STDOUT_FILENO, F_SETFL, stdoutFlags | O_NONBLOCK)
    _ = fcntl(STDERR_FILENO, F_SETFL, stderrFlags | O_NONBLOCK)
    defer {
      _ = fcntl(STDIN_FILENO, F_SETFL, stdinFlags)
      _ = fcntl(STDOUT_FILENO, F_SETFL, stdoutFlags)
      _ = fcntl(STDERR_FILENO, F_SETFL, stderrFlags)
    }
    let explicit = SamplingSettings(maxTokens: maxTokens, temperature: temperature, topP: topP)
    do { try explicit.validate() } catch {
      diagnostic(String(describing: error))
      throw ExitCode(2)
    }
    guard prompt != nil || isatty(STDIN_FILENO) != 0 else {
      diagnostic("invalidParameters: non-terminal stdin requires --prompt.")
      throw ExitCode(2)
    }
    let connection: Connection
    do {
      connection = try await Connection.open(
        root: dataRoot, executable: ExecutableLocation.current())
    } catch {
      diagnostic(String(describing: error))
      throw ExitCode(1)
    }
    let effective: EffectiveSampling
    do {
      effective = try await connection.client.resolveSampling(
        .init(model: modelReference, explicit: explicit))
    } catch {
      diagnostic(String(describing: error))
      connection.worker?.requestStop()
      if let worker = connection.worker, !(await worker.wait()) { await worker.forceStop() }
      throw ExitCode(1)
    }
    diagnostic("sampling max_tokens=\(effective.maxTokens) [\(effective.maxTokensSource.rawValue)] temperature=\(effective.temperature) [\(effective.temperatureSource.rawValue)] top_p=\(effective.topP) [\(effective.topPSource.rawValue)]")
    let driver = await ChatDriver(
      client: connection.client, model: modelReference, sampling: try effective.sampling(), oneShot: prompt != nil)
    let status = await driver.run(prompt: prompt)
    connection.worker?.requestStop()
    if let worker = connection.worker, !(await worker.wait()) { await worker.forceStop() }
    throw ExitCode(status)
  }
}
func diagnostic(_ text: String) {
  // Unified Logging is authoritative. Never block inference/signals on an unread stderr pipe.
  let data = Data((text + "\n").utf8)
  _ = data.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
}

@MainActor final class ChatDriver {
  let client: ServiceClient
  let model: GenerateBody.Model
  let sampling: Sampling
  let oneShot: Bool
  var active: RemoteGeneration?
  var exiting: Int32?
  var interruptedBeforeHandle = false
  var working = false
  var sources: [DispatchSourceSignal] = []
  var input: DispatchSourceRead?
  var inputWaiter: CheckedContinuation<String?, Error>?
  var inputBuffer = Data()
  init(client: ServiceClient, model: GenerateBody.Model, sampling: Sampling, oneShot: Bool) {
    self.client = client
    self.model = model
    self.sampling = sampling
    self.oneShot = oneShot
  }
  func run(prompt: String?) async -> Int32 {
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    signal(SIGPIPE, SIG_IGN)
    for number in [SIGINT, SIGTERM] {
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { [weak self] in Task { @MainActor in self?.received(number) } }
      source.resume()
      sources.append(source)
    }
    var session = ChatSession()
    var result: Int32 = 0
    repeat {
      let text: String
      if let prompt {
        text = prompt
      } else {
        diagnostic("You> ")
        do {
          guard let line = try await readInput() else { break }
          text = line
        } catch {
          diagnostic(String(describing: error))
          result = 1
          break
        }
      }
      if exiting != nil { break }
      working = true
      interruptedBeforeHandle = false
      do {
        let request = try session.request(prompt: text, sampling: sampling)
        let handle = try client.generate(model: model, request: request)
        active = handle
        if interruptedBeforeHandle || exiting != nil { handle.cancel() }
        var reply = ""
        var finishedReason: FinishReason?
        for try await event in handle.events {
          switch event.payload {
          case .contentDelta(let delta):
            try await writeOutput(delta, handle: handle)
            reply += delta
          case .promptTokens, .toolCall, .matchedStopSequence: break
          case .phase(let phase): diagnostic("request=\(event.requestID) phase=\(phase)")
          case .usage(let usage):
            diagnostic(
              "request=\(event.requestID) prompt_tokens=\(usage.promptTokens) output_tokens=\(usage.outputTokens) prefill_s=\(usage.prefillSeconds) decode_s=\(usage.decodeSeconds)"
            )
          case .finished(let reason):
            diagnostic("request=\(event.requestID) finished=\(reason.rawValue)")
            finishedReason = reason
          case .failed(let error):
            diagnostic("request=\(event.requestID) \(error)")
            result = 1
          }
        }
        guard await handle.waitUntilStopped() else {
          throw MoxError(.connectionLost, "Cannot confirm generation stopped.")
        }
        if let finishedReason {
          session.complete(prompt: text, reply: reply, reason: finishedReason)
        }
        try await writeOutput("\n", handle: nil)
      } catch {
        active?.cancel()
        await active?.waitUntilStopped()
        diagnostic(String(describing: error))
        result = 1
      }
      active = nil
      working = false
    } while !oneShot && exiting == nil
    input?.cancel()
    sources.forEach { $0.cancel() }
    return exiting ?? result
  }
  func received(_ number: Int32) {
    if number == SIGTERM {
      exiting = 143
    } else if oneShot {
      exiting = 130
    } else if !working {
      exiting = 0
    }
    if working {
      interruptedBeforeHandle = true
      active?.cancel()
      diagnostic("Cancelling; waiting for backend to stop…")
    }
    if exiting != nil {
      inputWaiter?.resume(returning: nil)
      inputWaiter = nil
      input?.cancel()
    }
  }
  func readInput() async throws -> String? {
    if exiting != nil { return nil }
    if let newline = inputBuffer.firstIndex(of: 10) {
      let line = String(decoding: inputBuffer[..<newline], as: UTF8.self)
      inputBuffer.removeSubrange(...newline)
      return line
    }
    return try await withCheckedThrowingContinuation { continuation in
      inputWaiter = continuation
      let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .main)
      source.setEventHandler { [weak self] in Task { @MainActor in self?.readReady() } }
      input = source
      source.resume()
    }
  }
  func readReady() {
    guard inputWaiter != nil else { return }
    var bytes = [UInt8](repeating: 0, count: 4096)
    let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
    if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return }
    if count < 0 {
      inputWaiter?.resume(throwing: MoxError(.generationFailed, "Terminal input read failed."))
      inputWaiter = nil
      input?.cancel()
      return
    }
    if count == 0 {
      inputWaiter?.resume(returning: nil)
      inputWaiter = nil
      input?.cancel()
      return
    }
    inputBuffer.append(contentsOf: bytes.prefix(count))
    if inputBuffer.count > 1_048_576 {
      inputWaiter?.resume(
        throwing: MoxError(.contextLimit, "Input exceeds the 1 MiB safety limit."))
      inputWaiter = nil
      input?.cancel()
      return
    }
    if let newline = inputBuffer.firstIndex(of: 10) {
      let line = String(decoding: inputBuffer[..<newline], as: UTF8.self)
      inputBuffer.removeSubrange(...newline)
      inputWaiter?.resume(returning: line)
      inputWaiter = nil
      input?.cancel()
    }
  }
}

/// Nonblocking stdout with a bounded write deadline; main actor stays available to signals.
func writeOutput(_ text: String, handle: RemoteGeneration?) async throws {
  let data = Data(text.utf8)
  let deadline = ContinuousClock.now.advanced(by: .seconds(5))
  var offset = 0
  while offset < data.count {
    if handle?.isCancelled == true { return }
    let count = data.withUnsafeBytes {
      Darwin.write(STDOUT_FILENO, $0.baseAddress!.advanced(by: offset), data.count - offset)
    }
    if count > 0 {
      offset += count
      continue
    }
    if count < 0 && errno == EINTR { continue }
    guard count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) else {
      throw MoxError(.slowConsumer, "stdout closed or write failed.")
    }
    guard ContinuousClock.now < deadline else {
      throw MoxError(.slowConsumer, "stdout write exceeded 5 seconds.")
    }
    try await Task.sleep(for: .milliseconds(10))
  }
}
