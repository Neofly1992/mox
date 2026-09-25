import ArgumentParser
import Foundation
import MoxBootstrap
import MoxClient
import MoxDomain
import MoxProtocol

struct Models: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Get and inspect managed MLX models.",
    subcommands: [Plan.self, Pull.self, List.self, Show.self, Import.self, Remove.self, Select.self, Load.self, Unload.self, DownloadAction.self, Sources.self, DefaultSource.self])
  private static func request(client: ServiceClient, provider: ModelProvider?,
    repository: String, revision: String?, variant: String, endpoint: String?
  ) async throws -> PullBody {
    let library = try await client.library()
    let selected: ModelRegistry
    if let endpoint {
      guard let url = URL(string: endpoint) else { throw ValidationError("Invalid source endpoint.") }
      if let existing = library.configuration.registries.first(where: {
        $0.origin == url && (provider == nil || $0.provider == provider)
      }) {
        selected = existing
      } else {
        guard let kind = provider else {
          throw ValidationError("Specify --provider when adding a source endpoint.")
        }
        let registry = ModelRegistry(id: UUID(), name: repository, provider: kind, origin: url)
        _ = try await client.updateRegistry(.init(
          expectedRevision: library.configuration.revision, registry: registry))
        selected = registry
      }
    } else {
      guard let preferred = library.configuration.preferredRegistry(for: provider) else {
        throw ValidationError("No model source is configured for this provider.")
      }
      selected = preferred
    }
    return .init(provider: selected.provider, endpoint: selected.mirror ?? selected.origin,
      registryID: selected.id, repository: repository,
      selector: revision ?? (selected.provider == .huggingFace ? "main" : "master"), variant: variant)
  }
  private static func awaitDownload(_ id: UUID, client: ServiceClient) async throws {
    while true {
      let operation = try await client.download(id)
      switch operation.phase {
      case .installed: return
      case .failed:
        throw MoxError(.connectionLost,
          "Download failed (\(operation.errorCode ?? "unknown")); inspect or resume operation \(id).")
      case .interrupted, .cancelled:
        throw MoxError(.connectionLost, "Download stopped before installation; operation \(id).")
      case .paused:
        throw MoxError(.busy, "Download is paused; resume operation \(id).")
      case .downloading, .verifying, .committing:
        try await Task.sleep(for: .milliseconds(250))
      }
    }
  }
  struct Plan: AsyncParsableCommand {
    @Option var dataRoot: String = ServiceFiles.defaultRoot
    @Option var provider: String?
    @Option var repository: String
    @Option var revision: String?
    @Option var variant: String = ""
    @Option var endpoint: String?
    mutating func run() async throws {
      let kind = try provider.map {
        guard let value = ModelProvider(rawValue: $0) else {
          throw ValidationError("Use --provider huggingFace or modelScope.")
        }
        return value
      }
      let connection = try await Connection.open(root: dataRoot, executable: ExecutableLocation.current())
      defer { connection.worker?.requestStop() }
      let body = try await Models.request(client: connection.client, provider: kind,
        repository: repository, revision: revision, variant: variant, endpoint: endpoint)
      let plan = try await connection.client.planPull(body)
      print("revision: \(plan.origin.revision)")
      print("files: \(plan.fileCount), download bytes: \(plan.totalBytes), peak bytes: \(plan.peakBytes)")
      if let available = plan.availableBytes { print("available bytes: \(available)") }
      else { print("available bytes: unknown") }
    }
  }
  struct Pull: AsyncParsableCommand {
    @Option var dataRoot: String = ServiceFiles.defaultRoot
    @Option var provider: String?
    @Option var repository: String
    @Option var revision: String?
    @Option var variant: String = ""
    @Option var endpoint: String?
    mutating func run() async throws {
      let kind = try provider.map {
        guard let value = ModelProvider(rawValue: $0) else {
          throw ValidationError("Use --provider huggingFace or modelScope.")
        }
        return value
      }
      let connection = try await Connection.open(root: dataRoot, executable: ExecutableLocation.current())
      defer { connection.worker?.requestStop() }
      let body = try await Models.request(client: connection.client, provider: kind,
        repository: repository, revision: revision, variant: variant, endpoint: endpoint)
      let created = try await connection.client.pull(body)
      print(created.id.uuidString)
      try await Models.awaitDownload(created.id, client: connection.client)
    }
  }
  struct List: AsyncParsableCommand {
    @Option var dataRoot: String = ServiceFiles.defaultRoot
    mutating func run() async throws {
      let connection = try await Connection.open(root: dataRoot, executable: ExecutableLocation.current())
      defer { connection.worker?.requestStop() }
      var installOffset = 0
      var operationOffset = 0
      while true {
        let page = try await connection.client.library(
          installationOffset: installOffset, operationOffset: operationOffset)
        for item in page.installations { print("\(item.id)  \(item.alias)  \(item.path)") }
        for item in page.operations where item.phase != .installed {
          print("\(item.id)  \(item.phase.rawValue)  \(item.origin.repository)")
        }
        installOffset += page.installations.count
        operationOffset += page.operations.count
        if installOffset >= page.totalInstallations && operationOffset >= page.totalOperations { break }
      }
    }
  }
  struct Show: AsyncParsableCommand {
    @Option var dataRoot: String = ServiceFiles.defaultRoot
    @Argument var id: String
    mutating func run() async throws {
      guard let value = UUID(uuidString: id) else { throw ValidationError("Expected model UUID.") }
      let connection = try await Connection.open(root: dataRoot, executable: ExecutableLocation.current())
      defer { connection.worker?.requestStop() }
      let model = try await connection.client.model(value)
      print("\(model.id)  \(model.alias)  \(model.availability.rawValue)  \(model.path)")
    }
  }
  struct Import: AsyncParsableCommand {
    @Option var dataRoot: String = ServiceFiles.defaultRoot
    @Option var alias: String?
    @Argument var path: String
    mutating func run() async throws {
      let connection = try await Connection.open(root: dataRoot, executable: ExecutableLocation.current())
      defer { connection.worker?.requestStop() }
      let name = alias ?? URL(fileURLWithPath: path).lastPathComponent
      let item = try await connection.client.importModel(path: path, alias: name)
      print("imported \(item.id)  \(item.alias)")
    }
  }
  struct Remove: AsyncParsableCommand {
    @Option var dataRoot: String = ServiceFiles.defaultRoot
    @Argument var id: String
    mutating func run() async throws {
      guard let value = UUID(uuidString: id) else { throw ValidationError("Expected model UUID.") }
      let connection = try await Connection.open(root: dataRoot, executable: ExecutableLocation.current())
      defer { connection.worker?.requestStop() }
      _ = try await connection.client.removeModel(value)
      print("removed \(value)")
    }
  }
  struct Select: AsyncParsableCommand {
    @Option var dataRoot: String = ServiceFiles.defaultRoot
    @Argument var id: String
    mutating func run() async throws {
      guard let value = UUID(uuidString: id) else { throw ValidationError("Expected model UUID.") }
      let connection = try await Connection.open(root: dataRoot, executable: ExecutableLocation.current())
      defer { connection.worker?.requestStop() }
      _ = try await connection.client.selectModel(value)
      let selected = try await connection.client.model(value)
      print("current model: \(selected.alias)  \(value)")
    }
  }
  struct Load: AsyncParsableCommand {
    @Option var dataRoot: String = ServiceFiles.defaultRoot
    @Argument var id: String
    mutating func run() async throws {
      guard let value = UUID(uuidString: id) else { throw ValidationError("Expected model UUID.") }
      let connection = try await Connection.open(root: dataRoot, executable: ExecutableLocation.current())
      defer { connection.worker?.requestStop() }
      _ = try await connection.client.modelAction(value, "load")
      print("loaded \(value)")
    }
  }
  struct Unload: AsyncParsableCommand {
    @Option var dataRoot: String = ServiceFiles.defaultRoot
    @Argument var id: String
    mutating func run() async throws {
      guard let value = UUID(uuidString: id) else { throw ValidationError("Expected model UUID.") }
      let connection = try await Connection.open(root: dataRoot, executable: ExecutableLocation.current())
      defer { connection.worker?.requestStop() }
      _ = try await connection.client.modelAction(value, "unload")
      print("unloaded \(value)")
    }
  }
  struct DownloadAction: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "download")
    @Option var dataRoot: String = ServiceFiles.defaultRoot
    @Argument var id: String
    @Argument var action: String
    mutating func run() async throws {
      let connection = try await Connection.open(root: dataRoot, executable: ExecutableLocation.current())
      defer { connection.worker?.requestStop() }
      guard let operationID = UUID(uuidString: id) else { throw ValidationError("Expected a download UUID.") }
      _ = try await connection.client.downloadAction(operationID, action)
      if action == "discard" { print("discarded") }
      else { print(try await connection.client.download(operationID).phase.rawValue) }
      if action == "resume" { try await Models.awaitDownload(operationID, client: connection.client) }
    }
  }
  struct Sources: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show configured model sources.")
    @Option var dataRoot: String = ServiceFiles.defaultRoot
    mutating func run() async throws {
      let connection = try await Connection.open(root: dataRoot, executable: ExecutableLocation.current())
      defer { connection.worker?.requestStop() }
      let settings = try await connection.client.library().configuration
      for source in settings.registries {
        let mark = source.id == settings.defaultRegistryID ? "*" : " "
        let provenance = source.id == settings.defaultRegistryID
          ? " [default: \(settings.defaultProvenance.rawValue)]" : ""
        print("\(mark) \(source.id) \(source.name) \(source.provider.rawValue) \(source.origin.absoluteString)\(provenance)")
        if let mirror = source.mirror { print("    mirror: \(mirror.absoluteString)") }
        if source.credentialReference != nil { print("    source credential: Keychain") }
        if source.mirrorCredentialReference != nil { print("    mirror credential: Keychain") }
      }
    }
  }
  struct DefaultSource: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "default-source")
    @Option var dataRoot: String = ServiceFiles.defaultRoot
    @Argument var registryID: String
    mutating func run() async throws {
      guard let id = UUID(uuidString: registryID) else { throw ValidationError("Expected source UUID.") }
      let connection = try await Connection.open(root: dataRoot, executable: ExecutableLocation.current())
      defer { connection.worker?.requestStop() }
      let current = try await connection.client.library().configuration
      let updated = try await connection.client.setDefaultRegistry(.init(
        expectedRevision: current.revision, registryID: id))
      print("default source: \(updated.defaultRegistryID)")
    }
  }

}
