import AppKit
import Carbon
import XCTest

private let repositoryURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
  .deletingLastPathComponent()

#if DEBUG
  private let buildConfiguration = "Debug"
#else
  private let buildConfiguration = "Release"
#endif

final class MoxUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
  }
  @MainActor private func openTesting(_ app: XCUIApplication) {
    let navigation = app.descendants(matching: .any)["testingNavigation"].firstMatch
    XCTAssertTrue(navigation.waitForExistence(timeout: 20))
    XCTAssertFalse(app.textViews["composer"].exists, "Models is the default entry")
    navigation.click()
    XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 10))
  }
  @MainActor func testModelWorkspaceEntry() throws {
    let app = XCUIApplication()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mox-workspace-\(UUID())"
    ).path
    try seed(root)
    app.launchEnvironment["MOX_DATA_ROOT"] = root
    app.launch()
    let model = app.buttons["localModelRow"].firstMatch
    XCTAssertTrue(model.waitForExistence(timeout: 20))
    XCTAssertFalse(app.textViews["composer"].exists)
    model.click()
    let testModel = app.buttons["testSelectedModel"]
    XCTAssertTrue(testModel.waitForExistence(timeout: 10))
    testModel.click()
    XCTAssertTrue(app.textViews["composer"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.textFields["temperature"].exists)
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))
  }
  @MainActor func testHistoryPagesAndRetryPreserveDraft() throws {
    let keyboard = try useABCKeyboard()
    defer { TISSelectInputSource(keyboard) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mox-history-ui-\(UUID())"
    ).path
    try seed(root, mode: "seed-history")
    let app = XCUIApplication()
    app.launchEnvironment["MOX_DATA_ROOT"] = root
    app.launch()
    openTesting(app)
    let earlier = app.buttons["更早记录"]
    XCTAssertTrue(earlier.waitForExistence(timeout: 10))
    earlier.click()
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "History question 4")).firstMatch
        .waitForExistence(timeout: 10))
    let newer = app.buttons["较新记录"]
    XCTAssertTrue(newer.isEnabled)
    newer.click()
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "History question 12")).firstMatch
        .waitForExistence(timeout: 10))
    XCTAssertFalse(newer.isEnabled)
    let editor = app.textViews["composer"]
    editor.click()
    editor.typeText("Preserve my next question.")
    app.buttons["retryReply"].firstMatch.click()
    XCTAssertTrue(app.buttons["sendMessage"].waitForExistence(timeout: 40))
    XCTAssertEqual(editor.value as? String, "Preserve my next question.")
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))
  }
  @MainActor func testLaunchAndChat() throws {
    let keyboard = try useABCKeyboard()
    defer { TISSelectInputSource(keyboard) }
    let app = XCUIApplication()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mox-m2-ui-\(UUID().uuidString)"
    ).path
    app.launchEnvironment["MOX_DATA_ROOT"] = root
    try seed(root)
    app.launch()
    openTesting(app)
    // Deterministic sampling and a prompt verified by the real-model benchmark
    // keep the cancellation scenario independent of a randomly short answer.
    let parameters = app.disclosureTriangles["生成参数"]
    // SwiftUI exposes the label and arrow together; click the visible arrow.
    let disclosureArrow = parameters.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
    disclosureArrow.click()
    let temperature = app.textFields["temperature"]
    XCTAssertTrue(temperature.waitForExistence(timeout: 5))
    temperature.click()
    temperature.typeKey("a", modifierFlags: .command)
    temperature.typeText("0")
    temperature.typeKey(.return, modifierFlags: [])
    disclosureArrow.click()
    XCTAssertTrue(app.buttons["chooseModel"].waitForExistence(timeout: 20))
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "服务已连接", "服务已连接")
      ).firstMatch.waitForExistence(timeout: 20))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "qwen2.5-0.5b-4bit")).firstMatch
        .waitForExistence(timeout: 10))
    let editor = app.textViews["composer"]
    XCTAssertTrue(editor.waitForExistence(timeout: 5))
    editor.click()
    editor.typeText("Say hello briefly.")
    app.buttons["sendMessage"].click()
    XCTAssertTrue(app.buttons["retryReply"].waitForExistence(timeout: 30))
    let finished = NSPredicate(format: "enabled == true")
    expectation(for: finished, evaluatedWith: app.buttons["retryReply"])
    waitForExpectations(timeout: 30)
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(
          format:
            "value CONTAINS %@ OR value CONTAINS %@ OR label CONTAINS %@ OR label CONTAINS %@",
          "已完成", "达到输出上限", "已完成", "达到输出上限")
      ).firstMatch.exists)
    editor.click()
    editor.typeText(
      "Write a detailed 4000-word history of mathematics, beginning with ancient civilizations. Continue with as much detail as possible.\n"
    )
    app.buttons["sendMessage"].click()
    XCTAssertTrue(app.buttons["stopGeneration"].waitForExistence(timeout: 10))
    app.buttons["stopGeneration"].click()
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "已停止")).firstMatch
        .waitForExistence(timeout: 30))
    editor.click()
    editor.typeText("Say OK briefly.\n")
    app.buttons["sendMessage"].click()
    XCTAssertTrue(app.buttons["sendMessage"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.staticTexts["currentReplyStatus"].waitForExistence(timeout: 5))
    let finalStatus = app.staticTexts["currentReplyStatus"].value as? String
    XCTAssertTrue(["已完成", "达到输出上限"].contains(finalStatus ?? ""))
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root + "/run/discovery.json"))
  }
}

