import ArgumentParser
import Darwin
import Foundation
import MoxBootstrap
import MoxCore
import MoxDomain
import MoxMLX
import MoxPersistence
import MoxProtocol
import MoxServer
import MoxSources
import OSLog

struct Serve: AsyncParsableCommand {
  @Option var dataRoot: String = ServiceFiles.defaultRoot
  @Option var ownership: String = "foreground"
  @Option(help: "Temporary default maximum output tokens for this worker.") var defaultMaxTokens:
    Int?
  @Option(help: "Temporary default temperature for this worker.") var defaultTemperature: Float?
  @Option(help: "Temporary default top-p for this worker.") var defaultTopP: Float?
  @Option(help: "GPU queue capacity (1...64).") var queueCapacity: Int = 8
  @Option(help: "GPU queue timeout in seconds (1...600).") var queueTimeoutSeconds: Int = 60
  @Option(help: "Memory budget ceiling in bytes; may only lower the device recommendation.")
  var budgetBytes: Int?
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
    guard (1...64).contains(queueCapacity), (1...600).contains(queueTimeoutSeconds),
      budgetBytes.map({ 64 * 1024 * 1024 <= $0 && $0 <= budget }) ?? true
    else { throw ValidationError("Invalid queue or memory budget setting.") }
    let launchSampling = SamplingSettings(
      maxTokens: defaultMaxTokens,
      temperature: defaultTemperature, topP: defaultTopP)
    try launchSampling.validate()
    let effectiveBudget = budgetBytes ?? budget
    let runtime = RuntimeCoordinator(
      backend: MLXBackend(memoryLimit: effectiveBudget),
      policy: .init(
        budgetBytes: effectiveBudget, queueCapacity: queueCapacity,
        queueTimeout: .seconds(queueTimeoutSeconds)),
      availableMemory: { SystemMemory.reclaimablePageBytes() })
    let pressureEvents = AsyncStream<MemoryPressureLevel>.makeStream(
      bufferingPolicy: .bufferingNewest(16))
    let pressureConsumer = Task {
      for await level in pressureEvents.stream { await runtime.updatePressure(level) }
    }
    let pressureSource = DispatchSource.makeMemoryPressureSource(
      eventMask: [.normal, .warning, .critical], queue: .global())
    pressureSource.setEventHandler {
      let event = pressureSource.data
      let level: MemoryPressureLevel =
        event.contains(.critical)
        ? .critical
        : event.contains(.warning) ? .warning : .normal
      pressureEvents.continuation.yield(level)
    }
    pressureSource.resume()
    defer {
      pressureSource.cancel()
      pressureEvents.continuation.finish()
      pressureConsumer.cancel()
    }
    let libraryStore = try await RuntimeStore.open(root: files.root)
    let artifacts = try ArtifactStore(root: files.root.appendingPathComponent("models"))
    let downloads = try await DownloadManager.open(
      persistence: libraryStore, artifacts: artifacts)
    let sourceFactory = DefaultModelSources(
      cacheDirectory: files.root.appendingPathComponent("hub-cache"))
    let service = InferenceService(
      identity: identity, token: token, runtime: runtime,
      downloads: downloads, sources: sourceFactory, launchSampling: launchSampling)
    let publicAPI = PublicAPIManager(
      service: service, downloads: downloads,
      rootIdentity: files.rootIdentity)
    await service.attachPublicAPI(publicAPI)
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
            try await service.restoreLibrarySettings()
            await publicAPI.restore()
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
