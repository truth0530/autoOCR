import AppKit

/// 영역 선택 결과. sourceRect에 바로 쓸 수 있는 값들을 담는다.
struct RegionSelectionResult {
    let rect: CGRect                  // 디스플레이 기준 top-left screen points
    let displayID: CGDirectDisplayID  // 선택이 이뤄진 화면
    let pixelScale: CGFloat           // 해당 화면의 backingScaleFactor
}

/// 창 좌표(bottom-left)와 디스플레이 좌표(top-left), 그리고 이동·크기 조절 히트 테스트.
enum RegionGeometry {
    static let minimumSize: CGFloat = 8
    static let edgeMargin: CGFloat = 10

    struct Edges: OptionSet, Equatable {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
        static let top = Edges(rawValue: 1 << 3)
    }

    enum Drag: Equatable {
        case draw
        case move
        case resize(Edges)
    }

    static func windowRect(fromDisplayTopLeft region: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(x: region.minX,
               y: screenHeight - region.maxY,
               width: region.width,
               height: region.height)
    }

    static func displayTopLeft(fromWindowRect rect: CGRect, screenHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX,
               y: screenHeight - rect.maxY,
               width: rect.width,
               height: rect.height)
    }

    /// 기존 상자 안은 이동, 가장자리는 크기 조절, 밖은 새 드래그.
    static func drag(at point: CGPoint, in rect: CGRect?) -> Drag {
        guard let rect, rect.width >= minimumSize, rect.height >= minimumSize else { return .draw }
        let expanded = rect.insetBy(dx: -edgeMargin, dy: -edgeMargin)
        guard expanded.contains(point) else { return .draw }
        if rect.width <= edgeMargin * 2 || rect.height <= edgeMargin * 2 {
            return .move
        }
        var edges: Edges = []
        if abs(point.x - rect.minX) <= edgeMargin { edges.insert(.left) }
        if abs(point.x - rect.maxX) <= edgeMargin { edges.insert(.right) }
        if abs(point.y - rect.minY) <= edgeMargin { edges.insert(.bottom) }
        if abs(point.y - rect.maxY) <= edgeMargin { edges.insert(.top) }
        if !edges.isEmpty { return .resize(edges) }
        return rect.contains(point) ? .move : .draw
    }

    static func apply(drag: Drag,
                      original: CGRect,
                      from start: CGPoint,
                      to current: CGPoint,
                      bounds: CGRect) -> CGRect {
        switch drag {
        case .draw:
            let rect = CGRect(x: min(start.x, current.x),
                              y: min(start.y, current.y),
                              width: abs(current.x - start.x),
                              height: abs(current.y - start.y))
            return clamp(rect, to: bounds)
        case .move:
            var moved = original.offsetBy(dx: current.x - start.x, dy: current.y - start.y)
            let maxX = max(bounds.minX, bounds.maxX - moved.width)
            let maxY = max(bounds.minY, bounds.maxY - moved.height)
            moved.origin.x = min(max(moved.origin.x, bounds.minX), maxX)
            moved.origin.y = min(max(moved.origin.y, bounds.minY), maxY)
            return moved
        case .resize(let edges):
            var rect = original
            let dx = current.x - start.x
            let dy = current.y - start.y
            if edges.contains(.left) {
                rect.origin.x += dx
                rect.size.width -= dx
            }
            if edges.contains(.right) {
                rect.size.width += dx
            }
            if edges.contains(.bottom) {
                rect.origin.y += dy
                rect.size.height -= dy
            }
            if edges.contains(.top) {
                rect.size.height += dy
            }
            if rect.width < minimumSize {
                if edges.contains(.left) { rect.origin.x = original.maxX - minimumSize }
                rect.size.width = minimumSize
            }
            if rect.height < minimumSize {
                if edges.contains(.bottom) { rect.origin.y = original.maxY - minimumSize }
                rect.size.height = minimumSize
            }
            return clamp(rect, to: bounds)
        }
    }

    static func clamp(_ rect: CGRect, to bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return rect }
        var rect = rect
        rect.size.width = min(max(rect.width, 0), bounds.width)
        rect.size.height = min(max(rect.height, 0), bounds.height)
        let maxX = bounds.maxX - rect.width
        let maxY = bounds.maxY - rect.height
        rect.origin.x = min(max(rect.origin.x, bounds.minX), maxX)
        rect.origin.y = min(max(rect.origin.y, bounds.minY), maxY)
        return rect
    }
}

/// 전체 화면 오버레이를 띄워 사용자가 사각형 영역을 드래그로 선택하게 한다.
@MainActor
final class RegionSelectionController {
    private var window: SelectionWindow?
    private var cancelled = false