extension MoxUITests {
  @MainActor func testFixtureLongReplyStopRetryAndHistory() throws {
    let keyboard = try useABCKeyboard()
    defer { TISSelectInputSource(keyboard) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mox-m2-ui-fixture-\(UUID().uuidString)"
    ).path
    try seed(root)
    let fixture = Process()
    fixture.executableURL = URL(
      fileURLWithPath: repositoryURL.appendingPathComponent(".build/m2-tests/debug/MoxTestSupport")
        .path)
    fixture.arguments = ["serve", root]
    fixture.standardOutput = FileHandle.standardOutput
    fixture.standardError = FileHandle.standardError
    try fixture.run()
    defer { if fixture.isRunning { fixture.terminate() } }
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        FileManager.default.fileExists(atPath: root + "/run/discovery.json")
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    XCTAssertTrue(fixture.isRunning)
    let app = XCUIApplication()
    app.launchEnvironment["MOX_DATA_ROOT"] = root
    app.launch()
    openTesting(app)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "外部托管服务")).firstMatch
        .waitForExistence(timeout: 20))
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "服务已连接", "服务已连接")
      ).firstMatch.waitForExistence(timeout: 20))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "qwen2.5-0.5b-4bit")).firstMatch
        .waitForExistence(timeout: 10))
    let editor = app.textViews["composer"]
    editor.click()
    editor.typeText("LONG_FIXTURE")
    editor.typeKey(.return, modifierFlags: [])
    let canSend = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: app.buttons["sendMessage"])
    XCTAssertEqual(XCTWaiter.wait(for: [canSend], timeout: 10), .completed)
    app.buttons["sendMessage"].click()
    XCTAssertTrue(app.buttons["stopGeneration"].waitForExistence(timeout: 10))
    // Continue long enough to exercise repeated rendering and disk checkpoints.
    sleep(7)
    app.buttons["stopGeneration"].click()
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "已停止", "已停止")
      ).firstMatch.waitForExistence(timeout: 20))
    app.buttons["retryReply"].firstMatch.click()
    XCTAssertTrue(app.buttons["stopGeneration"].waitForExistence(timeout: 10))
    app.buttons["stopGeneration"].click()
    XCTAssertTrue(app.buttons["sendMessage"].waitForExistence(timeout: 20))
    // Switching displayed attempts must retain both results without issuing a request.
    XCTAssertTrue(app.buttons["上一结果"].firstMatch.waitForExistence(timeout: 10))
    app.buttons["上一结果"].firstMatch.click()
    XCTAssertTrue(app.buttons["下一结果"].firstMatch.isEnabled)
    app.buttons["下一结果"].firstMatch.click()
    XCTAssertTrue(app.buttons["上一结果"].firstMatch.isEnabled)
    XCTAssertFalse(app.buttons["下一结果"].firstMatch.isEnabled)
    XCTAssertFalse(app.buttons["stopGeneration"].exists)
    // Lazy rows need not all exist in AX; verify every attempt in the reopened store.
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))
    XCTAssertTrue(fixture.isRunning)
    let inspect = Process()
    inspect.executableURL = fixture.executableURL
    inspect.arguments = ["inspect-long-history", root]
    try inspect.run()
    inspect.waitUntilExit()
    XCTAssertEqual(inspect.terminationStatus, 0)
    app.launch()
    openTesting(app)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "LONG_FIXTURE")).firstMatch
        .waitForExistence(timeout: 20))
    // History survives a fresh ModelContainer and does not issue another generation.
    XCTAssertFalse(app.buttons["stopGeneration"].exists)
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))
  }
}

