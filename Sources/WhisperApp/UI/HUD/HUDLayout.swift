import CoreGraphics
import Foundation

enum HUDLayout {
    static let panelSize = CGSize(width: 60, height: 60)
    static let cardSize = CGSize(width: 44, height: 44)
    static let outerPadding: CGFloat = 8
    static let screenInset: CGFloat = 24

    static func origin(
        in visibleFrame: CGRect,
        panelSize: CGSize = panelSize
    ) -> CGPoint {
        let safeFrame = visibleFrame.insetBy(
            dx: screenInset,
            dy: screenInset
        )
        return CGPoint(
            x: max(safeFrame.minX, safeFrame.maxX - panelSize.width),
            y: safeFrame.minY
        )
    }
}

enum ReadingHUDLayout {
    static let statusPanelSize = CGSize(width: 286, height: 90)
    static let statusCardSize = CGSize(width: 266, height: 70)
    static let playbackPanelSize = CGSize(width: 320, height: 146)
    static let playbackCardSize = CGSize(width: 300, height: 126)
    static let outerPadding: CGFloat = 10
    static let screenInset: CGFloat = 24

    static func origin(
        in visibleFrame: CGRect,
        panelSize: CGSize
    ) -> CGPoint {
        let safeFrame = visibleFrame.insetBy(
            dx: screenInset,
            dy: screenInset
        )
        return CGPoint(
            x: max(safeFrame.minX, safeFrame.maxX - panelSize.width),
            y: safeFrame.minY
        )
    }
}
