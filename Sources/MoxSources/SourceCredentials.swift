import Foundation
import MoxDomain
import Security

/// Keychain account includes both registry and exact HTTPS origin. Tokens never enter
/// SwiftData, progress events, logs, manifests, or exported configuration.
public struct SourceCredentials: Sendable {
  private let service = "dev.mox.registry-credentials"
  public init() {}
  public func reference(registryID: UUID, endpoint: URL) throws -> String {
    guard endpoint.scheme == "https", let host = endpoint.host,
      endpoint.user == nil, endpoint.password == nil, endpoint.query == nil,
      endpoint.fragment == nil,
      endpoint.path.isEmpty || endpoint.path == "/" else { throw MoxError(.invalidParameters, "Credentials require an HTTPS origin.") }
    return "\(registryID.uuidString)|https://\(host.lowercased()):\(endpoint.port ?? 443)"
  }
  public func save(_ secret: String, registryID: UUID, endpoint: URL) throws -> String {
    // A configuration update may fail after this write. Never overwrite the
    // credential referenced by the currently committed configuration.
    let account = try reference(registryID: registryID, endpoint: endpoint) + "|" + UUID().uuidString
    guard !secret.isEmpty, secret.utf8.count <= 4096 else {
      throw MoxError(.invalidParameters, "Credential is empty or exceeds 4 KiB.")
    }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: account]
    let data = Data(secret.utf8)
    var item = query
    item[kSecValueData as String] = data
    guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
      throw MoxError(.storageFailed, "Keychain could not store this source credential.")
    }
    return account
  }
  public func delete(reference: String) throws {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: reference]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw MoxError(.storageFailed, "Keychain could not remove an unused source credential.")
    }
  }
  public func read(reference: String) throws -> String {
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service, kSecAttrAccount as String: reference,
      kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
      let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
      throw MoxError(.authenticationFailed, "Source credential is unavailable in Keychain.")
    }
    return value
  }
}
