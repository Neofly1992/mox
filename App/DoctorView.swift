import AppKit
import MoxBootstrap
import MoxChat
import MoxClient
import MoxDomain
import MoxProtocol
import SwiftUI

struct DoctorView: View {
  let chat: ChatController
  @State private var report: DoctorReport?
  @State private var running: Task<Void, Never>?
  @State private var progress = ""
  @State private var modelAlias = ""
  @State private var repository = ""
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("环境诊断").font(.title2)
      Text("只读检查，不自动启动服务、修复、下载权重或加载模型。运行 App 无需开发工具。")
        .foregroundStyle(.secondary)
      TextField("完整性检查：安装模型标识（可选，可能耗时）", text: $modelAlias)
      TextField("联网检查：默认来源的 owner/repository（可选）", text: $repository)
      HStack {
        Button("开始诊断") { start() }.disabled(running != nil).accessibilityIdentifier("runDoctor")
        Button("取消") { running?.cancel() }.disabled(running == nil)
        Button("导出本次检查…") {
          guard let report else { return }
          let panel = NSSavePanel()
          panel.nameFieldStringValue = "mox-doctor.json"
          if panel.runModal() == .OK, let url = panel.url {
            do { try Wire.encode(report).write(to: url, options: .atomic) } catch {
              chat.error = "无法导出本次检查。"
            }
          }
        }.disabled(report == nil || running != nil)
        if running != nil {
          ProgressView().controlSize(.small)
          Text(progress).font(.caption)
        }
      }
      if let report {
        List(report.results, id: \.id) { result in
          VStack(alignment: .leading, spacing: 4) {
            Text("\(result.id) · \(result.status.userLabel)").font(.headline)
            Text(result.reason)
            if !result.suggestion.isEmpty { Text(result.suggestion).foregroundStyle(.secondary) }
          }.padding(.vertical, 5)
        }.accessibilityIdentifier("doctorResults")
      }
      Text("失败时使用侧栏“导出诊断”；错误码与阶段保留，私人内容和敏感路径不导出。")
        .font(.caption).foregroundStyle(.secondary)
    }.padding(24).onDisappear { running?.cancel() }
  }
  private func start() {
    report = nil
    let root = chat.root
    let worker = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/MoxWorker.app/Contents/MacOS/mox")
    let alias = modelAlias
    let repository = repository
    running = Task {
      var checks = DoctorChecks.local(root: root, worker: worker, appBundle: Bundle.main.bundleURL)
      checks += DoctorChecks.extensions(
        root: root,
        model: alias.isEmpty ? nil : .init(kind: "installedAlias", path: alias),
        sourceRepository: repository.isEmpty ? nil : repository)
      report = await DoctorRunner.run(checks) { id in await MainActor.run { progress = id } }
      running = nil
    }
  }
}

struct ResourcePreview: View {
  let chat: ChatController
  let model: GenerateBody.Model
  let explicit: SamplingSettings
  @State private var assessment: ResourceAssessment?
  @State private var failed = false
  var body: some View {
    Group {
      if let assessment {
        Text("\(assessment.status.userLabel) · \(assessment.summary)")
      } else {
        Text(failed ? "无法取得内存评估；运行时仍须安全准入。" : "正在评估内存…")
      }
    }.font(.caption).foregroundStyle(.secondary)
      .task(
        id:
          "\(model.path):\(explicit):\(chat.serviceState?.instanceID.uuidString ?? "disconnected")"
      ) {
        assessment = nil
        failed = false
        guard let client = chat.connection?.client else {
          failed = true
          return
        }
        do {
          let value = try await client.assessResources(.init(model: model, explicit: explicit))
          guard !Task.isCancelled else { return }
          assessment = value
        } catch { if !Task.isCancelled { failed = true } }
      }
  }
}

// Stable wire values stay language-independent; the native UI names the product states.
extension ResourceStatus {
  var userLabel: String {
    switch self {
    case .recommended: "推荐配置"
    case .constrained: "资源紧张"
    case .exceedsBudget: "超出安全预算"
    case .unknown: "无法可靠估算"
    }
  }
}
extension DoctorStatus {
  var userLabel: String {
    switch self {
    case .passed: "通过"
    case .warning: "需注意"
    case .failed: "失败"
    case .skipped: "未检查"
    case .timedOut: "超时"
    case .cancelled: "已取消"
    }
  }
}
