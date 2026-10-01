import Foundation
import MoxDomain

public enum Wire {
  public static let version = 1
  // Updated by the release build script together for the app and worker.
  public static let buildID = BuildIdentity.value
  public static let productVersion = BuildIdentity.productVersion
  public static let bodyLimit = 16 * 1024 * 1024
  public static let frameLimit = 1024 * 1024
  public static func encode<T: Encodable>(_ value: T) throws -> Data {
    try JSONEncoder().encode(value)
  }
  public static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
    try JSONDecoder().decode(type, from: data)
  }
}
public struct ServiceIdentity: Codable, Sendable, Equatable {
  public var instanceID: UUID
  public var pid: Int32
  public var uid: UInt32
  public var rootIdentity: String
  public var buildID: String = Wire.buildID
  public var protocolVersion: Int = Wire.version
  public var ownership: ServiceOwnership
  public init(
    instanceID: UUID = UUID(), pid: Int32, uid: UInt32, rootIdentity: String,
    ownership: ServiceOwnership
  ) {
    self.instanceID = instanceID
    self.pid = pid
    self.uid = uid
    self.rootIdentity = rootIdentity
    self.ownership = ownership
  }
}
public struct Discovery: Codable, Sendable {
  public var schema: Int = 1
  public var identity: ServiceIdentity
  public var privateEndpoint: String
  public var token: String
  public init(identity: ServiceIdentity, privateEndpoint: String, token: String) {
    self.identity = identity
    self.privateEndpoint = privateEndpoint
    self.token = token
  }
}
public struct PublicAPIStatus: Codable, Sendable {
  public let enabled: Bool
  public let endpoint: String?
  public let errorCode: String?
  /// Changes whenever the public credential changes. Contains no credential material.
  public let credentialID: UUID
  public init(enabled: Bool, endpoint: String?, errorCode: String?, credentialID: UUID = UUID()) {
    self.enabled = enabled
    self.endpoint = endpoint
    self.errorCode = errorCode
    self.credentialID = credentialID
  }
}
public struct PublicAPIChange: Codable, Sendable {
  public let enabled: Bool
  public init(enabled: Bool) { self.enabled = enabled }
}
public struct PublicAPIKey: Codable, Sendable {
  public let key: String
  public let credentialID: UUID
  public init(key: String, credentialID: UUID) {
    self.key = key
    self.credentialID = credentialID
  }
}
public struct WireMessage: Codable, Sendable {
  public struct Block: Codable, Sendable {
    public var type: String
    public var text: String
    public init(text: String) {
      type = "text"
      self.text = text
    }
  }
  public var role: String
  public var content: [Block]
  public init(_ message: Message) throws {
    role = message.role.rawValue
    content = [.init(text: try message.text())]
  }
  public func domain() throws -> Message {
    guard let role = Message.Role(rawValue: role), content.allSatisfy({ $0.type == "text" }) else {
      throw MoxError(.unsupportedInput, "Only text messages are supported.")
    }
    return Message(role: role, content: content.map { .text($0.text) })
  }
}
public struct GenerateBody: Codable, Sendable {
  public struct Model: Codable, Sendable {
    public var kind: String
    public var path: String
    public init(kind: String, path: String) {
      self.kind = kind
      self.path = path
    }
  }
  public struct Parameters: Codable, Sendable {
    public var maxTokens: Int?
    public var temperature: Float?
    public var topP: Float?
  }
  public var requestID: UUID
  public var model: Model
  public var messages: [WireMessage]
  public var sampling: Parameters
  public var samplingSettings: SamplingSettings {
    .init(maxTokens: sampling.maxTokens, temperature: sampling.temperature, topP: sampling.topP)
  }
  public init(path: String, request: GenerationRequest) throws {
    try self.init(model: Model(kind: "localDirectory", path: path), request: request)
  }
  public init(model: Model, request: GenerationRequest) throws {
    requestID = request.id
    self.model = model
    messages = try request.messages.map(WireMessage.init)
    sampling = Parameters(
      maxTokens: request.sampling.maxTokens, temperature: request.sampling.temperature,
      topP: request.sampling.topP)
  }
  public func domain(sampling resolved: Sampling? = nil) throws -> GenerationRequest {
    guard model.kind == "localDirectory" || model.kind == "installedAlias" else {
      throw MoxError(.unsupportedInput, "Select a local model directory or installed alias.")
    }
    return try GenerationRequest(
      id: requestID, messages: messages.map { try $0.domain() },
      sampling: try resolved ?? EffectiveSampling.resolve(request: samplingSettings).sampling())
  }
  public static func decode(_ data: Data) throws -> Self {
    func keys(_ object: Any?, _ allowed: Set<String>) throws -> [String: Any] {
      guard let value = object as? [String: Any], Set(value.keys).isSubset(of: allowed) else {
        throw MoxError(.invalidParameters, "Unknown or malformed request fields.")
      }
      return value
    }
    let root = try keys(
      JSONSerialization.jsonObject(with: data), ["requestID", "model", "messages", "sampling"])
    _ = try keys(root["model"], ["kind", "path"])
    _ = try keys(root["sampling"], ["maxTokens", "temperature", "topP"])
    for message in root["messages"] as? [Any] ?? [] {
      let m = try keys(message, ["role", "content"])
      for block in m["content"] as? [Any] ?? [] { _ = try keys(block, ["type", "text"]) }
    }
    return try Wire.decode(Self.self, data)
  }
}
public struct EventFrame: Codable, Sendable {
  public var instanceID: UUID
  public var requestID: UUID
  public var sequence: Int
  public var type: String
  public var phase: String?
  public var promptTokens: Int?
  public var text: String?
  public var toolCallID: String?
  public var toolName: String?
  public var toolArguments: String?
  public var stopSequence: String?
  public var usage: Usage?
  public var reason: FinishReason?
  public var error: MoxError?
  public init(instanceID: UUID, event: GenerationEvent) {
    self.instanceID = instanceID
    requestID = event.requestID
    sequence = event.sequence
    switch event.payload {
    case .phase(let value):
      type = "phase"
      phase = value
    case .promptTokens(let value):
      type = "promptTokens"
      promptTokens = value
    case .contentDelta(let value):
      type = "contentDelta"
      text = value
    case .toolCall(let id, let name, let arguments):
      type = "toolCall"
      toolCallID = id
      toolName = name
      toolArguments = arguments
    case .matchedStopSequence(let value):
      type = "matchedStopSequence"
      stopSequence = value
    case .usage(let value):
      type = "usage"
      usage = value
    case .finished(let value):
      type = "finished"
      reason = value
    case .failed(let value):
      type = "failed"
      error = value
    }
  }
  public func event() throws -> GenerationEvent {
    let payload: GenerationPayload
    switch type {
    case "phase" where phase != nil: payload = .phase(phase!)
    case "promptTokens" where promptTokens != nil: payload = .promptTokens(promptTokens!)
    case "contentDelta" where text != nil: payload = .contentDelta(text!)
    case "toolCall" where toolCallID != nil && toolName != nil && toolArguments != nil:
      payload = .toolCall(id: toolCallID!, name: toolName!, arguments: toolArguments!)
    case "matchedStopSequence" where stopSequence != nil:
      payload = .matchedStopSequence(stopSequence!)
    case "usage" where usage != nil: payload = .usage(usage!)
    case "finished" where reason != nil: payload = .finished(reason!)
    case "failed" where error != nil: payload = .failed(error!)
    default: throw MoxError(.protocolViolation, "Invalid generation event.")
    }
    return GenerationEvent(requestID: requestID, sequence: sequence, payload: payload)
  }
  public func sse() throws -> Data {
    var data = Data("event: generation\nid: \(sequence)\ndata: ".utf8)
    data.append(try Wire.encode(self))
    data.append(Data("\n\n".utf8))
    return data
  }
}
public struct RequestState: Codable, Sendable {
  public var requestID: UUID
  public var modelID: String
  public var phase: String
  public var stopping: Bool
  public var lastSequence: Int
  public var terminal: EventFrame?
  public var state: String { terminal == nil ? (stopping ? "stopping" : "running") : "stopped" }
  private enum CodingKeys: String, CodingKey {
    case requestID, modelID, phase, stopping, lastSequence, terminal, state
  }
  public func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(requestID, forKey: .requestID)
    try c.encode(modelID, forKey: .modelID)
    try c.encode(phase, forKey: .phase)
    try c.encode(stopping, forKey: .stopping)
    try c.encode(lastSequence, forKey: .lastSequence)
    try c.encodeIfPresent(terminal, forKey: .terminal)
    try c.encode(state, forKey: .state)
  }
  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    requestID = try c.decode(UUID.self, forKey: .requestID)
    modelID = try c.decode(String.self, forKey: .modelID)
    phase = try c.decode(String.self, forKey: .phase)
    stopping = try c.decode(Bool.self, forKey: .stopping)
    lastSequence = try c.decode(Int.self, forKey: .lastSequence)
    terminal = try c.decodeIfPresent(EventFrame.self, forKey: .terminal)
    guard try c.decode(String.self, forKey: .state) == state else {
      throw MoxError(.protocolViolation, "Inconsistent request state.")
    }
  }
  public init(
    requestID: UUID, modelID: String, phase: String = "accepted", stopping: Bool = false,
    lastSequence: Int = -1, terminal: EventFrame? = nil
  ) {
    self.requestID = requestID
    self.modelID = modelID
    self.phase = phase
    self.stopping = stopping
    self.lastSequence = lastSequence
    self.terminal = terminal
  }
}
public struct ModelState: Codable, Sendable {
  public var modelID: String
  public var state: String
  public var verifiedProfile: String
  public init(modelID: String, state: String, verifiedProfile: String = "unverified") {
    self.modelID = modelID
    self.state = state
    self.verifiedProfile = verifiedProfile
  }
}
public struct ServiceState: Codable, Sendable {
  public var instanceID: UUID
  public var revision: UInt64
  public var serviceState: String
  public var ownership: ServiceOwnership
  public var residentModels: Int
  public var reservedBytes: Int
  public var activeLeases: Int
  public var queued: Int
  public var budgetBytes: Int
  public var queueCapacity: Int
  public var queueTimeoutSeconds: Int
  public var libraryRecovery: LibraryRecoveryState
  public var activeDownloads: Int
  public var models: [ModelState]
  public var requests: [RequestState]
  public init(
    instanceID: UUID, revision: UInt64, serviceState: String, ownership: ServiceOwnership,
    residentModels: Int, reservedBytes: Int, activeLeases: Int, queued: Int,
    budgetBytes: Int, queueCapacity: Int, queueTimeoutSeconds: Int,
    activeDownloads: Int, models: [ModelState],
    requests: [RequestState], libraryRecovery: LibraryRecoveryState = .init()
  ) {
    self.instanceID = instanceID
    self.revision = revision
    self.serviceState = serviceState
    self.ownership = ownership
    self.residentModels = residentModels
    self.reservedBytes = reservedBytes
    self.activeLeases = activeLeases
    self.queued = queued
    self.budgetBytes = budgetBytes
    self.queueCapacity = queueCapacity
    self.queueTimeoutSeconds = queueTimeoutSeconds
    self.libraryRecovery = libraryRecovery
    self.activeDownloads = activeDownloads
    self.models = models
    self.requests = requests
  }
}
public struct ErrorEnvelope: Codable, Sendable {
  public var instanceID: UUID
  public var requestID: UUID?
  public var error: MoxError
  public init(instanceID: UUID, requestID: UUID? = nil, error: MoxError) {
    self.instanceID = instanceID
    self.requestID = requestID
    self.error = error
  }
}