extension MoxUITests {
  fileprivate func seed(_ root: String, mode: String = "seed") throws {
    let process = Process()
    process.executableURL = URL(
      fileURLWithPath: repositoryURL.appendingPathComponent(".build/m2-tests/debug/MoxTestSupport")
        .path)
    process.arguments = [
      mode, root,
      ProcessInfo.processInfo.environment["MOX_TEST_MODEL"]
        ?? repositoryURL.appendingPathComponent(".build/test-models/qwen2.5-0.5b-4bit").path,
    ]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
  }
}

private func useABCKeyboard() throws -> TISInputSource {
  let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
  let sources =
    TISCreateInputSourceList(
      [kTISPropertyInputSourceID as String: "com.apple.keylayout.ABC"] as CFDictionary, false
    ).takeRetainedValue() as! [TISInputSource]
  let source = try XCTUnwrap(sources.first)
  XCTAssertEqual(TISSelectInputSource(source), noErr)
  return previous
}

extension MoxUITests {
  @MainActor func testLongReplyResponsiveness() throws {
    let keyboard = try useABCKeyboard()
    defer { TISSelectInputSource(keyboard) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mox-m2-ui-performance-\(UUID().uuidString)"
    ).path
    try seed(root)
    let fixture = Process()
    fixture.executableURL = URL(
      fileURLWithPath: repositoryURL.appendingPathComponent(".build/m2-tests/debug/MoxTestSupport")
        .path)
    fixture.arguments = ["serve", root]
    try fixture.run()
    defer { if fixture.isRunning { fixture.terminate() } }
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        FileManager.default.fileExists(atPath: root + "/run/discovery.json")
      }, object: nil)
    XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    let app = XCUIApplication()
    app.launchEnvironment["MOX_DATA_ROOT"] = root
    app.launchEnvironment["MOX_PERFORMANCE_REPORT"] = root + "/performance.json"
    app.launch()
    openTesting(app)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "外部托管服务")).firstMatch
        .waitForExistence(timeout: 20))
    let editor = app.textViews["composer"]
    for index in 0..<20 {
      editor.click()
      editor.typeText("LONG_FIXTURE\n")
      app.buttons["sendMessage"].click()
      XCTAssertTrue(app.buttons["stopGeneration"].waitForExistence(timeout: 10))
      if index == 0 { sleep(7) }
      app.buttons["stopGeneration"].click()
      XCTAssertTrue(app.buttons["sendMessage"].waitForExistence(timeout: 20))
    }
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))
    let data = try Data(contentsOf: URL(fileURLWithPath: root + "/performance.json"))
    let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [String: Any]])
    print("M2 PERFORMANCE", String(decoding: data, as: UTF8.self))
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "M2-performance"
    attachment.lifetime = .keepAlways
    add(attachment)
    let stops = try XCTUnwrap(report["stopPresentation"])
    XCTAssertEqual(stops["count"] as? Int, 20)
    let histogram = try XCTUnwrap(stops["histogram"] as? [Int])
    XCTAssertGreaterThanOrEqual(histogram.prefix(101).reduce(0, +), 19)
    let loop = try XCTUnwrap(report["mainRunLoop"])
    XCTAssertLessThanOrEqual(try XCTUnwrap(loop["maximumMilliseconds"] as? Double), 250)
    XCTAssertGreaterThan(try XCTUnwrap(report["checkpoint"]?["count"] as? Int), 0)

  }
}

extension MoxUITests {
  @MainActor func testCloseReopenAndQuitChoices() async throws {
    let keyboard = try useABCKeyboard()
    defer { TISSelectInputSource(keyboard) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mox-m2-ui-lifecycle-\(UUID().uuidString)"
    ).path
    try seed(root)
    let fixture = Process()
    fixture.executableURL = URL(
      fileURLWithPath: repositoryURL.appendingPathComponent(".build/m2-tests/debug/MoxTestSupport")
        .path)
    fixture.arguments = ["serve", root]
    try fixture.run()
    defer { if fixture.isRunning { fixture.terminate() } }
    let ready = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        FileManager.default.fileExists(atPath: root + "/run/discovery.json")
      }, object: nil)
    await fulfillment(of: [ready], timeout: 15)
    let app = XCUIApplication()
    app.launchEnvironment["MOX_DATA_ROOT"] = root
    app.launch()
    openTesting(app)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "外部托管服务")).firstMatch
        .waitForExistence(timeout: 20))
    app.textViews["composer"].click()
    app.textViews["composer"].typeText("LONG_FIXTURE\n")
    app.buttons["sendMessage"].click()
    XCTAssertTrue(app.buttons["stopGeneration"].waitForExistence(timeout: 10))
    app.typeKey("w", modifierFlags: .command)
    XCTAssertNotEqual(app.state, .notRunning)
    _ = try await NSWorkspace.shared.openApplication(
      at: URL(
        fileURLWithPath: repositoryURL.appendingPathComponent(
          ".build/m2-app/Build/Products/\(buildConfiguration)/Mox.app"
        ).path
      ), configuration: NSWorkspace.OpenConfiguration())
    XCTAssertTrue(app.buttons["stopGeneration"].waitForExistence(timeout: 10))
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.dialogs.firstMatch.buttons["继续运行"].waitForExistence(timeout: 10))
    app.dialogs.firstMatch.buttons["继续运行"].click()
    XCTAssertTrue(app.buttons["stopGeneration"].exists)
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.dialogs.firstMatch.buttons["停止任务并退出"].waitForExistence(timeout: 10))
    app.dialogs.firstMatch.buttons["停止任务并退出"].click()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))
    XCTAssertTrue(fixture.isRunning)
  }
}

