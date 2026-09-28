import ArgumentParser
import Foundation
import MoxBootstrap
import MoxClient
import MoxProtocol

struct API: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "api", abstract: "Inspect or control the local public inference API.")
  @Option var dataRoot: String = ServiceFiles.defaultRoot
  @Argument(help: "status, enable, disable, key, or rotate") var action: String

  mutating func run() async throws {
    guard ["status", "enable", "disable", "key", "rotate"].contains(action) else {
      throw ValidationError("Action must be status, enable, disable, key, or rotate.")
    }
    let connection = try await Connection.open(root: dataRoot,
      executable: ExecutableLocation.current(), allowStart: false)
    let client = connection.client
    switch action {
    case "status":
      let status = try await client.publicAPIStatus()
      print(status.enabled ? "running \(status.endpoint ?? "")" : "off")
      if let error = status.errorCode { diagnostic("public_api_error=\(error)") }
    case "enable", "disable":
      let status = try await client.setPublicAPIEnabled(action == "enable")
      print(status.enabled ? "running \(status.endpoint ?? "")" : "off")
    case "key":
      let result = try await client.publicAPIKey()
      print(result.key)
    case "rotate":
      let result = try await client.rotatePublicAPIKey()
      print(result.key)
    default: break
    }
  }
}