public struct PullBody: Codable, Sendable {
  public let provider: ModelProvider
  public let endpoint: URL
  public let registryID: UUID
  public let repository: String
  public let selector: String
  public let variant: String
  public init(
    provider: ModelProvider, endpoint: URL, registryID: UUID, repository: String, selector: String,
    variant: String = ""
  ) {
    self.variant = variant
    self.provider = provider
    self.endpoint = endpoint
    self.registryID = registryID
    self.repository = repository
    self.selector = selector
  }
}
public struct DownloadCreated: Codable, Sendable {
  public let id: UUID
  public init(id: UUID) { self.id = id }
}

public struct RegistryUpdate: Codable, Sendable {
  public let expectedRevision: UInt64
  public let registry: ModelRegistry
  public let credential: String?
  public let mirrorCredential: String?
  public init(
    expectedRevision: UInt64, registry: ModelRegistry,
    credential: String? = nil, mirrorCredential: String? = nil
  ) {
    self.expectedRevision = expectedRevision
    self.registry = registry
    self.credential = credential
    self.mirrorCredential = mirrorCredential
  }
}

public struct SamplingResolutionBody: Codable, Sendable {
  public let model: GenerateBody.Model
  public let explicit: SamplingSettings
  public init(model: GenerateBody.Model, explicit: SamplingSettings = .init()) {
    self.model = model
    self.explicit = explicit
  }
}
public struct GlobalSamplingUpdate: Codable, Sendable {
  public let expectedRevision: UInt64
  public let settings: SamplingSettings
  public init(expectedRevision: UInt64, settings: SamplingSettings) {
    self.expectedRevision = expectedRevision
    self.settings = settings
  }
}
public struct ModelSamplingUpdate: Codable, Sendable {
  public let expectedRevision: UInt64
  public let settings: SamplingSettings
  public init(expectedRevision: UInt64, settings: SamplingSettings) {
    self.expectedRevision = expectedRevision
    self.settings = settings
  }
}
public struct ModelPinUpdate: Codable, Sendable {
  public let expectedRevision: UInt64
  public let pinned: Bool
  public init(expectedRevision: UInt64, pinned: Bool) {
    self.expectedRevision = expectedRevision
    self.pinned = pinned
  }
}

public struct ModelImportBody: Codable, Sendable {
  public let path: String
  public let alias: String
  public init(path: String, alias: String) {
    self.path = path
    self.alias = alias
  }
}

public struct DefaultRegistryUpdate: Codable, Sendable {
  public let expectedRevision: UInt64
  public let registryID: UUID
  public init(expectedRevision: UInt64, registryID: UUID) {
    self.expectedRevision = expectedRevision
    self.registryID = registryID
  }
}
