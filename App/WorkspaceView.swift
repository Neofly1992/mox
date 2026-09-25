import AppKit
import MoxChat
import MoxDomain
import SwiftUI

/// Global navigation owns presentation only; the chat controller owns requests and history.
struct WorkspaceView: View {
  enum Section: String, CaseIterable, Identifiable {
    case models = "模型"
    case testing = "测试"
    case downloads = "下载任务"
    var id: Self { self }
    var symbol: String { self == .models ? "square.stack.3d.up" : self == .downloads ? "arrow.down.circle" : "flask" }
  }
  @Bindable var chat: ChatController
  @Binding var section: Section?
  @State private var library = LibraryController()
  @State private var detailPath: String?
  @State private var showingAcquire = false
  @State private var removal: ModelInstallationSummary?

  private var paths: [String] {
    var seen = Set<String>()
    return ([chat.modelPath] + chat.conversations.map(\.modelPath)).filter {
      !$0.isEmpty && seen.insert($0).inserted
    }
  }
  var body: some View {
    NavigationSplitView {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(Section.allCases) { item in
          Button { section = item } label: {
            Label(item.rawValue, systemImage: item.symbol)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 10)
              .padding(.vertical, 8)
              .background((section ?? .models) == item ? Color.accentColor.opacity(0.16) : .clear)
              .clipShape(RoundedRectangle(cornerRadius: 8))
          }
            .buttonStyle(.plain)
            .accessibilityIdentifier(item == .models ? "modelsNavigation" : item == .downloads ? "downloadsNavigation" : "testingNavigation")
        }
        Spacer(minLength: 0)
      }.padding(8)
      .navigationSplitViewColumnWidth(min: 140, ideal: 170, max: 210)
      .safeAreaInset(edge: .bottom) {
        ServiceControls(chat: chat).padding()
      }
    } detail: {
      switch section ?? .models {
      case .models: models
      case .testing: ChatView(chat: chat)
      case .downloads: downloads
      }
    }
    .task {
      while !Task.isCancelled {
        await library.refresh(using: chat)
        try? await Task.sleep(for: .seconds(1))
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: .moxNewTest)) { _ in
      section = .testing
      Task { await chat.newConversation() }
    }
  }
  private var models: some View {
    VStack(alignment: .leading, spacing: 20) {
      HStack {
        if detailPath != nil {
          Button("返回模型", systemImage: "chevron.left") { detailPath = nil }
        }
        Text(detailPath == nil ? "模型" : "本地模型").font(.title2)
        Spacer()
        Button("获取模型…") { showingAcquire = true }
        Button("添加本地目录…") { chooseModel() }
          .disabled(chat.isWorking || chat.isClosing).accessibilityIdentifier("chooseModel")
      }
      if let path = detailPath {
        Text(URL(fileURLWithPath: path).lastPathComponent).font(.title)
        Text(path).foregroundStyle(.secondary).textSelection(.enabled)
        let installation = library.snapshot.installations.first(where: { $0.path == path })
        GroupBox("本地文件") {
        Text(installation?.origin == nil
            ? "本地目录引用 · 文件由你管理。发送请求时验证路径，不复制或改写模型。"
            : "Mox 托管安装 · 删除此模型会移除受管文件；发送请求时验证路径。")
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        if let item = installation {
          GroupBox("安装信息") {
            VStack(alignment: .leading, spacing: 6) {
              if let origin = item.origin {
                Text("来源：\(origin.repository)")
                Text("精确版本：\(origin.revision)")
                Text(item.alias == origin.preferredAlias ? "当前版本" : "保留的旧版本")
                Text("文件大小：\(ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file))")
              } else { Text("本地目录引用；移除不会删除原文件。") }
              Text("状态：\(item.availability.rawValue)")
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
          }
          HStack {
            Button("加载") { Task { await library.modelAction("load", id: item.id) } }
              .disabled(item.availability != .ready)
            Button("卸载") { Task { await library.modelAction("unload", id: item.id) } }
              .disabled(item.availability != .ready)
            if let origin = item.origin, item.alias != origin.preferredAlias {
              Button("设为当前版本") { Task { await library.selectModel(item.id) } }
                .disabled(item.availability != .ready)
            }
            Button(item.origin == nil ? "移除引用…" : "删除托管模型…", role: .destructive) {
              removal = item
            }
          }.disabled(chat.isWorking || library.busy)
        }
        GroupBox("运行") {
          Text(runtimeLabel(path))
            .frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        Button("测试此模型") {
          chat.modelPath = path
          Task {
            await chat.newConversation()
            section = .testing
          }
        }.buttonStyle(.borderedProminent)
          .disabled(chat.isWorking || chat.isClosing || !chat.storageAvailable)
          .accessibilityIdentifier("testSelectedModel")
      } else if paths.isEmpty && library.snapshot.installations.isEmpty {
        ContentUnavailableView(
          "添加一个本地模型", systemImage: "cpu",
          description: Text("选择已有 MLX 模型目录，随后进入测试。模型文件保持原样。"))
      } else {
        if !library.snapshot.installations.isEmpty {
          Text("已安装模型").foregroundStyle(.secondary)
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
              ForEach(library.snapshot.installations) { item in
                HStack(alignment: .center, spacing: 12) {
                  VStack(alignment: .leading) {
                Text(item.origin?.repository ?? item.alias).font(.headline)
                if let origin = item.origin {
                  Text("版本 \(origin.revision.prefix(12))")
                    .font(.caption).foregroundStyle(.secondary)
                  if item.alias == origin.preferredAlias {
                    Text("当前版本").font(.caption).foregroundStyle(.green)
                  }
                }
                Text(item.path).font(.caption).foregroundStyle(.secondary)
                if item.availability != .ready {
                  Text(item.availability == .corrupt ? "文件损坏 · 不可运行" : "文件缺失 · 不可运行")
                    .font(.caption).foregroundStyle(.red)
                }
                  }.frame(maxWidth: .infinity, alignment: .leading)
                  Button("查看详情") { detailPath = item.path }
                    .accessibilityIdentifier("installedModelDetails")
                }.padding(8)
              }
            }
          }.frame(minHeight: 100, maxHeight: 220)
          HStack {
            Button("上一页") { Task { await library.page(installations: max(0, library.snapshot.installationOffset - ModelLibraryPage.pageSize)) } }
              .disabled(library.snapshot.installationOffset == 0)
            Text("\(library.snapshot.installationOffset + 1)–\(library.snapshot.installationOffset + library.snapshot.installations.count) / \(library.snapshot.totalInstallations)")
            Button("下一页") { Task { await library.page(installations: library.snapshot.installationOffset + library.snapshot.installations.count) } }
              .disabled(library.snapshot.installationOffset + library.snapshot.installations.count >= library.snapshot.totalInstallations)
          }
        }
        Text("最近使用的本地目录").foregroundStyle(.secondary)
        List(paths, id: \.self) { path in
          Button {
            detailPath = path
          } label: {
            VStack(alignment: .leading, spacing: 6) {
              Text(URL(fileURLWithPath: path).lastPathComponent).font(.headline)
              Text(path).font(.caption).foregroundStyle(.secondary)
              Text("本地引用 · 发送时验证 · \(runtimeLabel(path))").font(.caption).foregroundStyle(
                .secondary)
            }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
          }.buttonStyle(.plain).accessibilityIdentifier("localModelRow")
        }.listStyle(.inset)
      }
      if !library.snapshot.configuration.registries.isEmpty {
        GroupBox("模型来源") {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(library.snapshot.configuration.registries) { registry in
              let isDefault = registry.id == library.snapshot.configuration.defaultRegistryID
              Text("\(registry.name) · \(registry.provider.rawValue)\(isDefault ? " · 默认（\(library.snapshot.configuration.defaultProvenance == .product ? "产品" : "用户设置")）" : "")")
                .font(.caption)
              Text(registry.origin.absoluteString).font(.caption2).foregroundStyle(.secondary)
              if let mirror = registry.mirror {
                Text("镜像：\(mirror.absoluteString)").font(.caption2).foregroundStyle(.secondary)
              }
              if registry.credentialReference != nil || registry.mirrorCredentialReference != nil {
                Text("凭据存于 Keychain").font(.caption2).foregroundStyle(.secondary)
              }
            }
          }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
      }
      if let error = chat.error {
        Text(error).foregroundStyle(.red).textSelection(.enabled)
          .accessibilityIdentifier("appError")
      }
      Spacer(minLength: 0)
    }.padding(24)
    .sheet(isPresented: $showingAcquire) { AcquireModelSheet(chat: chat, library: library) }
    .confirmationDialog(
      removal?.origin == nil ? "移除本地引用？原文件会保留。" : "删除 Mox 托管模型文件？",
      isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } })
    ) {
      Button("确认移除", role: .destructive) {
        guard let item = removal else { return }
        removal = nil
        Task {
          await library.removeModel(item.id)
          if library.error == nil { detailPath = nil }
        }
      }
    }
  }
  private var downloads: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("下载任务").font(.title2)
      if library.snapshot.operations.isEmpty {
        ContentUnavailableView("暂无下载任务", systemImage: "arrow.down.circle")
      } else {
        List(library.snapshot.operations) { operation in
          VStack(alignment: .leading, spacing: 8) {
            Text(operation.origin.repository).font(.headline)
            Text("版本 \(operation.origin.revision)").font(.caption).textSelection(.enabled)
            Text("\(operation.phase.rawValue) · 已校验 \(ByteCountFormatter.string(fromByteCount: operation.verifiedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: operation.totalBytes, countStyle: .file))")
              .accessibilityIdentifier("downloadPhase-\(operation.phase.rawValue)")
            if let code = operation.errorCode { Text(code).foregroundStyle(.red) }
            HStack {
              if operation.phase == .downloading {
                Button("暂停") { Task { await library.action("pause", id: operation.id) } }
              }
              if [.paused, .interrupted, .failed].contains(operation.phase) {
                Button("继续") { Task { await library.action("resume", id: operation.id) } }
              }
              if operation.phase != .installed && operation.phase != .committing {
                Button("取消") { Task { await library.action("cancel", id: operation.id) } }
              }
              if operation.phase == .cancelled {
                Button("清理未完成文件") { Task { await library.action("discard", id: operation.id) } }
              }
            }
          }.padding(.vertical, 8)
        }
        HStack {
          Button("上一页") { Task { await library.page(operations: max(0, library.snapshot.operationOffset - ModelLibraryPage.pageSize)) } }
            .disabled(library.snapshot.operationOffset == 0)
          Text("\(library.snapshot.operationOffset + 1)–\(library.snapshot.operationOffset + library.snapshot.operations.count) / \(library.snapshot.totalOperations)")
          Button("下一页") { Task { await library.page(operations: library.snapshot.operationOffset + library.snapshot.operations.count) } }
            .disabled(library.snapshot.operationOffset + library.snapshot.operations.count >= library.snapshot.totalOperations)
        }
      }
      if let error = library.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
    }.padding(24)
  }
  private func runtimeLabel(_ path: String) -> String {
    switch chat.modelState(for: path) {
    case "ready": "已加载"
    case "loading": "正在加载"
    case "unloaded": "未加载 · 测试时自动加载"
    case .none: "运行状态待确认"
    default: "运行状态更新中"
    }
  }
  private func chooseModel() {
    ModelDirectoryPicker.present { path in
      Task {
        guard let installedPath = await library.importDirectory(using: chat, path: path) else { return }
        chat.modelPath = installedPath
        detailPath = installedPath
      }
    }
  }
}

