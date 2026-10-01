import Foundation
import MoxDomain
import Observation

/// Editor state survives rejected saves and excludes overlapping submissions.
@MainActor @Observable public final class SamplingSettingsDraft {
  public var maxTokens: String
  public var temperature: String
  public var topP: String
  public private(set) var saving = false
  public private(set) var error: String?
  public init(_ initial: SamplingSettings) {
    maxTokens = initial.maxTokens.map(String.init) ?? ""
    temperature = initial.temperature.map { String($0) } ?? ""
    topP = initial.topP.map { String($0) } ?? ""
  }
  public func save(using submit: @MainActor (SamplingSettings) async throws -> Void) async -> Bool {
    guard !saving else { return false }
    let settings = SamplingSettings(
      maxTokens: maxTokens.isEmpty ? nil : Int(maxTokens),
      temperature: temperature.isEmpty ? nil : Float(temperature),
      topP: topP.isEmpty ? nil : Float(topP))
    guard maxTokens.isEmpty || settings.maxTokens != nil,
      temperature.isEmpty || settings.temperature != nil, topP.isEmpty || settings.topP != nil
    else {
      error = "请输入有效数字，或留空继承。"
      return false
    }
    do { try settings.validate() } catch {
      self.error = "参数超出允许范围。"
      return false
    }
    saving = true
    error = nil
    defer { saving = false }
    do {
      try await submit(settings)
      return true
    } catch {
      self.error =
        ((error as? MoxError)?.description ?? "保存失败。")
        + " 输入已保留；恢复连接或刷新配置后可重试。"
      return false
    }
  }
}
