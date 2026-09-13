import SwiftUI
import AppKit

/// 방금 캡처된 텍스트를 자막처럼 띄우는 플로팅 창.
/// 클릭이 통과(click-through)되어 영상 조작을 방해하지 않는다.
@MainActor
final class CaptionMirror {
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var pinned = false
    private var lastText = ""
    private var appearance = CaptionAppearance()
    /// fade-out 완료 콜백이 이후 present를 덮어쓰지 못하게 세대 번호를 둔다.
    private var generation = 0

    private let autoHideDelay: TimeInterval = 5

    struct CaptionAppearance {
        var position: CaptionPosition = .topRight
        var fontSize: CGFloat = CaptionLayout.defaultFontSize
    }

    /// 설정에서 위치·글자 크기를 바꿀 때 호출한다.
    func apply(position: CaptionPosition, fontSize: CGFloat) {
        appearance.position = position
        appearance.fontSize = fontSize
        guard let panel, panel.isVisible else { return }
        present(lastText.isEmpty ? "캡처된 자막이 여기에 표시됩니다" : lastText)
    }

    /// 새 캡처 텍스트를 표시한다.
    func update(_ text: String, pinned: Bool) {
        self.pinned = pinned
        lastText = text
        present(text)
        if pinned {
            hideWorkItem?.cancel()
            hideWorkItem = nil
        } else {
            scheduleHide(after: autoHideDelay)
        }
    }

    /// 띄워두기 상태를 바꾼다.
    func setPinned(_ pinned: Bool) {
        self.pinned = pinned
        if pinned {
            present(lastText.isEmpty ? "캡처된 자막이 여기에 표시됩니다" : lastText)
            hideWorkItem?.cancel()
            hideWorkItem = nil
        } else {
            scheduleHide(after: 1.0)
        }
    }

    /// 즉시 숨긴다. (오버레이 비활성화 시)
    func hide() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        fadeOut()
    }

    // MARK: - 표시

    private func present(_ text: String) {
        generation += 1
        let panel = self.panel ?? makePanel()
        self.panel = panel

        let screen = screenUnderMouse()
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
        let maxWidth = CaptionLayout.maxWidth(position: appearance.position,
                                              visibleWidth: visible.width)
        let view = CaptionView(text: text,
                               maxWidth: maxWidth,
                               fontSize: appearance.fontSize,
                               alignment: appearance.position.textAlignment)
        if let hosting = panel.contentView as? NSHostingView<CaptionView> {
            hosting.rootView = view
        } else {
            panel.contentView = NSHostingView(rootView: view)
        }
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        position(panel, in: visible)

        if panel.isVisible {
            panel.alphaValue = 1
            panel.orderFrontRegardless()
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            let gen = generation
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }, completionHandler: { [weak self] in
                guard let self, self.generation == gen else { return }
                panel.alphaValue = 1
            })
        }
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.fadeOut() }
        hideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        let gen = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.4
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak panel] in
            guard let self, self.generation == gen else { return }
            panel?.orderOut(nil)
        })
    }

    // MARK: - 창/위치

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: CaptionView(text: "",
                                                                maxWidth: 560,
                                                                fontSize: CaptionLayout.defaultFontSize,
                                                                alignment: .trailing))
        return panel
    }

    private func position(_ panel: NSPanel, in visible: CGRect) {
        let origin = CaptionLayout.origin(position: appearance.position,
                                          panelSize: panel.frame.size,
                                          visibleFrame: visible)
        panel.setFrameOrigin(origin)
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }
}

/// 자막 스타일 텍스트 뷰.
private struct CaptionView: View {
    let text: String
    let maxWidth: CGFloat
    let fontSize: CGFloat
    let alignment: TextAlignment

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(alignment)
            .lineLimit(3)
            .truncationMode(.tail)
            .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(maxWidth: maxWidth, alignment: frameAlignment)
            .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .leading:  return .leading
        case .trailing: return .trailing
        default:        return .center
        }
    }
}
