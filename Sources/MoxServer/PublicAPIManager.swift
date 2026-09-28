import Foundation
import MoxCore
import MoxDomain
import MoxProtocol
import Security

/// Public listener lifecycle belongs to the worker. The private service is the sole
/// authority for toggling it; no public request can reach management methods.
public actor PublicAPIManager {
  private let service: InferenceService
  private let downloads: DownloadManager
  private let account: String
  private var key: String?
  private var endpoint: String?
  private var failure: String?
  private var task: Task<Void, Never>?
  private var ready: CheckedContinuation<Int, Error>?
  private var stopping = false
  private var credentialID = UUID()
  private var transitionHeld = false
  private var transitionWaiters: [CheckedContinuation<Void, Never>] = []

  public init(service: InferenceService, downloads: DownloadManager, rootIdentity: String) {
    self.service = service
    self.downloads = downloads
    account = "dev.mox.public-api.\(rootIdentity)"
  }
  public func status() -> PublicAPIStatus {
    PublicAPIStatus(enabled: task != nil && endpoint != nil, endpoint: endpoint,
      errorCode: failure, credentialID: credentialID)
  }
  public func currentKey() throws -> PublicAPIKey? {
    try loadKey().map { PublicAPIKey(key: $0, credentialID: credentialID) }
  }
  public func authorize(_ supplied: String?) -> Bool {
    guard let key, let supplied else { return false }
    let a = Array(key.utf8), b = Array(supplied.utf8)
    guard a.count == b.count else { return false }
    var difference: UInt8 = 0
    for index in a.indices { difference |= a[index] ^ b[index] }
    return difference == 0
  }
  public func restore() async {
    guard (await downloads.snapshot()).configuration.publicAPIEnabled else { return }
    await acquireTransition()
    defer { releaseTransition() }
    do { try await start() }
    catch let error as MoxError {
      failure = error.code == .storageFailed ? error.code.rawValue : "publicListenerUnavailable"
    }
    catch { failure = "publicListenerUnavailable" }
  }
  public func setEnabled(_ enabled: Bool) async throws -> PublicAPIStatus {
    await acquireTransition()
    defer { releaseTransition() }
    try Task.checkCancellation()
    if enabled {
      if task == nil { try await start() }
      do { _ = try await downloads.setPublicAPIEnabled(true) }
      catch { await stop(); throw error }
    } else {
      _ = try await downloads.setPublicAPIEnabled(false)
      await stop()
    }
    return status()
  }
  public func rotateKey() throws -> PublicAPIKey {
    let new = try ServiceKey.generate()
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.mox.public-api", kSecAttrAccount as String: account]
    let code: OSStatus
    if try loadKey() != nil {
      code = SecItemUpdate(query as CFDictionary,
        [kSecValueData as String: Data(new.utf8)] as CFDictionary)
    } else {
      var create = query
      create[kSecValueData as String] = Data(new.utf8)
      create[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
      code = SecItemAdd(create as CFDictionary, nil)
    }
    guard code == errSecSuccess else {
      throw MoxError(.storageFailed, "Public API key could not be saved in Keychain.")
    }
    key = new
    credentialID = UUID()
    return PublicAPIKey(key: new, credentialID: credentialID)
  }
  private func acquireTransition() async {
    if !transitionHeld {
      transitionHeld = true
      return
    }
    await withCheckedContinuation { transitionWaiters.append($0) }
  }
  private func releaseTransition() {
    if transitionWaiters.isEmpty { transitionHeld = false }
    else { transitionWaiters.removeFirst().resume() }
  }
  private func loadKey() throws -> String? {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "dev.mox.public-api", kSecAttrAccount as String: account,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    let code = SecItemCopyMatching(query as CFDictionary, &result)
    if code == errSecItemNotFound { return nil }
    guard code == errSecSuccess else {
      throw MoxError(.storageFailed, "Public API key is unavailable in Keychain (status \(code)).")
    }
    guard code == errSecSuccess, let data = result as? Data,
      let value = String(data: data, encoding: .utf8), value.utf8.count == 64 else {
      throw MoxError(.storageFailed, "Public API key data is invalid in Keychain.")
    }
    return value
  }
  private func start() async throws {
    if task != nil { return }
    if let existing = try loadKey() { key = existing }
    else { key = try rotateKey().key }
    failure = nil
    let server = PublicServer(service: service, manager: self)
    let deadline = Task {
      try? await Task.sleep(for: ServiceTiming.readiness)
      if !Task.isCancelled { await self.didTimeout() }
    }
    defer { deadline.cancel() }
    do {
      let port = try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Int, Error>) in
        ready = waiter
        task = Task {
          do { try await server.run { port in await self.didBind(port) } }
          catch { await self.didFail() }
        }
      }
      endpoint = "http://127.0.0.1:\(port)"
    } catch {
      task?.cancel()
      task = nil
      key = nil
      throw error
    }
  }
  private func didBind(_ port: Int) {
    ready?.resume(returning: port)
    ready = nil
  }
  private func didFail() {
    if stopping { return }
    failure = "publicListenerUnavailable"
    ready?.resume(throwing: MoxError(.serviceConflict, "Public API listener could not start."))
    ready = nil
    task = nil
    endpoint = nil
    key = nil
  }
  private func didTimeout() {
    guard let ready else { return }
    self.ready = nil
    failure = "publicListenerUnavailable"
    task?.cancel()
    ready.resume(throwing: MoxError(.serviceConflict, "Public API listener did not become ready."))
  }
  private func stop() async {
    stopping = true
    await service.stopPublicGenerations()
    task?.cancel()
    await task?.value
    task = nil
    key = nil
    endpoint = nil
    failure = nil
    stopping = false
  }
  public func shutdown() async {
    await acquireTransition()
    defer { releaseTransition() }
    await stop()
  }
}
private enum ServiceKey {
  static func generate() throws -> String {
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      throw MoxError(.storageFailed, "Public API key could not be generated.")
    }
    return bytes.map { String(format: "%02x", $0) }.joined()
  }
}