extension MoxUITests {
  @MainActor func testServiceLossReconnectDoesNotReplay() throws {
    let keyboard = try useABCKeyboard()
    defer { TISSelectInputSource(keyboard) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mox-m2-ui-loss-\(UUID().uuidString)"
    ).path
    try seed(root)
    func startFixture() throws -> Process {
      let fixture = Process()
      fixture.executableURL = URL(
        fileURLWithPath: repositoryURL.appendingPathComponent(
          ".build/m2-tests/debug/MoxTestSupport"
        ).path)
      fixture.arguments = ["serve", root]
      try fixture.run()
      let ready = XCTNSPredicateExpectation(
        predicate: NSPredicate { _, _ in
          guard
            let bytes = try? Data(contentsOf: URL(fileURLWithPath: root + "/run/discovery.json")),
            let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
            let identity = object["identity"] as? [String: Any]
          else { return false }
          return identity["pid"] as? Int32 == fixture.processIdentifier
        }, object: nil)
      XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
      return fixture
    }
    let first = try startFixture()
    defer { if first.isRunning { first.terminate() } }
    let app = XCUIApplication()
    app.launchEnvironment["MOX_DATA_ROOT"] = root
    app.launch()
    openTesting(app)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "外部托管服务")).firstMatch
        .waitForExistence(timeout: 20))
    app.textViews["composer"].click()
    app.textViews["composer"].typeText("LONG_FIXTURE\n")
    app.buttons["sendMessage"].click()
    XCTAssertTrue(app.buttons["stopGeneration"].waitForExistence(timeout: 10))
    XCTAssertEqual(kill(first.processIdentifier, SIGKILL), 0)
    first.waitUntilExit()
    XCTAssertTrue(app.buttons["sendMessage"].waitForExistence(timeout: 20))
    let second = try startFixture()
    defer { if second.isRunning { second.terminate() } }
    for _ in 0..<8 {
      if app.staticTexts["attemptStatus"].firstMatch.exists { break }
      app.scrollViews["chatHistory"].scroll(byDeltaX: 0, deltaY: 10000)
    }
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "已中断")).firstMatch
        .waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "服务已连接")).firstMatch
        .waitForExistence(timeout: 20))
    XCTAssertFalse(app.buttons["stopGeneration"].exists)
    app.buttons["回到底部"].click()
    XCTAssertTrue(app.buttons["retryReply"].firstMatch.waitForExistence(timeout: 10))
    app.buttons["retryReply"].firstMatch.click()
    XCTAssertTrue(app.buttons["stopGeneration"].waitForExistence(timeout: 10))
    app.buttons["stopGeneration"].click()
    XCTAssertTrue(app.buttons["sendMessage"].waitForExistence(timeout: 20))
    XCTAssertEqual(kill(second.processIdentifier, SIGKILL), 0)
    second.waitUntilExit()
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "正在重新连接")).firstMatch
        .waitForExistence(timeout: 10))
    let third = try startFixture()
    defer { if third.isRunning { third.terminate() } }
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "服务已连接")).firstMatch
        .waitForExistence(timeout: 20))
    XCTAssertFalse(app.buttons["stopGeneration"].exists)
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))
    XCTAssertTrue(third.isRunning)
  }

  @MainActor func testMovedAppWithCleanPath() throws {
    let keyboard = try useABCKeyboard()
    defer { TISSelectInputSource(keyboard) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "Mox 独立搬迁 \(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let relocated = try String(
      contentsOfFile: repositoryURL.appendingPathComponent(".build/m2-relocated-app-path.txt").path,
      encoding: .utf8
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let dataRoot = root.appendingPathComponent("数据").path
    try seed(dataRoot)
    let app = XCUIApplication(url: URL(fileURLWithPath: relocated))
    app.launchEnvironment["MOX_DATA_ROOT"] = dataRoot
    app.launchEnvironment["PATH"] = "/usr/bin:/bin"
    app.launch()
    openTesting(app)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@", "由此 App 启动")).firstMatch
        .waitForExistence(timeout: 20))
    app.textViews["composer"].click()
    app.textViews["composer"].typeText("Say hello briefly.\n")
    app.buttons["sendMessage"].click()
    XCTAssertTrue(app.buttons["retryReply"].waitForExistence(timeout: 30))
    let finished = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"), object: app.buttons["retryReply"])
    XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 30), .completed)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "value == %@ OR value == %@", "已完成", "达到输出上限"))
        .firstMatch.exists)
    app.typeKey("q", modifierFlags: .command)
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 30))
    XCTAssertFalse(FileManager.default.fileExists(atPath: dataRoot + "/run/discovery.json"))
  }
}

