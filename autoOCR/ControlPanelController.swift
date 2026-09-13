import SwiftUI
import AppKit

/// 메뉴바 Extra가 노치·다른 아이콘에 가려져도 열 수 있는 독립 패널.
@MainActor
final class ControlPanelController: NSObject, NSWindowDelegate {
    static let shared = ControlPanelController()

    private var window: NSWindow?

    func toggle(manager: OCRManager) {
        if let window, window.isVisible {
            window.orderOut(nil)
            return
        }
        show(manager: manager)
    }

    func show(manager: OCRManager) {
        let window = self.window ?? makeWindow(manager: manager)
        self.window = window
        manager.applyActivationPolicy()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.orderOut(nil)
    }

    private func makeWindow(manager: OCRManager) -> NSWindow {
        let visibleHeight = NSScreen.main?.visibleFrame.height ?? 800
        let height = min(640, max(420, visibleHeight - 80))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 378, height: height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "autoOCR"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 360)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .moveToActiveSpace]
        window.contentView = NSHostingView(rootView: ContentView(ocrManager: manager))
        window.setFrameAutosaveName("autoOCR.controlPanel")
        window.delegate = self
        if !window.setFrameUsingName("autoOCR.controlPanel") {
            window.center()
        }
        return window
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
