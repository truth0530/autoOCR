import Testing
import CoreGraphics
@testable import autoOCR

struct CaptionLayoutTests {

    private let visible = CGRect(x: 0, y: 38, width: 1440, height: 862) // 메뉴바 제외 visibleFrame

    @Test func defaultPositionIsTopRight() {
        #expect(CaptionLayout.defaultPosition == .topRight)
    }

    @Test func topRightSitsInUpperRightInsideVisibleFrame() {
        let size = CGSize(width: 320, height: 56)
        let origin = CaptionLayout.origin(position: .topRight, panelSize: size, visibleFrame: visible)
        let panel = CGRect(origin: origin, size: size)

        #expect(origin.x > visible.midX)
        #expect(origin.y > visible.midY)
        #expect(CaptionLayout.overflow(panel: panel, visibleFrame: visible) == .zero)
        #expect(panel.maxX <= visible.maxX - CaptionLayout.edgeMargin + 0.5)
        #expect(panel.maxY <= visible.maxY - CaptionLayout.edgeMargin + 0.5)
    }

    @Test func bottomCenterStaysAboveBottomEdge() {
        let size = CGSize(width: 400, height: 56)
        let origin = CaptionLayout.origin(position: .bottomCenter, panelSize: size, visibleFrame: visible)
        let panel = CGRect(origin: origin, size: size)

        #expect(abs(panel.midX - visible.midX) < 1)
        #expect(panel.minY >= visible.minY + CaptionLayout.edgeMargin - 0.5)
        #expect(CaptionLayout.overflow(panel: panel, visibleFrame: visible) == .zero)
    }

    @Test func oversizedPanelDoesNotRunOffScreen() {
        let size = CGSize(width: 2000, height: 900)
        for position in CaptionPosition.allCases {
            let origin = CaptionLayout.origin(position: position, panelSize: size, visibleFrame: visible)
            let panel = CGRect(origin: origin, size: size)
            let overflow = CaptionLayout.overflow(panel: panel, visibleFrame: visible)
            // 패널이 화면보다 크면 넘칠 수밖에 없지만, 한쪽으로 치우쳐 더 크게 벗어나지는 않는다.
            #expect(overflow.width < size.width)
            #expect(overflow.height < size.height)
        }
    }

    @Test func cornerMaxWidthIsNarrowerThanCenter() {
        let corner = CaptionLayout.maxWidth(position: .topRight, visibleWidth: 1440)
        let center = CaptionLayout.maxWidth(position: .topCenter, visibleWidth: 1440)
        #expect(corner < center)
        #expect(corner <= 560)
        #expect(center <= 900)
        #expect(corner <= 1440 - 2 * CaptionLayout.edgeMargin)
    }

    @Test func allPresetPositionsStayInsideVisibleFrame() {
        let size = CGSize(width: 280, height: 48)
        for position in CaptionPosition.allCases {
            let origin = CaptionLayout.origin(position: position, panelSize: size, visibleFrame: visible)
            let panel = CGRect(origin: origin, size: size)
            #expect(CaptionLayout.overflow(panel: panel, visibleFrame: visible) == .zero)
        }
    }

    @Test func fontSizeRangeCoversSettingsSlider() {
        #expect(CaptionLayout.fontSizeRange.contains(18))
        #expect(CaptionLayout.fontSizeRange.lowerBound == 12)
        #expect(CaptionLayout.fontSizeRange.upperBound == 36)
    }
}

struct AccessPolicyTests {
    @Test func defaultShortcutsDoNotCollide() {
        let region = KeyboardShortcutConfig.defaultRegionSelect
        let capture = KeyboardShortcutConfig.defaultCaptureNow
        let panel = KeyboardShortcutConfig.defaultPanel
        #expect(!region.sameCombo(as: capture))
        #expect(!region.sameCombo(as: panel))
        #expect(!capture.sameCombo(as: panel))
    }

    @Test func keepingDockOrMenuBarAlwaysAllowsToggle() {
        #expect(AccessPolicy.canTurnOff(dock: true, menuBar: true, hasPanelShortcut: false))
        #expect(AccessPolicy.canTurnOff(dock: true, menuBar: false, hasPanelShortcut: false))
        #expect(AccessPolicy.canTurnOff(dock: false, menuBar: true, hasPanelShortcut: false))
    }

    @Test func hidingBothRequiresPanelShortcut() {
        #expect(!AccessPolicy.canTurnOff(dock: false, menuBar: false, hasPanelShortcut: false))
        #expect(AccessPolicy.canTurnOff(dock: false, menuBar: false, hasPanelShortcut: true))
    }
}
