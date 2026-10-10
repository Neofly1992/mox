import Darwin
import Foundation
import Metal
import MoxBootstrap
import MoxDomain
import MoxProtocol

/// Small ordered checks with cooperative cancellation; platform/library checks are
/// injected, not a plugin system. Untrusted exception descriptions are never exported.
public struct DoctorCheck: Sendable {
  public let id: String
  public let operation: @Sendable () async throws -> DoctorResult
  public init(id: String, operation: @escaping @Sendable () async throws -> DoctorResult) {
    self.id = id
    self.operation = operation
  }
}
public enum DoctorRunner {
  public static func run(
    _ checks: [DoctorCheck], timeout: Duration = .seconds(15),
    progress: @Sendable (String) async -> Void = { _ in }
  ) async -> DoctorReport {
    var results: [DoctorResult] = []
    var events: [DiagnosticEvent] = []
    for check in checks {
      if Task.isCancelled {
        results.append(.init(id: check.id, status: .cancelled, reason: "Check cancelled; not run."))
        continue
      }
      await progress(check.id)
      do {
        let result = try await withThrowingTaskGroup(of: DoctorResult.self) { group in
          group.addTask { try await check.operation() }
          group.addTask {
            try await Task.sleep(for: timeout)
            return .init(
              id: check.id, status: .timedOut, reason: "Check deadline exceeded.",
              suggestion: "Retry this explicit check after restoring access.")
          }
          var result = try await group.next()!
          group.cancelAll()
          if result.status == .timedOut {
            do { _ = try await group.next() } catch let error as MoxError
              where error.code == .connectionLost
            {
              result = .init(
                id: check.id, status: .timedOut,
                reason: "Deadline exceeded; service check stop could not be confirmed.",
                suggestion:
                  "Reconnect and export diagnostics; do not assume the inspection stopped.")
            } catch { /* Cooperative cancellation of the losing operation is expected. */  }
          }
          return result
        }
        results.append(result)
      } catch {
        let cancelled = Task.isCancelled || error is CancellationError
        let code = (error as? MoxError)?.code.rawValue ?? "checkFailed"
        let suggestion: String
        switch (error as? MoxError)?.code {
        case .authenticationFailed:
          suggestion = "Restore source credentials in settings; diagnosis does not change them."
        case .incompatibleService:
          suggestion =
            "Stop the existing worker through its original launcher and reopen the matching App/CLI version."
        case .connectionLost:
          suggestion =
            "Reconnect explicitly through the service owner; local diagnosis does not restart services."
        case .invalidModel:
          suggestion =
            "Inspect model integrity and selected repository/revision; no files were repaired."
        default:
          suggestion = "Check permissions/resources and export diagnostics if the problem persists."
        }
        results.append(
          .init(
            id: check.id, status: cancelled ? .cancelled : .failed,
            reason: cancelled
              ? ((error as? MoxError)?.code == .connectionLost
                ? "Cancellation requested; service check stop not confirmed." : "Check cancelled.")
              : "Check failed (\(code)); see safe stage and system code.",
            suggestion: cancelled
              ? "Run diagnosis again when ready; inspect stop status if service access was lost." : suggestion
          ))
        let ns = error as NSError
        events.append(
          .init(
            stage: "doctor.\(check.id)",
            code: (error as? MoxError)?.code.rawValue ?? (cancelled ? "cancelled" : "checkFailed"),
            systemDomain: error is MoxError ? nil : ns.domain,
            systemCode: error is MoxError ? nil : ns.code))
      }
    }
    return .init(results: results, events: events)
  }
}

