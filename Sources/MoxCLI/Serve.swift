import ArgumentParser
import Darwin
import Foundation
import MoxBootstrap
import MoxCore
import MoxDomain
import MoxMLX
import MoxProtocol
import MoxPersistence
import MoxSources
import MoxServer
import OSLog

struct Serve: AsyncParsableCommand {
  @Option var dataRoot: String = ServiceFiles.defaultRoot
  @Option var ownership: String = "foreground"
  @Flag var parentControl = false
  mutating func run() async throws {
    BuildInfo.logStartup(component: "worker")
    guard let owner = ServiceOwnership(rawValue: ownership), owner != .appOwned || parentControl
    else { throw ValidationError("Invalid service ownership/control combination.") }
    let files = try ServiceFiles(path: dataRoot)
    let lock = try files.lock()
    let identity = ServiceIdentity(
      pid: getpid(), uid: getuid(), rootIdentity: files.rootIdentity, ownership: owner)
    let token = try ServiceFiles.token()
    // Validate packaged resources before Cmlx's generated accessor can throw an NSException.
    if Bundle.main.bundleURL.pathExtension == "app" {
      guard
        let resource = Bundle.main.resourceURL?.appendingPathComponent(
          "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"),
        FileManager.default.isReadableFile(atPath: resource.path)
      else {
        Logger(subsystem: "dev.mox", category: "process").error("stage=resources code=loadFailed")
        throw MoxError(
          .loadFailed, "Bundled Metal resources are missing. Rebuild or reinstall Mox.app.")
      }
    }
    let budget = try MLXBackend.recommendedBudget()
    let runtime = RuntimeCoordinator(
      backend: MLXBackend(memoryLimit: budget), policy: .init(budgetBytes: budget),
      availableMemory: { SystemMemory.availableBytes() })
    let libraryStore = try await RuntimeStore.open(root: files.root)
    let artifacts = try ArtifactStore(root: files.root.appendingPathComponent("models"))
    let downloads = DownloadManager(
      persistence: libraryStore, artifacts: artifacts, state: try await libraryStore.readLibrary())
    try await downloads.recover()
    let sourceFactory = DefaultModelSources(cacheDirectory: files.root.appendingPathComponent("hub-cache"))
    let service = InferenceService(
      identity: identity, token: token, runtime: runtime,
      downloads: downloads, sources: sourceFactory)
    let publicAPI = PublicAPIManager(service: service, downloads: downloads,
      rootIdentity: files.rootIdentity)
    await service.attachPublicAPI(publicAPI)
    await publicAPI.restore()
    let stop = AsyncStream<MoxError?>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var signals: [DispatchSourceSignal] = []
    signal(SIGPIPE, SIG_IGN)
    for fd in [STDOUT_FILENO, STDERR_FILENO] {
      let flags = fcntl(fd, F_GETFL)
      if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }
    for number in [SIGINT, SIGTERM] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { stop.continuation.yield(nil) }
      source.resume()
      signals.append(source)
    }
    var parent: DispatchSourceRead?
    if parentControl {
      let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global())
      source.setEventHandler {
        var byte: UInt8 = 0
        if Darwin.read(STDIN_FILENO, &byte, 1) <= 0 {
          source.cancel()
          stop.continuation.yield(nil)
        }
      }
      source.resume()
      parent = source
    }
    defer {
      signals.forEach { $0.cancel() }
      parent?.cancel()
      stop.continuation.finish()
      files.remove(instanceID: identity.instanceID)
      withExtendedLifetime(lock) {}
    }
    let server = PrivateServer(service: service)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await server.run { port in
          do {
            try files.publish(
              Discovery(
                identity: identity, privateEndpoint: "http://127.0.0.1:\(port)", token: token))
            Logger(subsystem: "dev.mox", category: "process").info(
              "instance=\(identity.instanceID.uuidString, privacy: .public) phase=ready")
            diagnostic(
              "Mox ready instance=\(identity.instanceID) endpoint=http://127.0.0.1:\(port) owner=\(owner.rawValue)"
            )
          } catch {
            Logger(subsystem: "dev.mox", category: "process").error(
              "phase=ready code=serviceConflict")
            stop.continuation.yield(MoxError(.serviceConflict, "Cannot publish service readiness."))
          }
        }
      }
      group.addTask {
        var failure: MoxError?
        for await reason in stop.stream {
          failure = reason
          break
        }
        guard !Task.isCancelled else { return }
        let deadline = Task {
          try await Task.sleep(for: .seconds(ServiceTiming.shutdownSeconds))
          Darwin._exit(1)
        }
        await service.shutdown()
        deadline.cancel()
        if let failure { throw failure }
      }
      _ = try await group.next()
      group.cancelAll()
    }
    await service.shutdown()
  }
}
