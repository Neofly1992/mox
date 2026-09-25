import Darwin
import Foundation
import MoxDomain
import MoxProtocol
import OSLog

public struct WorkerOutputSnapshot: Codable, Sendable {
  public let stdoutBytes: UInt64
  public let stderrBytes: UInt64
}

private final class WorkerOutput: @unchecked Sendable {
  private let lock = NSLock()
  private var stdout: UInt64 = 0
  private var stderr: UInt64 = 0
  func record(_ count: Int, error: Bool) {
    lock.lock()
    defer { lock.unlock() }
    if error { stderr &+= UInt64(count) } else { stdout &+= UInt64(count) }
  }
  func snapshot() -> WorkerOutputSnapshot {
    lock.lock()
    defer { lock.unlock() }
    return .init(stdoutBytes: stdout, stderrBytes: stderr)
  }
}

/// The Process handle and stdin pipe constitute ownership. Observing discovery does not.
public final class Worker: @unchecked Sendable {
  public let process: Process
  private let control: Pipe
  private let output: Pipe
  private let errors: Pipe
  private let outputCounts = WorkerOutput()
  public var outputSnapshot: WorkerOutputSnapshot { outputCounts.snapshot() }
  public init(executable: URL, root: URL, ownership: ServiceOwnership = .appOwned) throws {
    guard FileManager.default.isExecutableFile(atPath: executable.path) else {
      throw MoxError(
        .incompatibleService, "Worker executable is missing. Rebuild or reinstall Mox.app.")
    }
    process = Process()
    control = Pipe()
    output = Pipe()
    errors = Pipe()
    process.executableURL = executable
    process.arguments = [
      "serve", "--data-root", root.path, "--ownership", ownership.rawValue, "--parent-control",
    ]
    process.standardInput = control
    process.standardOutput = output
    process.standardError = errors
    // Arbitrary process text is never exported: it may contain paths or prompts.
    // Read fixed-size chunks, retain counters, and keep structured diagnostics in OSLog.
    let counts = outputCounts
    for (pipe, isError) in [(output, false), (errors, true)] {
      let fd = pipe.fileHandleForReading.fileDescriptor
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
      pipe.fileHandleForReading.readabilityHandler = { handle in
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
        if count > 0 {
          counts.record(count, error: isError)
        } else if count == 0 {
          handle.readabilityHandler = nil
        } else if errno != EAGAIN && errno != EINTR {
          handle.readabilityHandler = nil
          Logger(subsystem: "dev.mox", category: "process").error("stage=pipeDrain code=readFailed")
        }
      }
    }
    process.terminationHandler = { process in
      let snapshot = counts.snapshot()
      Logger(subsystem: "dev.mox", category: "process").info(
        "stage=workerExit status=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) stdoutBytes=\(snapshot.stdoutBytes) stderrBytes=\(snapshot.stderrBytes)"
      )
    }
    try process.run()
    try? control.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
    try? errors.fileHandleForWriting.close()
  }
  public var isRunning: Bool { process.isRunning }
  public func requestStop() { try? control.fileHandleForWriting.close() }
  public func wait(seconds: Double = ServiceTiming.shutdownSeconds) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1000)))
    while process.isRunning && ContinuousClock.now < deadline {
      try? await Task.sleep(for: ServiceTiming.controlPoll)
    }
    return !process.isRunning
  }
  public func forceStop() async {
    requestStop()
    if process.isRunning { process.terminate() }
    if !(await wait(seconds: ServiceTiming.terminationSeconds)), process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      _ = await wait(seconds: ServiceTiming.terminationSeconds)
    }
  }
  deinit { try? control.fileHandleForWriting.close() }
}
