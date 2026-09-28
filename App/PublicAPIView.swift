import AppKit
import MoxChat
import MoxProtocol
import Observation
import SwiftUI

@MainActor @Observable private final class PublicAPIController {
  var status = PublicAPIStatus(enabled: false, endpoint: nil, errorCode: nil)
  var key: String?
  var error: String?
  var busy = false
  func refresh(chat: ChatController) async {
    guard let client = chat.connection?.client else { return }
    do {
      let updated = try await client.publicAPIStatus()
      if updated.credentialID != status.credentialID { key = nil }
      status = updated
      error = nil
    }
    catch { self.error = String(describing: error) }
  }
  func toggle(chat: ChatController) async {
    guard !busy, let client = chat.connection?.client else { return }
    busy = true
    defer { busy = false }
    do {
      status = try await client.setPublicAPIEnabled(!status.enabled)
      key = nil
      error = nil
    } catch { self.error = String(describing: error) }
  }
  func reveal(chat: ChatController) async {
    guard let client = chat.connection?.client else { return }
    do {
      let result = try await client.publicAPIKey()
      key = result.key
      status = PublicAPIStatus(enabled: status.enabled, endpoint: status.endpoint,
        errorCode: status.errorCode, credentialID: result.credentialID)
      error = nil
    }
    catch { self.error = String(describing: error) }
  }
  func rotate(chat: ChatController) async {
    guard !busy, let client = chat.connection?.client else { return }
    busy = true
    defer { busy = false }
    do {
      let result = try await client.rotatePublicAPIKey()
      key = result.key
      status = PublicAPIStatus(enabled: status.enabled, endpoint: status.endpoint,
        errorCode: status.errorCode, credentialID: result.credentialID)
      error = nil
    }
    catch { self.error = String(describing: error) }
  }
}

struct PublicAPIView: View {
  @Bindable var chat: ChatController
  @State private var control = PublicAPIController()
  var body: some View {
    Form {
      Section("本机 API") {
        LabeledContent("状态", value: control.status.enabled ? "运行中" : "已关闭")
        if let endpoint = control.status.endpoint {
          LabeledContent("连接地址", value: endpoint + "/v1")
            .textSelection(.enabled)
          Button("复制连接地址") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(endpoint + "/v1", forType: .string)
          }
        }
        if let code = control.status.errorCode {
          Text("启动错误：\(code)").foregroundStyle(.red)
        }
        Button(control.status.enabled ? "关闭 API" : "开启 API") {
          Task { await control.toggle(chat: chat) }
        }.disabled(control.busy || chat.connection == nil)
          .accessibilityIdentifier("togglePublicAPI")
      }
      Section("访问密钥") {
        Text("密钥与管理服务凭据独立，默认隐藏。重置后旧密钥立即失效。")
          .foregroundStyle(.secondary)
        if let key = control.key {
          Text(key).font(.system(.body, design: .monospaced)).textSelection(.enabled)
          Button("复制密钥") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key, forType: .string)
          }
        }
        HStack {
          Button("显示密钥") { Task { await control.reveal(chat: chat) } }
          Button("重置密钥") { Task { await control.rotate(chat: chat) } }
        }.disabled(chat.connection == nil)
      }
      Section("连接示例") {
        Text("OpenAI SDK：base_url 设为上方地址，api_key 设为此处密钥；调用 chat.completions.create。")
        Text("Anthropic SDK：base_url 设为上方地址去掉 /v1，api_key 设为此处密钥；调用 messages.create。")
        Text("model 使用模型页显示的已安装别名。API 请求不会写入测试会话。")
      }
      if let error = control.error {
        Section("诊断") { Text(error).foregroundStyle(.red).textSelection(.enabled) }
      }
    }
    .padding()
    .task {
      while !Task.isCancelled {
        await control.refresh(chat: chat)
        try? await Task.sleep(for: .seconds(2))
      }
    }
  }
}
