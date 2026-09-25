import Foundation
import MoxBootstrap
import MoxDomain
import MoxProtocol

public struct Connection: Sendable {
  public let client: ServiceClient
  public let worker: Worker?
  public static func open(root: String, executable: URL, allowStart: Bool = true) async throws
    -> Connection
  {
    let files = try ServiceFiles(path: root)
    if let discovery = try files.read(matchingBuild: false) {
      if discovery.identity.buildID != Wire.buildID
        || discovery.identity.protocolVersion != Wire.version
      {
        do {
          let probe = try files.lock()
          withExtendedLifetime(probe) {}
        } catch {
          throw MoxError(
            .incompatibleService,
            "The existing owner uses another version; stop it through its launcher before reconnecting."
          )
        }
        // With no owner, the new worker may replace stale readiness after taking the lock.
      } else {
        let client = ServiceClient(discovery: discovery)
        do {
          _ = try await client.identity()
          return Connection(client: client, worker: nil)
        } catch let e as MoxError
          where e.code == .incompatibleService || e.code == .authenticationFailed
          || e.code == .protocolViolation
        { throw e } catch {
          // A live owner with a broken listener must not be replaced.
          let probe = try files.lock()
          withExtendedLifetime(probe) {}
        }
      }
    }
    guard allowStart else {
      throw MoxError(.connectionLost, "No available service; reconnect explicitly to start one.")
    }
    let worker = try Worker(executable: executable, root: files.root)
    let deadline = ContinuousClock.now.advanced(by: ServiceTiming.readiness)
    do {
      while ContinuousClock.now < deadline {
        if let discovery = try files.read(matchingBuild: false) {
          let client = ServiceClient(discovery: discovery)
          if (try? await client.identity()) != nil {
            let owned = discovery.identity.pid == worker.process.processIdentifier
            if !owned {
              worker.requestStop()
              _ = await worker.wait(seconds: ServiceTiming.terminationSeconds)
            }
            return Connection(client: client, worker: owned ? worker : nil)
          }
        }
        if !worker.isRunning, let unlocked = try? files.lock() {
          withExtendedLifetime(unlocked) {}
          throw MoxError(
            .connectionLost,
            "Worker exited before readiness (status \(worker.process.terminationStatus)). Inspect process diagnostics; rebuild or reinstall if resources are missing."
          )
        }
        try await Task.sleep(for: ServiceTiming.controlPoll)
      }
      throw MoxError(
        .connectionLost,
        "Worker did not become ready within 15 seconds. Inspect process diagnostics.")
    } catch {
      await worker.forceStop()
      throw error
    }
  }
}