extension MoxUITests {
  @MainActor func testM3ConfiguredMirrorSurvivesAcquireSheet() throws {
    let keyboard = try useABCKeyboard()
    defer { TISSelectInputSource(keyboard) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mox-m3-mirror-ui-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = XCUIApplication()
    app.launchEnvironment["MOX_DATA_ROOT"] = root.path
    app.launch()
    let acquire = app.buttons["获取模型…"]
    XCTAssertTrue(acquire.waitForExistence(timeout: 30))
    acquire.click()
    let repository = app.textFields["repositoryInput"]
    XCTAssertTrue(repository.waitForExistence(timeout: 10))
    repository.click()
    repository.typeText("mlx-community/Qwen2.5-0.5B-Instruct-4bit")
    let mirror = app.textFields["mirrorInput"]
    XCTAssertTrue(mirror.exists)
    mirror.click()
    mirror.typeText("https://huggingface.co")
    app.buttons["检查模型"].click()
    XCTAssertTrue(app.buttons["开始下载"].waitForExistence(timeout: 45))
    app.buttons["取消"].click()
    acquire.click()
    let reopenedMirror = app.textFields["mirrorInput"]
    XCTAssertTrue(reopenedMirror.waitForExistence(timeout: 10))
    XCTAssertEqual(reopenedMirror.value as? String, "https://huggingface.co")
    app.terminate()
  }

  @MainActor func testM3AcquireInstallAndChat() throws {
    let keyboard = try useABCKeyboard()
    defer { TISSelectInputSource(keyboard) }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mox-m3-ui-\(UUID())")
    defer { try? FileManager.default.removeItem(at: root) }
    let app = XCUIApplication()
    app.launchEnvironment["MOX_DATA_ROOT"] = root.path
    app.launch()
    let acquire = app.buttons["获取模型…"]
    XCTAssertTrue(acquire.waitForExistence(timeout: 30))
    acquire.click()
    let repository = app.textFields["repositoryInput"]
    XCTAssertTrue(repository.waitForExistence(timeout: 10))
    repository.click()
    repository.typeText("mlx-community/Qwen2.5-0.5B-Instruct-4bit")
    app.buttons["检查模型"].click()
    XCTAssertTrue(app.buttons["开始下载"].waitForExistence(timeout: 45))
    app.buttons["开始下载"].click()
    let downloads = app.descendants(matching: .any)["downloadsNavigation"].firstMatch
    XCTAssertTrue(downloads.waitForExistence(timeout: 30))
    downloads.click()
    let installed = app.descendants(matching: .any)["downloadPhase-installed"].firstMatch
    XCTAssertTrue(installed.waitForExistence(timeout: 120), "Real HF model should install")
    app.descendants(matching: .any)["modelsNavigation"].firstMatch.click()
    let model = app.buttons["installedModelDetails"].firstMatch
    XCTAssertTrue(model.waitForExistence(timeout: 30))
    model.click()
    XCTAssertTrue(app.staticTexts["当前版本"].waitForExistence(timeout: 10))
    let test = app.buttons["testSelectedModel"]
    XCTAssertTrue(test.waitForExistence(timeout: 15))
    test.click()
    let composer = app.textViews["composer"]
    XCTAssertTrue(composer.waitForExistence(timeout: 15))
    composer.click()
    composer.typeText("Say hello briefly.")
    app.buttons["sendMessage"].click()
    XCTAssertTrue(app.buttons["stopGeneration"].waitForExistence(timeout: 30))
    XCTAssertTrue(app.buttons["sendMessage"].waitForExistence(timeout: 120))
    XCTAssertTrue(app.buttons["retryReply"].isEnabled)
    app.terminate()
  }
}
