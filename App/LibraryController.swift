import Foundation
import MoxChat
import MoxClient
import MoxDomain
import MoxProtocol
import Observation

@MainActor @Observable final class LibraryController {
  var snapshot = ModelLibraryPage(ModelLibrarySnapshot())
  var error: String?
  var busy = false
  private var client: ServiceClient?
  func refresh(using chat: ChatController) async {
    guard let connection = chat.connection, chat.servicePhase == "running" else { return }
    do {
      client = connection.client
      let page = try await connection.client.library(
        installationOffset: snapshot.installationOffset,
        operationOffset: snapshot.operationOffset)
      snapshot = page.installations.isEmpty && page.totalInstallations > 0
        || page.operations.isEmpty && page.totalOperations > 0
        ? try await connection.client.library() : page
    } catch { self.error = String(describing: error) }
  }
  func pull(using chat: ChatController, provider: ModelProvider, repository: String,
    selector: String, variant: String, endpoint: String, mirror: String, credential: String,
    mirrorCredential: String
  ) async {
    guard !busy, let client = chat.connection?.client else { return }
    busy = true
    defer { busy = false }
    do {
      error = nil
      let body = try await configuredPull(client: client, provider: provider,
        repository: repository, selector: selector, variant: variant, endpoint: endpoint,
        mirror: mirror, credential: credential, mirrorCredential: mirrorCredential)
      _ = try await client.pull(body)
      snapshot = try await client.library()
    } catch { self.error = String(describing: error) }
  }
  func plan(using chat: ChatController, provider: ModelProvider, repository: String,
    selector: String, variant: String, endpoint: String, mirror: String, credential: String,
    mirrorCredential: String
  ) async -> ModelDownloadPlanSummary? {
    guard !busy, let client = chat.connection?.client else { return nil }
    busy = true
    defer { busy = false }
    do {
      error = nil
      let body = try await configuredPull(client: client, provider: provider,
        repository: repository, selector: selector, variant: variant, endpoint: endpoint,
        mirror: mirror, credential: credential, mirrorCredential: mirrorCredential)
      let plan = try await client.planPull(body)
      snapshot = try await client.library()
      return plan
    } catch {
      self.error = String(describing: error)
      return nil
    }
  }
  private func configuredPull(client: ServiceClient, provider: ModelProvider,
    repository: String, selector: String, variant: String, endpoint: String,
    mirror: String, credential: String, mirrorCredential: String
  ) async throws -> PullBody {
    guard let origin = URL(string: endpoint) else {
      throw MoxError(.invalidParameters, "来源地址不是有效 URL。")
    }
    let mirrorURL = mirror.isEmpty ? nil : URL(string: mirror)
    guard mirror.isEmpty || mirrorURL != nil else {
      throw MoxError(.invalidParameters, "镜像地址不是有效 URL。")
    }
    let current = try await client.library()
    let existing = current.configuration.registries.first {
      $0.provider == provider && $0.origin == origin
    }
    let registry = ModelRegistry(
      id: existing?.id ?? UUID(), name: existing?.name ?? (provider == .huggingFace ? "Hugging Face" : "ModelScope"),
      provider: provider, origin: origin, mirror: mirrorURL)
    if existing == nil || existing?.mirror != mirrorURL || !credential.isEmpty || !mirrorCredential.isEmpty {
      _ = try await client.updateRegistry(.init(
        expectedRevision: current.configuration.revision, registry: registry,
        credential: credential.isEmpty ? nil : credential,
        mirrorCredential: mirrorCredential.isEmpty ? nil : mirrorCredential))
    }
    return .init(provider: provider, endpoint: mirrorURL ?? origin, registryID: registry.id,
      repository: repository, selector: selector, variant: variant)
  }
  func importDirectory(using chat: ChatController, path: String) async -> String? {
    guard let client = chat.connection?.client else { return nil }
    do {
      error = nil
      let installed = try await client.importModel(
        path: path, alias: URL(fileURLWithPath: path).lastPathComponent)
      snapshot = try await client.library()
      return installed.path
    } catch {
      self.error = String(describing: error)
      return nil
    }
  }
  func modelAction(_ name: String, id: UUID) async {
    guard !busy, let client else { return }
    busy = true
    defer { busy = false }
    do {
      error = nil
      _ = try await client.modelAction(id, name)
    } catch { self.error = String(describing: error) }
  }
  func removeModel(_ id: UUID) async {
    guard !busy, let client else { return }
    busy = true
    defer { busy = false }
    do {
      error = nil
      snapshot = try await client.removeModel(id)
    } catch { self.error = String(describing: error) }
  }
  func selectModel(_ id: UUID) async {
    guard !busy, let client else { return }
    busy = true
    defer { busy = false }
    do {
      error = nil
      snapshot = try await client.selectModel(id)
    } catch { self.error = String(describing: error) }
  }
  func action(_ name: String, id: UUID) async {
    guard !busy, let client else { return }
    busy = true
    defer { busy = false }
    do {
      error = nil
      snapshot = try await client.downloadAction(id, name)
    } catch { self.error = String(describing: error) }
  }
  func page(installations: Int? = nil, operations: Int? = nil) async {
    guard let client else { return }
    do {
      snapshot = try await client.library(
        installationOffset: installations ?? snapshot.installationOffset,
        operationOffset: operations ?? snapshot.operationOffset)
      error = nil
    } catch { self.error = String(describing: error) }
  }
}
