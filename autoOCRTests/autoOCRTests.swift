import Testing
import AppKit
import CoreGraphics
import Darwin
import ScreenCaptureKit
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

    @Test func captionStaysThroughASlowInterval() {
        #expect(CaptionLayout.linger(interval: 0.5) == 5)
        #expect(CaptionLayout.linger(interval: 30) == 30)
        #expect(CaptionLayout.maxLines >= 6)
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

    @Test func spaceBehaviorsStayExclusive() {
        #expect(!WindowChrome.combinesJoinAllSpacesAndMove(WindowChrome.settings))
        #expect(!WindowChrome.combinesJoinAllSpacesAndMove(WindowChrome.overlay))
        #expect(!WindowChrome.combinesJoinAllSpacesAndMove(WindowChrome.caption))
        let illegal = NSWindow.CollectionBehavior([.canJoinAllSpaces, .moveToActiveSpace])
        #expect(WindowChrome.combinesJoinAllSpacesAndMove(illegal))
    }

    @Test func slowIntervalIsNotCalledRealtime() {
        #expect(RecognitionCopy.liveLabel(interval: 0.5) == "실시간 인식 중")
        #expect(RecognitionCopy.liveLabel(interval: 30) == "30초마다 인식 중")
    }

    @Test func zeroIntervalTurnsAutomaticRecognitionOff() {
        #expect(!RecognitionCopy.isAutomatic(0))
        #expect(!RecognitionCopy.isAutomatic(-1))
        #expect(RecognitionCopy.isAutomatic(0.5))
        #expect(RecognitionCopy.liveLabel(interval: 0) == "수동 대기")
    }

    @Test func savedRegionRoundTrips() {
        let saved = SavedRegion(rect: CGRect(x: 10, y: 20, width: 300, height: 80),
                                displayID: 1,
                                pixelScale: 2)
        let data = try! JSONEncoder().encode(saved)
        let decoded = try! JSONDecoder().decode(SavedRegion.self, from: data)
        #expect(decoded == saved)
        #expect(decoded.isUsable)
        #expect(!SavedRegion(rect: .zero, displayID: 1, pixelScale: 2).isUsable)
    }

    @Test func hidingBothRequiresPanelShortcut() {
        #expect(!AccessPolicy.canTurnOff(dock: false, menuBar: false, hasPanelShortcut: false))
        #expect(AccessPolicy.canTurnOff(dock: false, menuBar: false, hasPanelShortcut: true))
    }
}

struct RegionGeometryTests {
    @Test func displayTopLeftRoundTripsThroughWindowCoordinates() {
        let screenHeight: CGFloat = 900
        let display = CGRect(x: 12, y: 20, width: 300, height: 40)
        let window = RegionGeometry.windowRect(fromDisplayTopLeft: display, screenHeight: screenHeight)
        #expect(window == CGRect(x: 12, y: 840, width: 300, height: 40))
        let back = RegionGeometry.displayTopLeft(fromWindowRect: window, screenHeight: screenHeight)
        #expect(back == display)
    }

    @Test func interiorMovesAndEdgesResize() {
        let original = CGRect(x: 100, y: 100, width: 200, height: 80)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)

        #expect(RegionGeometry.drag(at: CGPoint(x: 180, y: 140), in: original) == .move)
        #expect(RegionGeometry.drag(at: CGPoint(x: 100, y: 140), in: original) == .resize(.left))
        #expect(RegionGeometry.drag(at: CGPoint(x: 300, y: 140), in: original) == .resize(.right))
        #expect(RegionGeometry.drag(at: CGPoint(x: 10, y: 10), in: original) == .draw)

        let moved = RegionGeometry.apply(drag: .move,
                                         original: original,
                                         from: CGPoint(x: 180, y: 140),
                                         to: CGPoint(x: 200, y: 155),
                                         bounds: bounds)
        #expect(moved == original.offsetBy(dx: 20, dy: 15))

        let resized = RegionGeometry.apply(drag: .resize(.right),
                                           original: original,
                                           from: CGPoint(x: 300, y: 140),
                                           to: CGPoint(x: 340, y: 140),
                                           bounds: bounds)
        #expect(resized.minX == 100)
        #expect(resized.width == 240)
    }

    @Test func resizeDoesNotCollapseBelowMinimum() {
        let original = CGRect(x: 100, y: 100, width: 200, height: 80)
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let resized = RegionGeometry.apply(drag: .resize(.left),
                                           original: original,
                                           from: CGPoint(x: 100, y: 140),
                                           to: CGPoint(x: 295, y: 140),
                                           bounds: bounds)
        #expect(resized.width >= RegionGeometry.minimumSize)
        #expect(resized.maxX == original.maxX)
    }
}

struct CaptureStopKindTests {
    @Test func menuBarStopSharingDoesNotRestart() {
        let kind = CaptureStopKind.classify(domain: SCStreamErrorDomain,
                                            code: SCStreamError.Code.userStopped.rawValue)
        #expect(kind == .userStopped)
        #expect(!kind.restartsAutomatically)
    }

    @Test func systemStopDoesNotRestart() {
        let kind = CaptureStopKind.classify(domain: SCStreamErrorDomain,
                                            code: SCStreamError.Code.systemStoppedStream.rawValue)
        #expect(kind == .systemStopped)
        #expect(!kind.restartsAutomatically)
    }

    @Test func internalFailureMayRestart() {
        let kind = CaptureStopKind.classify(domain: SCStreamErrorDomain,
                                            code: SCStreamError.Code.internalError.rawValue)
        #expect(kind == .interrupted)
        #expect(kind.restartsAutomatically)
    }

    @Test func foreignDomainIsNotTreatedAsUserStop() {
        let kind = CaptureStopKind.classify(domain: "other", code: SCStreamError.Code.userStopped.rawValue)
        #expect(kind == .interrupted)
    }
}

struct TimedRunTests {
    @Test func timeoutDoesNotWaitForWorkThatIgnoresCancellation() async {
        let start = ContinuousClock.now
        do {
            _ = try await Timed.run(seconds: 0.25) { () -> Int in
                await Task.detached {
                    usleep(2_000_000)
                }.value
                return 1
            }
            Issue.record("제한 시간 안에 반환되어야 한다")
        } catch is Timed.Failure {
            #expect(start.duration(to: .now) < .milliseconds(1200))
        } catch {
            Issue.record("예상한 시간 초과가 아니다: \(error)")
        }
    }
}
