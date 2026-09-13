import SwiftUI
import AppKit

enum AutoOCRRuntime {
    static weak var manager: OCRManager?
}

final class AutoOCRAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AutoOCRRuntime.manager?.applyActivationPolicy()
        }
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
        MenuBarExtra(isInserted: $ocrManager.showMenuBarIcon) {
            ContentView(ocrManager: ocrManager)
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