extension Notification.Name {
  static let moxNewTest = Notification.Name("dev.mox.newTest")
}

enum ModelDirectoryPicker {
  @MainActor static func present(selection: @escaping (String) -> Void) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.message = "选择包含 config.json、tokenizer 和 safetensors 的模型目录。"
    panel.prompt = "选择此模型"
    guard let window = NSApp.keyWindow else { return }
    panel.beginSheetModal(for: window) { response in
      if response == .OK, let url = panel.url { selection(url.path) }
    }
  }
}

struct ServiceControls: View {
  @Bindable var chat: ChatController
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(label, systemImage: chat.servicePhase == "running" ? "circle.fill" : "circle.dashed")
        .font(.caption).foregroundStyle(chat.servicePhase == "running" ? .green : .secondary)
        .accessibilityIdentifier("serviceStatus")
      Text(chat.ownerLabel).font(.caption).foregroundStyle(.secondary)
      if let state = chat.serviceState {
        Text("驻留模型：\(state.residentModels)").font(.caption)
          .accessibilityIdentifier("runtimeModelStatus")
      }
      Button("重新连接") { Task { await chat.connect() } }
        .disabled(chat.isWorking || chat.isClosing)
      Button("导出诊断…") {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mox-diagnostics.json"
        if panel.runModal() == .OK, let url = panel.url {
          do { try chat.diagnostics().write(to: url, options: .atomic) } catch {
            chat.error = "无法导出诊断。"
          }
        }
      }
    }
  }
  private var label: String {
    switch chat.servicePhase {
    case "running": "服务已连接"
    case "connecting": "正在连接服务"
    case "reconnecting": "正在重新连接"
    default: "服务不可用"
    }
  }
}

