import SwiftUI
import AppKit

/// 메뉴바 Extra가 노치·다른 아이콘에 가려져도 열 수 있는 독립 패널.
@MainActor
final class ControlPanelController: NSObject, NSWindowDelegate {
    static let shared = ControlPanelController()

    private var window: NSWindow?

    func toggle(manager: OCRManager) {
        // 다른 스페이스에만 남아 있는 창은 보이는 것으로 치지 않는다. 그러면 단축키가 숨기기만 한다.
        if let window, window.isVisible, window.isOnActiveSpace {
            window.orderOut(nil)
            return
        }
        show(manager: manager)
    }

    func show(manager: OCRManager) {
        // 메뉴바 팝오버의 클릭 처리 중에 활성화 정책·메인 메뉴를 바꾸면
        // macOS 27 MenuBarClientCore가 해제된 executor로 점프해 죽는다.
        // 클릭이 끝난 다음 턴에 연다.
        DispatchQueue.main.async { [weak self] in
            self?.present(manager: manager)
        }
    }

    private func present(manager: OCRManager) {
        guard !AutoOCRRuntime.isQuitting else { return }
        let window = self.window ?? makeWindow(manager: manager)
        self.window = window
        let desired: NSApplication.ActivationPolicy = manager.showDockIcon ? .regular : .accessory
        if NSApp.activationPolicy() != desired {
            manager.applyActivationPolicy()
        }
        (NSApp.delegate as? AutoOCRAppDelegate)?.installQuitMenuIfNeeded()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow(manager: OCRManager) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "autoOCR"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 360)
        window.collectionBehavior = WindowChrome.settings
        let hosting = NSHostingView(rootView: ContentView(ocrManager: manager, chrome: .panel))
        // 창 크기가 기준이다. intrinsic 크기만 쓰면 내용이 비어 보인다.
        hosting.sizingOptions = [.standardBounds, .minSize]
        hosting.frame = NSRect(x: 0, y: 0, width: 360, height: 580)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 360, height: 580))
        window.setFrameAutosaveName("autoOCR.controlPanel")
        window.delegate = self
        if !window.setFrameUsingName("autoOCR.controlPanel") {
            window.center()
        }
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 빨간 닫기는 숨기기만 한다. 종료 중에는 거절하면 앱 종료가 취소된다.
        if AutoOCRRuntime.isQuitting { return true }
        sender.orderOut(nil)
        return false
    }
}
