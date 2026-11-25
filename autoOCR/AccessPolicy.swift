import AppKit

/// 노치·브라우저 확장 때문에 메뉴바 아이콘이 가려져도 앱에 들어갈 길이 하나 이상 남는지.
enum AccessPolicy {
    /// Dock·메뉴바를 모두 끄려면 패널 단축키가 있어야 한다.
    static func canTurnOff(dock: Bool, menuBar: Bool, hasPanelShortcut: Bool) -> Bool {
        if dock || menuBar { return true }
        return hasPanelShortcut
    }
}

/// 창이 스페이스에 붙는 방식. Spaces 옵션은 하나만 쓴다.
/// `canJoinAllSpaces`와 `moveToActiveSpace`를 같이 주면 macOS 27이 예외를 던지고 앱이 죽는다.
enum WindowChrome {
    static let settings = NSWindow.CollectionBehavior([.moveToActiveSpace, .fullScreenAuxiliary])
    static let overlay = NSWindow.CollectionBehavior([.canJoinAllSpaces, .fullScreenAuxiliary])
    static let caption = NSWindow.CollectionBehavior([
        .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle
    ])

    static func combinesJoinAllSpacesAndMove(_ behavior: NSWindow.CollectionBehavior) -> Bool {
        behavior.contains(.canJoinAllSpaces) && behavior.contains(.moveToActiveSpace)
    }
}

/// 인식이 돌고 있을 때 상태 문구. 주기가 길면 "실시간"이라고 하지 않는다.
/// 0 이하는 자동 인식을 끈 상태다. 스트림은 유지하고 단축키로만 한 번씩 읽는다.
enum RecognitionCopy {
    static func isAutomatic(_ interval: Double) -> Bool {
        interval > 0
    }

    static func liveLabel(interval: Double) -> String {
        if !isAutomatic(interval) { return "수동 대기" }
        if interval <= 1 { return "실시간 인식 중" }
        let shown = interval < 10
            ? String(format: "%g", interval)
            : String(Int(interval.rounded()))
        return "\(shown)초마다 인식 중"
    }
}