/// Read-only local checks work without a running service or development toolchain.
public enum DoctorChecks {
  public static func local(root: String, worker: URL, appBundle: URL? = nil) -> [DoctorCheck] {
    [
      DoctorCheck(id: "environment.runtime") {
        let supported = ProcessInfo.processInfo.isOperatingSystemAtLeast(
          .init(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        #if arch(arm64)
          let native = true
        #else
          let native = false
        #endif
        return .init(
          id: "environment.runtime", status: supported && native ? .passed : .failed,
          reason: supported && native
            ? "Apple Silicon macOS 15+ runtime; no Xcode, Swift compiler or Python required."
            : "Unsupported OS or process architecture.",
          suggestion: supported && native
            ? "" : "Use an Apple Silicon Mac running macOS 15 or later.")
      },
      DoctorCheck(id: "environment.metal") {
        guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else {
          return .init(id: "environment.metal", status: .failed,
            reason: "A unified-memory Metal device is unavailable; MLX inference cannot start.",
            suggestion: "Run on Apple Silicon and inspect macOS GPU availability; no model was loaded.")
        }
        return .init(id: "environment.metal", status: .passed,
          reason: "Unified-memory Metal device available; recommended working-set bytes: \(device.recommendedMaxWorkingSetSize). This is advisory, not an allocation guarantee.")
      },
      DoctorCheck(id: "package.resources") {
        let bundle = worker.deletingLastPathComponent().deletingLastPathComponent()
        let resources =
          bundle.lastPathComponent == "Contents"
          ? bundle.appendingPathComponent("Resources") : worker.deletingLastPathComponent()
        let metal = resources.appendingPathComponent(
          "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        guard FileManager.default.isExecutableFile(atPath: worker.path),
          FileManager.default.isReadableFile(atPath: metal.path)
        else {
          return .init(
            id: "package.resources", status: .failed,
            reason: "Worker executable or bundled MLX Metal resource missing.",
            suggestion:
              "Reinstall the complete App/CLI distribution or rebuild with scripts/build.sh.")
        }
        return .init(
          id: "package.resources", status: .passed,
          reason: "Worker and required MLX Metal resource are readable.")
      },
      DoctorCheck(id: "package.identity") {
        guard let appBundle else {
          return .init(
            id: "package.identity", status: .skipped,
            reason: "Standalone CLI identity is the executing build; no App bundle selected.")
        }
        let workerBundle = worker.deletingLastPathComponent().deletingLastPathComponent()
          .deletingLastPathComponent()
        guard let app = Bundle(url: appBundle), let embedded = Bundle(url: workerBundle),
          app.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            == Wire.productVersion,
          embedded.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            == Wire.productVersion,
          embedded.object(forInfoDictionaryKey: "MoxBuildID") as? String == Wire.buildID
        else {
          return .init(
            id: "package.identity", status: .failed,
            reason: "App/worker version or build fingerprint differs.",
            suggestion: "Reinstall or rebuild the entire App bundle together.")
        }
        return .init(
          id: "package.identity", status: .passed,
          reason: "App and embedded worker version/fingerprint match.")
      },
      DoctorCheck(id: "data.permissions") {
        let url = URL(fileURLWithPath: root).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
          return .init(
            id: "data.permissions", status: .skipped,
            reason: "Data root has not been created; diagnosis did not create it.",
            suggestion: "Start Mox explicitly to initialize this data root.")
        }
        var rootInfo = stat()
        guard stat(url.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
          access(url.path, R_OK | W_OK | X_OK) == 0
        else {
          return .init(
            id: "data.permissions", status: .failed, reason: "Data root is not a readable, writable, traversable directory.",
            suggestion: "Restore access to the selected data root without deleting its contents.")
        }
        let run = url.appendingPathComponent("run")
        if FileManager.default.fileExists(atPath: run.path) {
          var info = stat()
          guard lstat(run.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
            info.st_uid == getuid(), info.st_mode & 0o077 == 0
          else {
            return .init(
              id: "data.permissions", status: .failed,
              reason: "Runtime directory ownership or permissions unsafe.",
              suggestion:
                "Restore owner-only access to the runtime directory; preserve model/history files.")
          }
          guard access(run.path, R_OK | W_OK | X_OK) == 0 else {
            return .init(
              id: "data.permissions", status: .failed,
              reason: "Runtime directory cannot be read, written or traversed.",
              suggestion: "Restore owner read/write/traversal access; diagnosis changes no permissions.")
          }
        }
        return .init(
          id: "data.permissions", status: .passed,
          reason: "Data root access and existing runtime permissions checked without writing.")
      },
      DoctorCheck(id: "data.disk") {
        var url = URL(fileURLWithPath: root).standardizedFileURL
        while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
          url.deleteLastPathComponent()
        }
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let available = values.volumeAvailableCapacity else {
          return .init(
            id: "data.disk", status: .skipped, reason: "Filesystem capacity unavailable.",
            suggestion: "Inspect available storage in macOS settings.")
        }
        // 1 GiB is a diagnostic warning threshold, not the download disk admission rule.
        return .init(
          id: "data.disk", status: available < 1024 * 1024 * 1024 ? .warning : .passed,
          reason:
            "Available filesystem bytes: \(available); each download still checks its own peak plan.",
          suggestion: available < 1024 * 1024 * 1024
            ? "Free storage before acquiring models; diagnosis removes nothing." : "")
      },
      DoctorCheck(id: "service.identity") {
        let files = try ServiceFiles(path: root, prepareDirectories: false)
        guard let discovery = try files.read() else {
          return .init(
            id: "service.identity", status: .skipped,
            reason: "No service discovery; local checks completed without starting a worker.",
            suggestion: "Start or reconnect Mox explicitly if inference is needed.")
        }
        _ = try await ServiceClient(discovery: discovery).identity()
        return .init(
          id: "service.identity", status: .passed,
          reason: "Authenticated service instance, data root and build identity match.")
      },
      DoctorCheck(id: "service.state") {
        let files = try ServiceFiles(path: root, prepareDirectories: false)
        guard let discovery = try files.read() else {
          return .init(
            id: "service.state", status: .skipped,
            reason: "Service not running; state not inspected.")
        }
        let client = ServiceClient(discovery: discovery)
        _ = try await client.identity()
        let state = try await client.state()
        let memory =
          state.backendMemory.map {
            " MLX active bytes \($0.activeBytes), cache bytes \($0.cacheBytes), process peak active bytes \($0.peakActiveBytes)."
          } ?? " MLX allocator metrics unavailable."
        return .init(
          id: "service.state",
          status: state.admissionPaused || state.libraryRecovery.phase == .failed
            ? .warning : .passed,
          reason:
            "Service \(state.serviceState); pressure \(state.memoryPressure.rawValue); reserved bytes \(state.reservedBytes), budget \(state.budgetBytes).\(memory) MLX active/cache/peak are allocator metrics, not total system use.",
          suggestion: state.admissionPaused
            ? "Wait for normal memory pressure; stop other memory-heavy work yourself." : "")
      },
      DoctorCheck(id: "service.public-api") {
        let files = try ServiceFiles(path: root, prepareDirectories: false)
        guard let discovery = try files.read() else {
          return .init(
            id: "service.public-api", status: .skipped,
            reason: "Service not running; API state not inspected.")
        }
        let client = ServiceClient(discovery: discovery)
        _ = try await client.identity()
        let status = try await client.publicAPIStatus()
        return .init(
          id: "service.public-api", status: status.errorCode == nil ? .passed : .warning,
          reason: status.enabled
            ? "Public API enabled; inspect API controls for listener status."
            : "Public API disabled by configuration; this is not a fault.",
          suggestion: status.errorCode == nil ? "" : "Inspect API controls and export diagnostics.")
      },
    ]
  }
}

extension DoctorChecks {
  public static func extensions(
    root: String, model: GenerateBody.Model? = nil, sourceRepository: String? = nil
  ) -> [DoctorCheck] {
    @Sendable func client() async throws -> ServiceClient? {
      let files = try ServiceFiles(path: root, prepareDirectories: false)
      guard let discovery = try files.read() else { return nil }
      let client = ServiceClient(discovery: discovery)
      _ = try await client.identity()
      return client
    }
    return [
      DoctorCheck(id: "model.integrity") {
        guard let model else {
          return .init(
            id: "model.integrity", status: .skipped,
            reason: "Expensive integrity check not selected.")
        }
        guard let service = try await client() else {
          return .init(
            id: "model.integrity", status: .skipped,
            reason: "Service not running; no model inspection performed.",
            suggestion: "Start service explicitly and select this check again.")
        }
        return try await service.inspectModel(model)
      },
      DoctorCheck(id: "source.connectivity") {
        guard let repository = sourceRepository else {
          return .init(
            id: "source.connectivity", status: .skipped,
            reason: "Network source check not selected.")
        }
        guard let service = try await client() else {
          return .init(
            id: "source.connectivity", status: .skipped,
            reason: "Service not running; source credentials and metadata not inspected.",
            suggestion: "Start service explicitly before checking configured source access.")
        }
        let config = try await service.library().configuration
        guard let registry = config.preferredRegistry(for: nil) else {
          return .init(
            id: "source.connectivity", status: .failed, reason: "No default source configured.",
            suggestion: "Configure a model source explicitly.")
        }
        return try await service.inspectSource(
          .init(
            provider: registry.provider,
            endpoint: registry.mirror ?? registry.origin, registryID: registry.id,
            repository: repository, selector: registry.provider == .huggingFace ? "main" : "master",
            variant: ""))
      },
      DoctorCheck(id: "service.diagnostics") {
        guard let service = try await client() else {
          return .init(
            id: "service.diagnostics", status: .skipped,
            reason: "No service diagnostic events available.")
        }
        let events = try await service.diagnosticEvents()
        return .init(
          id: "service.diagnostics", status: events.isEmpty ? .passed : .warning,
          reason: "Safe diagnostic events available: \(events.count).",
          suggestion: events.isEmpty ? "" : "Export diagnostics to inspect error codes and stages.")
      },
    ]
  }
}
