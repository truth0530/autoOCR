import SwiftUI
import AppKit

enum AutoOCRRuntime {
    static weak var manager: OCRManager?
    /// 종료가 시작되면 캡처 재연결과 영역 선택 재시작을 막는다. 메인 스레드에서만 바꾼다.
    static var isQuitting = false
}

final class AutoOCRAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        installQuitMenuIfNeeded()
        Task { @MainActor in
            AutoOCRRuntime.manager?.finishLaunching()
            installQuitMenuIfNeeded()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        installQuitMenuIfNeeded()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // 테스트 호스트는 XCTest가 프로세스를 닫는다. 강제 exit와 겹치면 러너가 멈춘다.
        if Self.isRunningTests { return .terminateNow }
        if AutoOCRRuntime.isQuitting {
            return .terminateNow
        }
        AutoOCRRuntime.isQuitting = true
        let manager = AutoOCRRuntime.manager
        Task { @MainActor in
            await manager?.shutdownForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        // ScreenCaptureKit이 stop을 끝까지 잡지 않아도 프로세스가 도크에 남지 않게 한다.
        Task.detached {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            exit(0)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            if let manager = AutoOCRRuntime.manager {
                ControlPanelController.shared.show(manager: manager)
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        add(menu, title: "패널 열기", action: #selector(openPanel))
        add(menu, title: "영역 선택", action: #selector(selectRegion))
        add(menu, title: "인식 시작/중지", action: #selector(toggleCapture))
        menu.addItem(.separator())
        add(menu, title: "autoOCR 종료", action: #selector(quit))
        return menu
    }

    private func add(_ menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func openPanel() {
        Task { @MainActor in
            guard let manager = AutoOCRRuntime.manager else { return }
            ControlPanelController.shared.show(manager: manager)
        }
    }

    @objc private func selectRegion() {
        Task { @MainActor in
            await AutoOCRRuntime.manager?.selectRegion()
        }
    }

    @objc private func toggleCapture() {
        Task { @MainActor in
            await AutoOCRRuntime.manager?.toggleCapturing()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static var isRunningTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }

    /// SwiftUI MenuBarExtra만 있으면 앱 메뉴가 없어 ⌘Q가 전달되지 않는다.
    func installQuitMenuIfNeeded() {
        let main = NSApp.mainMenu ?? NSMenu()
        if NSApp.mainMenu == nil {
            NSApp.mainMenu = main
        }
        let appItem: NSMenuItem
        if let first = main.items.first, first.submenu != nil {
            appItem = first
        } else {
            appItem = NSMenuItem()
            appItem.submenu = NSMenu(title: "autoOCR")
            main.insertItem(appItem, at: 0)
        }
        guard let appMenu = appItem.submenu else { return }
        let hasQuit = appMenu.items.contains { item in
            item.action == #selector(NSApplication.terminate(_:)) && item.keyEquivalent == "q"
        }
        if hasQuit { return }
        let quit = NSMenuItem(title: "autoOCR 종료",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        appMenu.addItem(quit)
    }
}

// 메뉴바 상주 유틸리티. 하나의 OCRManager를 앱 전역에서 공유한다.
@main
struct autoOCRApp: App {
    @NSApplicationDelegateAdaptor(AutoOCRAppDelegate.self) private var appDelegate
    @StateObject private var ocrManager = OCRManager()

    init() {
        Self.activateExistingInstanceIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra(isInserted: ocrManager.menuBarIconBinding) {
            ContentView(ocrManager: ocrManager, chrome: .menuExtra)
        } label: {
            Image(systemName: ocrManager.isCapturing ? "record.circle" : "text.viewfinder")
        }
        .menuBarExtraStyle(.window)
    }

    /// 이미 실행 중이면 기존 인스턴스만 살리고 중복 실행을 막는다.
    /// (핫키·캡처 스트림이 둘 다 붙으면 “멈춘 것처럼” 보인다.)
    private static func activateExistingInstanceIfNeeded() {
        // 테스트 호스트(같은 번들 ID)가 실사용 인스턴스를 보고 바로 종료하면 XCTest가 부트스트랩에 실패한다.
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return }
        if NSClassFromString("XCTestCase") != nil { return }

        let id = Bundle.main.bundleIdentifier ?? "ds-ch.autoOCR"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let existing = others.first else { return }
        _ = existing.activate()
        exit(0)
    }
}
