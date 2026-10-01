import AppKit
import MoxChat
import MoxDomain
import MoxPersistence
import SwiftUI

struct ChatView: View {
  @Bindable var chat: ChatController
  let chooseModel: () -> Void
  @State private var follow = true
  @State private var showSessions = true
  @State private var displayedAttempts: [UUID: UUID] = [:]
  @State private var parametersExpanded = false
  @State private var showDelete = false
  @State private var stopStarted: TimeInterval?
  var body: some View {
    HSplitView {
      if showSessions {
        VStack(alignment: .leading, spacing: 14) {
          HStack {
            Text("测试会话").font(.headline)
            Spacer()
            Button {
              Task { await chat.newConversation() }
            } label: {
              Image(systemName: "square.and.pencil")
            }.help("新对话").accessibilityIdentifier("newConversation")
          }
          .padding(.horizontal).padding(.top)
          List(selection: Binding(get: { chat.selectedID }, set: { chat.select($0) })) {
            ForEach(chat.conversations) { conversation in
              VStack(alignment: .leading, spacing: 4) {
                Text(conversation.title)
                Text(URL(fileURLWithPath: conversation.modelPath).lastPathComponent)
                  .font(.caption).foregroundStyle(.secondary)
                Text(conversation.updatedAt, style: .date).font(.caption).foregroundStyle(
                  .secondary)
                Text(conversationStatus(conversation))
                  .font(.caption).foregroundStyle(.secondary)
              }.tag(conversation.id)
            }
          }
        }
        .safeAreaInset(edge: .bottom) {
          if chat.conversationOffset > 0 || chat.hasMoreConversations {
            HStack {
              Button("较新会话") { Task { await chat.changeConversationPage(older: false) } }
                .disabled(chat.conversationOffset == 0)
              Button("更早会话") { Task { await chat.changeConversationPage(older: true) } }
                .disabled(!chat.hasMoreConversations)
            }.padding(8)
          }
        }
        .frame(minWidth: 170, idealWidth: 210, maxWidth: 280)
      }
      VStack(spacing: 0) {
        HStack(spacing: 12) {
          Image(systemName: "cpu").font(.title2).foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 3) {
            Text(
              chat.modelPath.isEmpty
                ? "选择本地 MLX 模型" : URL(fileURLWithPath: chat.modelPath).lastPathComponent
            ).font(.headline)
            Text(modelLabel).font(.caption).foregroundStyle(.secondary).accessibilityIdentifier(
              "modelStatus")
          }
          Spacer()
          Button("选择模型…", action: chooseModel).disabled(chat.isWorking || chat.isClosing)
            .accessibilityIdentifier("chooseModel")
        }.padding()
        Divider()
        if let error = chat.error {
          Text(error).foregroundStyle(.red).textSelection(.enabled).padding()
            .accessibilityIdentifier("appError")
        }
        if chat.isLoadingHistory {
          ProgressView("正在读取记录…").controlSize(.small).padding(8)
        }
        if chat.historyOffset > 0 || chat.selected?.hasMore == true {
          HStack {
            Button("更早记录") {
              follow = false
              Task { await chat.changeHistoryPage(older: true) }
            }
              .disabled(chat.isLoadingHistory || chat.selected?.hasMore != true)
            Text("当前显示最多 \(HistoryLimit.attempts) 条回答；完整记录保留在本机。")
              .font(.caption).foregroundStyle(.secondary)
            Button("较新记录") {
              follow = false
              Task { await chat.changeHistoryPage(older: false) }
            }
              .disabled(chat.isLoadingHistory || chat.historyOffset == 0)
          }.padding(8)
        }
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
              if chat.selected?.attempts.isEmpty ?? true {
                ContentUnavailableView(
                  "开始本地聊天", systemImage: "bubble.left.and.bubble.right",
                  description: Text("选择已有模型目录，输入消息。模型文件保持原样。"))
              }
              ForEach(replyRows) { row in replyRow(row) }
              Color.clear.frame(height: 1).id("bottom")
            }.padding(24)
          }
          // A replacement history page is a new viewport. Keeping the old lazy stack's
          // scroll geometry makes SwiftUI lay out removed offscreen text to preserve it.
          .id(chat.selected?.attempts.first?.id)
          .defaultScrollAnchor(follow ? .bottom : .top)
          .accessibilityIdentifier("chatHistory")
          .onScrollPhaseChange { _, phase in if phase == .interacting { follow = false } }
          .onChange(of: chat.live?.sequence) {
            if follow { proxy.scrollTo("bottom", anchor: .bottom) }
          }
          .onChange(of: chat.isWorking) {
            if !chat.isWorking, follow { proxy.scrollTo("bottom", anchor: .bottom) }
          }
          .onChange(of: displayedAttempts) { previous, current in
            // Keep the result selector visible when answers have different lengths.
            if let changed = current.first(where: { previous[$0.key] != $0.value }) {
              proxy.scrollTo(ReplyRow.ID(attemptID: changed.value, part: .footer), anchor: .bottom)
            }
          }
          .overlay(alignment: .bottomTrailing) {
            if !follow {
              Button("回到底部") {
                follow = true
                proxy.scrollTo("bottom", anchor: .bottom)
              }.padding()
            }
          }
        }
        Divider()
        VStack(alignment: .leading, spacing: 10) {
          TextEditor(text: $chat.draft).font(.body).frame(minHeight: 65, maxHeight: 120)
            .scrollContentBackground(.hidden).padding(8).background(
              .quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8)
            )
            .accessibilityIdentifier("composer")
          DisclosureGroup("生成参数", isExpanded: $parametersExpanded) {
            HStack {
              Text("最大输出")
              TextField("tokens", value: Binding(get: { chat.maxTokens }, set: {
                chat.setMaxTokensOverride($0)
              }), format: .number).frame(width: 65)
                .accessibilityIdentifier("maxTokens")
              Text("温度")
              TextField("温度", value: Binding(get: { chat.temperature }, set: {
                chat.setTemperatureOverride($0)
              }), format: .number).frame(width: 65)
                .accessibilityIdentifier("temperature")
            }.disabled(chat.isWorking || chat.isClosing)
            if let effective = chat.effectiveSampling {
              Text("最大输出：\(samplingSourceLabel(effective.maxTokensSource)) · 温度：\(samplingSourceLabel(effective.temperatureSource)) · top-p：\(samplingSourceLabel(effective.topPSource))")
                .font(.caption).foregroundStyle(.secondary)
            }
            Button("恢复模型/全局默认") {
              chat.maxTokensExplicit = false
              chat.temperatureExplicit = false
              Task { await chat.refreshEffectiveSampling() }
            }.disabled(chat.isWorking || chat.isClosing)
            Text("仅影响后续请求；留空的模型设置由全局或产品默认值决定。")
              .font(.caption)
          }
          HStack {
            Spacer()
            if chat.isWorking {
              if chat.isStopping {
                StopStatusLabel(
                  text: chat.stopWaitIsLong ? "仍在等待模型停止，可导出诊断" : "正在停止，等待模型释放请求…",
                  began: stopStarted, metrics: chat.performance
                )
                .frame(width: 265, height: 18)
              } else {
                Text(phaseLabel(chat.live?.phase ?? "accepted")).font(.caption).foregroundStyle(
                  .secondary)
              }
              Button("停止") {
                stopStarted = NSApp.currentEvent?.timestamp ?? ProcessInfo.processInfo.systemUptime
                chat.stop()
              }.disabled(chat.isStopping).accessibilityIdentifier("stopGeneration")
            } else {
              if let live = chat.live, live.conversationID == chat.selectedID {
                Text(statusLabel(live.status)).font(.caption).foregroundStyle(.secondary)
                  .accessibilityIdentifier("currentReplyStatus")
              }
              Button("发送") {
                follow = true
                Task { await chat.send() }
              }.keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent).disabled(
                  chat.isClosing || chat.isLoadingHistory || chat.live?.saved == false
                    || chat.modelPath.isEmpty
                    || chat.servicePhase != "running" || !chat.storageAvailable
                    || chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ).accessibilityIdentifier("sendMessage")
            }
          }
        }.padding()
      }
      .toolbar {
        ToolbarItem {
          Button(showSessions ? "收起会话" : "展开会话", systemImage: "sidebar.left") {
            showSessions.toggle()
          }.accessibilityIdentifier("toggleTestSessions")
        }
        ToolbarItem {
          Button {
            showDelete = true
          } label: {
            Image(systemName: "trash")
          }.disabled(!chat.canDeleteSelected).help("删除当前对话")
        }
      }
      .confirmationDialog("删除当前对话？模型文件不会被删除。", isPresented: $showDelete) {
        Button("删除对话", role: .destructive) { Task { await chat.deleteSelected() } }
      }
    }
  }
  private func conversationStatus(_ conversation: ConversationSummary) -> String {
    let current = chat.live?.conversationID == conversation.id ? chat.live : nil
    let status = statusLabel(current?.status ?? conversation.status)
    return current?.saved == false ? "\(status) · 未保存" : status
  }
  /// Retries share one visible answer slot. Viewing an older result never changes context.
  private var attemptGroups: [[AttemptSnapshot]] {
    var groups: [[AttemptSnapshot]] = []
    var groupByAttempt: [UUID: Int] = [:]
    for attempt in chat.selected?.attempts ?? [] {
      if let retry = attempt.retryOfID, let index = groupByAttempt[retry] {
        groups[index].append(attempt)
        groupByAttempt[attempt.id] = index
      } else {
        groupByAttempt[attempt.id] = groups.count
        groups.append([attempt])
      }
    }
    return groups
  }
  private var replyRows: [ReplyRow] {
    var rows: [ReplyRow] = []
    for group in attemptGroups {
      let attempt =
        group.first { $0.id == displayedAttempts[group[0].id] } ?? group[group.count - 1]
      let current = chat.live?.attemptID == attempt.id ? chat.live : nil
      rows.append(.init(attemptID: attempt.id, part: .header, content: .header(attempt)))
      for (index, text) in (current?.segments ?? chat.replySegments[attempt.id] ?? []).enumerated()
      {
        rows.append(
          .init(
            attemptID: attempt.id, part: .text(index),
            // Presentation follows this reply, not a later request being prepared.
            content: .text(text, current?.isInProgress != true)))
      }
      rows.append(.init(attemptID: attempt.id, part: .footer, content: .footer(attempt)))
    }
    return rows
  }
  @ViewBuilder private func replyRow(_ row: ReplyRow) -> some View {
    switch row.content {
    case .header(let attempt):
      replyHeader(attempt)
        .padding(18)
        .background(.background.secondary,
          in: UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
    case .text(let text, let markdown):
      ReplyChunk(text: text, markdown: markdown).equatable()
        .accessibilityIdentifier("replyText")
        .padding(.horizontal, 18).padding(.vertical, 2)
        .background(.background.secondary)
    case .footer(let attempt):
      replyFooter(attempt)
        .padding(18)
        .background(.background.secondary,
          in: UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        .padding(.bottom, 24)
    }
  }
  private func replyHeader(_ attempt: AttemptSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("你").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      Text(attempt.prompt).textSelection(.enabled)
      Divider()
      HStack {
        Text("Mox").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        if attempt.retryOfID != nil {
          Text("重试 · 原回复已保留").font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Text(statusLabel(chat.live?.attemptID == attempt.id ? chat.live!.status : attempt.status))
          .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("attemptStatus")
      }
    }
  }
  @ViewBuilder private func attemptSelector(_ attempt: AttemptSnapshot) -> some View {
    if let group = attemptGroups.first(where: { $0.contains(where: { $0.id == attempt.id }) }),
      let index = group.firstIndex(where: { $0.id == attempt.id }), group.count > 1
    {
      HStack {
        Button("上一结果") { displayedAttempts[group[0].id] = group[index - 1].id }
          .disabled(index == 0 || chat.isWorking)
        Text("回答 \(index + 1) / \(group.count)").font(.caption)
        Button("下一结果") { displayedAttempts[group[0].id] = group[index + 1].id }
          .disabled(index == group.count - 1 || chat.isWorking)
      }
    }
  }
  private func replyFooter(_ attempt: AttemptSnapshot) -> some View {
    let current = chat.live?.attemptID == attempt.id ? chat.live : nil
    return VStack(alignment: .leading, spacing: 12) {
      attemptSelector(attempt)
      if let error = current?.error?.description ?? attempt.errorCode {
        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
      }
      if current?.saved == false { Button("未保存 · 重试保存") { Task { await chat.retrySave() } } }
      HStack {
        Button("重试") {
          displayedAttempts = [:]
          follow = true
          Task { await chat.send(retryOf: attempt.id) }
        }
        .disabled(chat.isWorking || chat.isClosing || chat.live?.saved == false)
        .accessibilityIdentifier("retryReply")
        if attempt.canContinue {
          Button(chat.selected?.selectedLeafID == attempt.id ? "当前上下文" : "从此回复继续") {
            Task { await chat.selectBranch(attempt.id) }
          }.disabled(
            chat.isWorking || chat.isClosing || chat.selected?.selectedLeafID == attempt.id)
        }
        Spacer()
        if let usage = current?.usage ?? attempt.usage {
          Text("\(usage.outputTokens) tokens").font(.caption).foregroundStyle(.secondary)
        }
      }.buttonStyle(.borderless)
    }
  }
  var modelLabel: String {
    if chat.isWorking, chat.live?.conversationID == chat.selectedID {
      return phaseLabel(chat.live?.phase ?? "accepted")
    }
    return chat.modelPath.isEmpty ? "只引用本地目录，不下载或改写文件" : "本地引用 · 仅 Qwen2.5 0.5B 已验证，其他模型尚未验证"
  }
}
func phaseLabel(_ phase: String) -> String {
  switch phase {
  case "loading": "正在加载模型 / 预热"
  case "prefill": "正在准备输入"
  case "decode": "正在生成"
  case "queued": "等待模型资源"
  default: "请求已接受"
  }
}
func statusLabel(_ status: String) -> String {
  switch status {
  case "stop": "已完成"
  case "length": "达到输出上限"
  case "cancelled": "已停止"
  case "failed": "生成失败"
  case "interrupted": "已中断 · 结果待确认"
  case "empty": "尚未开始"
  case "stopping": "正在停止"
  default: "生成中"
  }
}
private struct ReplyRow: Identifiable {
  enum Part: Hashable {
    case header
    case text(Int)
    case footer
  }
  struct ID: Hashable {
    let attemptID: UUID
    let part: Part
  }
  enum Content {
    case header(AttemptSnapshot)
    case text(String, Bool)
    case footer(AttemptSnapshot)
  }
  let attemptID: UUID
  let part: Part
  let content: Content
  var id: ID { ID(attemptID: attemptID, part: part) }
}
struct ReplyChunk: View, Equatable {
  let text: String
  let markdown: Bool
  var body: some View {
    Text(
      markdown
        ? ((try? AttributedString(
          markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
          ?? AttributedString(text)) : AttributedString(text)
    )
    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Measures event timestamp to the first native draw of the stopping label.
struct StopStatusLabel: NSViewRepresentable {
  let text: String
  let began: TimeInterval?
  let metrics: PerformanceMetrics
  func makeNSView(context: Context) -> StopStatusField {
    let field = StopStatusField(labelWithString: text)
    field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    field.textColor = .secondaryLabelColor
    field.metrics = metrics
    field.began = began
    return field
  }
  func updateNSView(_ field: StopStatusField, context: Context) { field.stringValue = text }
}
final class StopStatusField: NSTextField {
  var began: TimeInterval?
  var metrics: PerformanceMetrics?
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    if let began {
      metrics?.record(.stopPresentation, seconds: ProcessInfo.processInfo.systemUptime - began)
      self.began = nil
    }
  }
}
