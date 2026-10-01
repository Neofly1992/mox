import AppKit
import MoxBootstrap
import OSLog
import MoxChat
import MoxPersistence
import SwiftUI

@main struct MoxApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  @State private var chat: ChatController
  @State private var section: WorkspaceView.Section? = .models
  init() {
    let root = ProcessInfo.processInfo.environment["MOX_DATA_ROOT"] ?? ServiceFiles.defaultRoot
    let worker = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/MoxWorker.app/Contents/MacOS/mox")
    _chat = State(initialValue: ChatController(root: root, executable: worker))
  }
  var body: some Scene {
    WindowGroup("Mox", id: "chat") {
      WorkspaceView(chat: chat, section: $section)
        .frame(minWidth: 800, minHeight: 600)
        .task {
          if delegate.chat == nil {
            delegate.chat = chat
            delegate.startPerformanceMonitoring()
            await chat.start()
          }
        }
    }
    .defaultSize(width: 1100, height: 780)
    .commands {
      CommandGroup(replacing: .newItem) {
        Button("新测试") { NotificationCenter.default.post(name: .moxNewTest, object: nil) }
          .keyboardShortcut("n")
      }
    }
  }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
  var chat: ChatController?
  private var exiting = false
  private var runLoopObserver: CFRunLoopObserver?
  private var busySince: TimeInterval?
  // Match the continuous main-thread work budget; emitted only in performance mode.
  private static let slowCycleSeconds = 0.25
  func startPerformanceMonitoring() {
    guard ProcessInfo.processInfo.environment["MOX_PERFORMANCE_REPORT"] != nil else { return }
    runLoopObserver = CFRunLoopObserverCreateWithHandler(
      nil, CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue, true,
      0
    ) { [weak self] _, activity in
      MainActor.assumeIsolated {
        guard let self else { return }
        if activity == .afterWaiting {
          self.busySince = self.chat?.isWorking == true ? ProcessInfo.processInfo.systemUptime : nil
        } else if let began = self.busySince {
          let elapsed = ProcessInfo.processInfo.systemUptime - began
          self.chat?.performance.record(.mainRunLoop, seconds: elapsed)
          if elapsed > Self.slowCycleSeconds, let chat = self.chat {
            Logger(subsystem: "dev.mox", category: "performance").notice(
              "slow_main_cycle milliseconds=\(elapsed * 1000, privacy: .public) attempts=\(chat.selected?.attempts.count ?? 0, privacy: .public) chunks=\(chat.live?.segments.count ?? 0, privacy: .public) sequence=\(chat.live?.sequence ?? -1, privacy: .public) reading=\(chat.isLoadingHistory, privacy: .public)"
            )
          }
          self.busySince = nil
        }
      }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), runLoopObserver, .commonModes)
  }
  func applicationWillTerminate(_ notification: Notification) {
    if let path = ProcessInfo.processInfo.environment["MOX_PERFORMANCE_REPORT"], let chat {
      do {
        try JSONEncoder().encode(chat.performance.snapshot()).write(
          to: URL(fileURLWithPath: path), options: .atomic)
      } catch { NSLog("Mox performance report write failed") }
    }
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    if !flag { sender.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
    return true
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !exiting, let chat else { return exiting ? .terminateLater : .terminateNow }
    exiting = true
    Task {
      if await chat.prepareToQuit() {
        let alert = NSAlert()
        alert.messageText = "停止任务并退出 Mox？"
        alert.informativeText =
          chat.connection?.worker != nil ? "将停止此 App 启动的服务中的任务，并保存聊天。" : "只停止此 App 的聊天；外部服务继续运行。"
        alert.addButton(withTitle: "停止任务并退出")
        alert.addButton(withTitle: "继续运行")
        if alert.runModal() != .alertFirstButtonReturn {
          chat.cancelQuit()
          exiting = false
          sender.reply(toApplicationShouldTerminate: false)
          return
        }
      }
      while !(await chat.shutdown()) {
        let alert = NSAlert()
        alert.messageText = chat.live?.saved == false ? "回复尚未保存" : "仍在等待模型停止"
        alert.informativeText = "可以继续等待或重试保存。强制退出可能丢失尚未保存的回复，已有数据会保留。"
        alert.addButton(withTitle: "继续等待 / 重试保存")
        alert.addButton(withTitle: "强制退出")
        if alert.runModal() == .alertSecondButtonReturn {
          await chat.forceShutdown()
          break
        }
        await chat.retrySave()
      }
      sender.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
  }
}
