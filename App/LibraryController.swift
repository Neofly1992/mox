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
  private var diagnostics: ChatController?
  private func show(_ failure: Error, stage: String, operationID: UUID? = nil) {
    diagnostics?.recordOperationFailure(failure, stage: stage, operationID: operationID)
    error = (failure as? MoxError)?.description ?? "操作失败，请导出诊断。"
  }
  func refresh(using chat: ChatController, clearErrorOnSuccess: Bool = false) async {
    diagnostics = chat
    guard let connection = chat.connection, chat.servicePhase == "running" else { return }
    do {
      client = connection.client
      let page = try await connection.client.library(
        installationOffset: snapshot.installationOffset,
        operationOffset: snapshot.operationOffset)
      snapshot =
        page.installations.isEmpty && page.totalInstallations > 0
          || page.operations.isEmpty && page.totalOperations > 0
        ? try await connection.client.library() : page
      if clearErrorOnSuccess { error = nil }
    } catch { show(error, stage: "library.refresh") }
  }
  func pull(
    using chat: ChatController, provider: ModelProvider, repository: String,
    selector: String, variant: String, endpoint: String, mirror: String, credential: String,
    mirrorCredential: String
  ) async {
    guard !busy, let client = chat.connection?.client else { return }
    busy = true
    defer { busy = false }
    do {
      error = nil
      let body = try await configuredPull(
        client: client, provider: provider,
        repository: repository, selector: selector, variant: variant, endpoint: endpoint,
        mirror: mirror, credential: credential, mirrorCredential: mirrorCredential)
      _ = try await client.pull(body)
      snapshot = try await client.library()
    } catch { show(error, stage: "download.create") }
  }
  func plan(
    using chat: ChatController, provider: ModelProvider, repository: String,
    selector: String, variant: String, endpoint: String, mirror: String, credential: String,
    mirrorCredential: String
  ) async -> ModelDownloadPlanSummary? {
    guard !busy, let client = chat.connection?.client else { return nil }
    busy = true
    defer { busy = false }
    do {
      error = nil
      let body = try await configuredPull(
        client: client, provider: provider,
        repository: repository, selector: selector, variant: variant, endpoint: endpoint,
        mirror: mirror, credential: credential, mirrorCredential: mirrorCredential)
      let plan = try await client.planPull(body)
      snapshot = try await client.library()
      return plan
    } catch {
      show(error, stage: "download.plan")
      return nil
    }
  }
  private func configuredPull(
    client: ServiceClient, provider: ModelProvider,
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
      id: existing?.id ?? UUID(),
      name: existing?.name ?? (provider == .huggingFace ? "Hugging Face" : "ModelScope"),
      provider: provider, origin: origin, mirror: mirrorURL)
    if existing == nil || existing?.mirror != mirrorURL || !credential.isEmpty
      || !mirrorCredential.isEmpty
    {
      _ = try await client.updateRegistry(
        .init(
          expectedRevision: current.configuration.revision, registry: registry,
          credential: credential.isEmpty ? nil : credential,
          mirrorCredential: mirrorCredential.isEmpty ? nil : mirrorCredential))
    }
    return .init(
      provider: provider, endpoint: mirrorURL ?? origin, registryID: registry.id,
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
      show(error, stage: "model.import")
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
    } catch { show(error, stage: "model.\(name)", operationID: id) }
  }
  func setGlobalSampling(_ settings: SamplingSettings) async throws {
    guard !busy else { throw MoxError(.busy, "已有操作正在提交，请稍后重试。") }
    guard let client else { throw MoxError(.connectionLost, "服务未连接，请恢复连接后重试。") }
    busy = true
    defer { busy = false }
    do {
      _ = try await client.setGlobalSampling(
        .init(
          expectedRevision: snapshot.configuration.revision, settings: settings))
    } catch {
      show(error, stage: "sampling.global")
      throw error
    }
    do {
      snapshot = try await client.library(
        installationOffset: snapshot.installationOffset,
        operationOffset: snapshot.operationOffset)
      error = nil
    } catch { show(error, stage: "sampling.refresh") }
  }
  func setModelSampling(_ id: UUID, settings: SamplingSettings) async throws {
    guard !busy else { throw MoxError(.busy, "已有操作正在提交，请稍后重试。") }
    guard let client else { throw MoxError(.connectionLost, "服务未连接，请恢复连接后重试。") }
    busy = true
    defer { busy = false }
    do {
      _ = try await client.setModelSampling(
        id,
        .init(
          expectedRevision: snapshot.configuration.revision, settings: settings))
    } catch {
      show(error, stage: "sampling.model", operationID: id)
      throw error
    }
    do {
      snapshot = try await client.library(
        installationOffset: snapshot.installationOffset,
        operationOffset: snapshot.operationOffset)
      error = nil
    } catch { show(error, stage: "sampling.refresh", operationID: id) }
  }
  func setPinned(_ id: UUID, pinned: Bool) async {
    guard !busy, let client else { return }
    busy = true
    defer { busy = false }
    do {
      _ = try await client.setModelPinned(
        id,
        .init(
          expectedRevision: snapshot.configuration.revision, pinned: pinned))
      snapshot = try await client.library(
        installationOffset: snapshot.installationOffset,
        operationOffset: snapshot.operationOffset)
      error = nil
    } catch { show(error, stage: "model.pin", operationID: id) }
  }
  func removeModel(_ id: UUID) async {
    guard !busy, let client else { return }
    busy = true
    defer { busy = false }
    do {
      error = nil
      snapshot = try await client.removeModel(id)
    } catch { show(error, stage: "model.remove", operationID: id) }
  }
  func selectModel(_ id: UUID) async {
    guard !busy, let client else { return }
    busy = true
    defer { busy = false }
    do {
      error = nil
      snapshot = try await client.selectModel(id)
    } catch { show(error, stage: "model.select", operationID: id) }
  }
  func action(_ name: String, id: UUID) async {
    guard !busy, let client else { return }
    busy = true
    defer { busy = false }
    do {
      error = nil
      snapshot = try await client.downloadAction(id, name)
    } catch { show(error, stage: "download.\(name)", operationID: id) }
  }
  func page(installations: Int? = nil, operations: Int? = nil) async {
    guard let client else { return }
    do {
      snapshot = try await client.library(
        installationOffset: installations ?? snapshot.installationOffset,
        operationOffset: operations ?? snapshot.operationOffset)
      error = nil
    } catch { show(error, stage: "library.page") }
  }
}