private struct AcquireModelSheet: View {
  @Environment(\.dismiss) private var dismiss
  let chat: ChatController
  let library: LibraryController
  @State private var provider: ModelProvider = .huggingFace
  @State private var repository = ""
  @State private var selector = "main"
  @State private var variant = ""
  @State private var endpoint = "https://huggingface.co"
  @State private var selectedSourceOrigin = ""
  @State private var mirror = ""
  @State private var credential = ""
  @State private var mirrorCredential = ""
  @State private var plan: ModelDownloadPlanSummary?
  var body: some View {
    Form {
      Group {
        Picker("来源", selection: $provider) {
          Text("Hugging Face").tag(ModelProvider.huggingFace)
          Text("ModelScope").tag(ModelProvider.modelScope)
        }.onChange(of: provider) { _, new in
          selectSource(for: new)
        }
        TextField("仓库 owner/name", text: $repository)
          .accessibilityIdentifier("repositoryInput")
        TextField("分支、标签或精确版本", text: $selector)
        TextField("仓库内变体目录（可选）", text: $variant)
        TextField("来源 HTTPS 地址", text: $endpoint)
          .onChange(of: endpoint) { _, value in
            if value == selectedSourceOrigin {
              mirror = library.snapshot.configuration.registries.first(where: {
                $0.provider == provider && $0.origin.absoluteString == value
              })?.mirror?.absoluteString ?? ""
            } else {
              mirror = ""
            }
          }
        TextField("镜像 HTTPS 地址（可选）", text: $mirror)
          .accessibilityIdentifier("mirrorInput")
        SecureField("来源凭据（可选，存 Keychain）", text: $credential)
        if !mirror.isEmpty {
          SecureField("镜像凭据（可选）", text: $mirrorCredential)
        }
      }.disabled(plan != nil || library.busy)
      if let plan {
        VStack(alignment: .leading, spacing: 5) {
          Text("精确版本：\(plan.origin.revision)")
            .textSelection(.enabled)
          Text("\(plan.fileCount) 个文件 · 下载 \(ByteCountFormatter.string(fromByteCount: plan.totalBytes, countStyle: .file))")
          Text("预计峰值空间：\(ByteCountFormatter.string(fromByteCount: plan.peakBytes, countStyle: .file))")
          if let available = plan.availableBytes {
            Text("当前可用：\(ByteCountFormatter.string(fromByteCount: available, countStyle: .file))")
              .foregroundStyle(available < plan.peakBytes ? Color.red : Color.secondary)
          } else {
            Text("当前可用空间未知；开始时仍会尝试系统容量检查。")
          }
          Text("文件布局通过初检；模型架构与权重需在下载后最终验证。")
        }.font(.caption)
      } else {
        Text("先检查来源、精确版本和空间估算，再开始下载。")
          .font(.caption).foregroundStyle(.secondary)
      }
      if let error = library.error { Text(error).foregroundStyle(.red) }
      HStack {
        Button("取消") { dismiss() }
        if let plan {
          Button("修改输入") { self.plan = nil }
          Button("开始下载") {
            Task {
              await library.pull(using: chat, provider: provider,
                repository: repository, selector: plan.origin.revision, variant: variant,
                endpoint: endpoint, mirror: mirror,
                credential: credential, mirrorCredential: mirrorCredential)
              if library.error == nil { dismiss() }
            }
          }.buttonStyle(.borderedProminent)
            .disabled(library.busy || (plan.availableBytes.map { $0 < plan.peakBytes } ?? false))
        } else {
          Button("检查模型") {
            Task {
              plan = await library.plan(using: chat, provider: provider,
                repository: repository, selector: selector, variant: variant,
                endpoint: endpoint, mirror: mirror,
                credential: credential, mirrorCredential: mirrorCredential)
              if plan != nil { credential = ""; mirrorCredential = "" }
            }
          }
          .buttonStyle(.borderedProminent).disabled(library.busy || repository.isEmpty)
        }
      }
    }.padding(24).frame(width: 560)
      .onAppear { selectSource(for: library.snapshot.configuration.preferredRegistry()?.provider ?? .huggingFace) }
      .task {
        await library.refresh(using: chat)
        if repository.isEmpty && variant.isEmpty && credential.isEmpty && mirrorCredential.isEmpty
          && provider == .huggingFace && endpoint == "https://huggingface.co"
          && mirror.isEmpty && selector == "main" && plan == nil
        {
          selectSource(for: library.snapshot.configuration.preferredRegistry()?.provider ?? provider)
        }
      }
  }
  private func selectSource(for kind: ModelProvider) {
    provider = kind
    guard let source = library.snapshot.configuration.preferredRegistry(for: kind) else { return }
    endpoint = source.origin.absoluteString
    selectedSourceOrigin = endpoint
    mirror = source.mirror?.absoluteString ?? ""
    selector = kind == .huggingFace ? "main" : "master"
  }
}
