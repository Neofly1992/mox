import ArgumentParser
import Darwin
import Foundation
import MoxBootstrap
import MoxClient
import MoxProtocol

struct Doctor: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Read-only environment diagnosis; never starts a worker.")
  @Option var dataRoot: String = ServiceFiles.defaultRoot
  @Flag(help: "Emit structured, redacted JSON.") var json = false
  @Option(help: "Explicit expensive integrity check for an installed model alias.") var model:
    String?
  @Option(help: "Explicit network check using the configured default source, owner/repository.")
  var sourceRepository: String?
  @Option(help: "Per-check deadline, 1...120 seconds.") var timeoutSeconds = 15
  mutating func run() async throws {
    guard (1...120).contains(timeoutSeconds) else {
      throw ValidationError("timeout must be 1...120 seconds.")
    }
    var checks = DoctorChecks.local(root: dataRoot, worker: try ExecutableLocation.current())
    checks += DoctorChecks.extensions(
      root: dataRoot,
      model: model.map { .init(kind: "installedAlias", path: $0) },
      sourceRepository: sourceRepository)
    let work = Task { [checks, timeoutSeconds] in
      await DoctorRunner.run(checks, timeout: .seconds(timeoutSeconds)) { id in
        diagnostic("checking \(id)")
      }
    }
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { number in
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { work.cancel() }
      source.resume()
      return source
    }
    defer { signals.forEach { $0.cancel() } }
    let report = await work.value
    if json {
      print(String(decoding: try Wire.encode(report), as: UTF8.self))
    } else {
      for result in report.results {
        print("[\(result.status.rawValue)] \(result.id): \(result.reason)")
        if !result.suggestion.isEmpty { print("  → \(result.suggestion)") }
      }
    }
    throw ExitCode(report.exitCode)
  }
}
