import CoreGraphics
import SwiftUI

/// 캡션 미러가 붙는 화면 위치. 기본값은 우측 상단(타이핑 영역을 가리지 않음).
enum CaptionPosition: String, CaseIterable, Identifiable {
    case topRight
    case topCenter
    case topLeft
    case bottomRight
    case bottomCenter
    case bottomLeft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .topRight:      return "우측 상단"
        case .topCenter:     return "상단 중앙"
        case .topLeft:       return "좌측 상단"
        case .bottomRight:   return "우측 하단"
        case .bottomCenter:  return "하단 중앙"
        case .bottomLeft:    return "좌측 하단"
        }
    }

    var isHorizontalCenter: Bool {
        self == .topCenter || self == .bottomCenter
    }

    var textAlignment: TextAlignment {
        switch self {
        case .topLeft, .bottomLeft:     return .leading
        case .topCenter, .bottomCenter: return .center
        case .topRight, .bottomRight:   return .trailing
        }
    }
}

/// 캡션 패널 크기·원점을 화면 visibleFrame 안으로 계산한다. (AppKit 창 없이 테스트 가능)
enum CaptionLayout {
    static let edgeMargin: CGFloat = 12
    static let defaultFontSize: CGFloat = 18
    static let fontSizeRange: ClosedRange<Double> = 12...36
    static let defaultPosition: CaptionPosition = .topRight

    /// 코너에 둘 때는 폭을 좁혀 본문을 덜 가리고, 중앙은 조금 더 넓게.
    static func maxWidth(position: CaptionPosition, visibleWidth: CGFloat) -> CGFloat {
        let fraction: CGFloat = position.isHorizontalCenter ? 0.70 : 0.42
        let cap: CGFloat = position.isHorizontalCenter ? 900 : 560
        let inner = max(visibleWidth - 2 * edgeMargin, 80)
        return min(inner, min(visibleWidth * fraction, cap))
    }

    /// 패널 원점(좌하단, AppKit 좌표). 결과는 가능하면 margin 안쪽, 패널이 더 크면 화면 중앙에 붙인다.
    static func origin(position: CaptionPosition,
                       panelSize: CGSize,
                       visibleFrame: CGRect,
                       margin: CGFloat = edgeMargin) -> CGPoint {
        let frame = visibleFrame
        let size = panelSize

        let loX = frame.minX + margin
        let hiX = frame.maxX - size.width - margin
        let loY = frame.minY + margin
        let hiY = frame.maxY - size.height - margin

        let preferredX: CGFloat
        let preferredY: CGFloat
        switch position {
        case .topLeft:
            preferredX = loX; preferredY = hiY
        case .topCenter:
            preferredX = frame.midX - size.width / 2; preferredY = hiY
        case .topRight:
            preferredX = hiX; preferredY = hiY
        case .bottomLeft:
            preferredX = loX; preferredY = loY
        case .bottomCenter:
            preferredX = frame.midX - size.width / 2; preferredY = loY
        case .bottomRight:
            preferredX = hiX; preferredY = loY
        }

        return CGPoint(
            x: clamp(preferredX, lower: loX, upper: hiX,
                     fallback: frame.minX + (frame.width - size.width) / 2),
            y: clamp(preferredY, lower: loY, upper: hiY,
                     fallback: frame.minY + (frame.height - size.height) / 2)
        )
    }

    /// 패널 사각형이 화면을 얼마나 벗어나는지. 0이면 완전 내부.
    static func overflow(panel: CGRect, visibleFrame: CGRect) -> CGSize {
        let dx = max(0, visibleFrame.minX - panel.minX) + max(0, panel.maxX - visibleFrame.maxX)
        let dy = max(0, visibleFrame.minY - panel.minY) + max(0, panel.maxY - visibleFrame.maxY)
        return CGSize(width: dx, height: dy)
    }

    private static func clamp(_ value: CGFloat,
                              lower: CGFloat,
                              upper: CGFloat,
                              fallback: CGFloat) -> CGFloat {
        if lower <= upper { return min(max(value, lower), upper) }
        return fallback
    }
}
