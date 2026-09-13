/// 노치·브라우저 확장 때문에 메뉴바 아이콘이 가려져도 앱에 들어갈 길이 하나 이상 남는지.
enum AccessPolicy {
    /// Dock·메뉴바를 모두 끄려면 패널 단축키가 있어야 한다.
    static func canTurnOff(dock: Bool, menuBar: Bool, hasPanelShortcut: Bool) -> Bool {
        if dock || menuBar { return true }
        return hasPanelShortcut
    }
}