    /// 마우스가 있는 화면에 오버레이를 띄우고 선택 결과를 반환한다. 취소 시 nil.
    /// `existing`이 같은 화면의 영역이면 그 상자를 보여 주고 이동·크기 조절을 받는다.
    func selectRegion(existing: RegionSelectionResult? = nil) async -> RegionSelectionResult? {
        cancelled = false
        // 캡처할 화면을 가리지 않도록 메뉴바 패널을 먼저 닫는다.
        dismissMenuBarPanel()
        // 패널이 사라지고 화면이 정리될 짧은 시간을 준 뒤 오버레이를 띄운다.
        try? await Task.sleep(nanoseconds: 150_000_000)
        if cancelled || AutoOCRRuntime.isQuitting { return nil }

        return await withCheckedContinuation { continuation in
            if cancelled || AutoOCRRuntime.isQuitting {
                continuation.resume(returning: nil)
                return
            }
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            let displayID = Self.displayID(of: screen)
            let existingRect: CGRect? = {
                guard let existing, existing.displayID == displayID, let screen else { return nil }
                return RegionGeometry.windowRect(fromDisplayTopLeft: existing.rect,
                                                 screenHeight: screen.frame.height)
            }()
            let window = SelectionWindow(screen: screen, existingRect: existingRect) { [weak self] result in
                self?.window = nil
                continuation.resume(returning: result)
            }
            self.window = window
            if cancelled || AutoOCRRuntime.isQuitting {
                window.cancelSelection()
                return
            }
            window.present()
        }
    }

    /// 종료나 재진입 때 떠 있는 선택을 닫고 대기를 끝낸다.
    func cancel() {
        cancelled = true
        window?.cancelSelection()
    }

    /// 열려 있는 MenuBarExtra 패널을 닫는다.
    private func dismissMenuBarPanel() {
        // 패널이 열려 있으면 그 창이 key window이므로 숨긴다. (다음 클릭 시 다시 열림)
        NSApp.keyWindow?.orderOut(nil)
    }

    fileprivate static func displayID(of screen: NSScreen?) -> CGDirectDisplayID {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value ?? CGMainDisplayID()
    }
}

/// 드래그로 영역을 선택받는 반투명 전체 화면 창.
final class SelectionWindow: NSWindow {
    fileprivate var selectionRect: CGRect?
    private let existingRect: CGRect?
    private var gesture: Gesture?

    private struct Gesture {
        let drag: RegionGeometry.Drag
        let origin: CGPoint
        let original: CGRect
    }

    private let targetScreen: NSScreen?
    private var completion: ((RegionSelectionResult?) -> Void)?
    private var hasCompleted = false

    init(screen: NSScreen?,
         existingRect: CGRect?,
         completion: @escaping (RegionSelectionResult?) -> Void) {
        self.targetScreen = screen
        self.existingRect = existingRect
        let frame = screen?.frame ?? NSScreen.main?.frame ?? .zero
        super.init(contentRect: frame,
                   styleMask: [.borderless],
                   backing: .buffered,
                   defer: false)
        self.completion = completion
        // 프로그램적으로 만든 NSWindow는 close() 시 스스로 해제되어 ARC와 이중 해제로 크래시가 난다.
        // ARC가 생명주기를 관리하도록 자동 해제를 끈다.
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = NSColor.black.withAlphaComponent(0.3)
        level = .screenSaver
        ignoresMouseEvents = false
        collectionBehavior = WindowChrome.overlay
        contentView = SelectionOverlayView(frame: CGRect(origin: .zero, size: frame.size))
        if let existingRect {
            let bounds = contentView?.bounds ?? CGRect(origin: .zero, size: frame.size)
            selectionRect = RegionGeometry.clamp(existingRect, to: bounds)
        }
    }

    override var canBecomeKey: Bool { true }

    func present() {
        makeKeyAndOrderFront(nil)
        orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancelSelection() {
        finish(with: nil)
    }

    // MARK: - 마우스 / 키보드

    override func mouseDown(with event: NSEvent) {
        let point = event.locationInWindow
        let drag = RegionGeometry.drag(at: point, in: selectionRect)
        let original = selectionRect ?? CGRect(origin: point, size: .zero)
        gesture = Gesture(drag: drag, origin: point, original: original)
        if drag == .draw {
            selectionRect = CGRect(origin: point, size: .zero)
        }
        contentView?.needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let gesture else { return }
        selectionRect = RegionGeometry.apply(drag: gesture.drag,
                                             original: gesture.original,
                                             from: gesture.origin,
                                             to: event.locationInWindow,
                                             bounds: contentView?.bounds ?? .zero)
        contentView?.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let gesture else { return }
        let rect = RegionGeometry.apply(drag: gesture.drag,
                                        original: gesture.original,
                                        from: gesture.origin,
                                        to: event.locationInWindow,
                                        bounds: contentView?.bounds ?? .zero)
        let drawn = gesture.drag == .draw
            && rect.width >= RegionGeometry.minimumSize
            && rect.height >= RegionGeometry.minimumSize
        let adjusted = gesture.drag != .draw && Self.changed(rect, from: gesture.original)
        self.gesture = nil
        if drawn || adjusted {
            selectionRect = rect
            finish(with: selectionResult())
            return
        }
        if gesture.drag == .draw, existingRect == nil {
            finish(with: nil)
            return
        }
        selectionRect = existingRect
        contentView?.needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            finish(with: nil)
        } else {
            super.keyDown(with: event)
        }
    }

    private static func changed(_ rect: CGRect, from original: CGRect) -> Bool {
        abs(rect.minX - original.minX) > 2
            || abs(rect.minY - original.minY) > 2
            || abs(rect.width - original.width) > 2
            || abs(rect.height - original.height) > 2
    }

    // MARK: - 좌표 변환

    /// 창 좌표(bottom-left, points) → 디스플레이 기준 화면 좌표(top-left, points).
    private func selectionResult() -> RegionSelectionResult? {
        guard let rect = selectionRect,
              rect.width >= RegionGeometry.minimumSize,
              rect.height >= RegionGeometry.minimumSize else { return nil }

        let screen = targetScreen ?? NSScreen.main
        let screenHeight = screen?.frame.height ?? 0
        let topLeft = RegionGeometry.displayTopLeft(fromWindowRect: rect, screenHeight: screenHeight)
        let displayID = RegionSelectionController.displayID(of: screen)
        let scale = screen?.backingScaleFactor ?? 2
        return RegionSelectionResult(rect: topLeft, displayID: displayID, pixelScale: scale)
    }

    private func finish(with result: RegionSelectionResult?) {
        guard !hasCompleted else { return }
        hasCompleted = true
        let completion = self.completion
        self.completion = nil
        close()
        completion?(result)
    }
}

/// 안내 문구, 선택 사각형, 크기 라벨을 그리는 오버레이 뷰.
private final class SelectionOverlayView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = NSColor.black.withAlphaComponent(0.3).cgColor

        let scale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        var sublayers: [CALayer] = [instructionLayer(scale: scale)]

        if let rect = (window as? SelectionWindow)?.selectionRect, rect.width >= 1, rect.height >= 1 {
            let selectionLayer = CALayer()
            selectionLayer.frame = rect
            selectionLayer.borderColor = NSColor.systemRed.cgColor
            selectionLayer.borderWidth = 2.0
            selectionLayer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.08).cgColor
            sublayers.append(selectionLayer)

            for corner in [
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY),
                CGPoint(x: rect.maxX, y: rect.maxY)
            ] {
                let handle = CALayer()
                handle.frame = CGRect(x: corner.x - 4, y: corner.y - 4, width: 8, height: 8)
                handle.backgroundColor = NSColor.white.cgColor
                handle.borderColor = NSColor.systemRed.cgColor
                handle.borderWidth = 1
                handle.cornerRadius = 1
                sublayers.append(handle)
            }

            let infoLayer = CATextLayer()
            infoLayer.string = "크기: \(Int(rect.width)) × \(Int(rect.height))"
            infoLayer.fontSize = 12
            infoLayer.foregroundColor = NSColor.white.cgColor
            infoLayer.backgroundColor = NSColor.black.withAlphaComponent(0.7).cgColor
            infoLayer.cornerRadius = 4
            infoLayer.alignmentMode = .center
            infoLayer.frame = CGRect(x: rect.minX, y: rect.maxY + 8, width: 130, height: 20)
            infoLayer.contentsScale = scale
            sublayers.append(infoLayer)
        }

        layer.sublayers = sublayers
    }

    /// 화면 상단 중앙에 사용 안내를 표시한다.
    private func instructionLayer(scale: CGFloat) -> CALayer {
        let text = CATextLayer()
        text.string = "드래그로 새 영역  ·  상자 안은 이동  ·  가장자리는 크기 조절  ·  ESC 취소"
        text.fontSize = 15
        text.foregroundColor = NSColor.white.cgColor
        text.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        text.cornerRadius = 8
        text.alignmentMode = .center
        text.contentsScale = scale
        let width: CGFloat = 680
        let height: CGFloat = 34
        text.frame = CGRect(x: (bounds.width - width) / 2,
                            y: bounds.height - 120,
                            width: width,
                            height: height)
        return text
    }
}
