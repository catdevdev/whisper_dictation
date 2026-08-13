import Darwin
import Foundation

@main
private enum WhisperHUDLayoutVerification {
    static func main() {
        var verifier = Verifier()
        verifier.verifyGeometry()
        verifier.verifyScreenOrigins()

        if verifier.failureCount == 0 {
            print("Whisper HUD layout verification passed (\(verifier.checkCount) checks)")
        } else {
            fputs(
                "Whisper HUD layout verification failed: \(verifier.failureCount) of "
                    + "\(verifier.checkCount) checks failed\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }
    }
}

private struct Verifier {
    private(set) var checkCount = 0
    private(set) var failureCount = 0

    mutating func verifyGeometry() {
        expectEqual(HUDLayout.panelSize, CGSize(width: 60, height: 60), "panel size")
        expectEqual(HUDLayout.cardSize, CGSize(width: 44, height: 44), "card size")
        expectEqual(
            HUDLayout.panelSize.width - HUDLayout.cardSize.width,
            HUDLayout.outerPadding * 2,
            "horizontal shadow margin"
        )
        expectEqual(
            HUDLayout.panelSize.height - HUDLayout.cardSize.height,
            HUDLayout.outerPadding * 2,
            "vertical shadow margin"
        )
        expectEqual(
            ReadingHUDLayout.statusPanelSize.width
                - ReadingHUDLayout.statusCardSize.width,
            ReadingHUDLayout.outerPadding * 2,
            "reading status horizontal shadow margin"
        )
        expectEqual(
            ReadingHUDLayout.playbackPanelSize.height
                - ReadingHUDLayout.playbackCardSize.height,
            ReadingHUDLayout.outerPadding * 2,
            "reading playback vertical shadow margin"
        )
    }

    mutating func verifyScreenOrigins() {
        expectEqual(
            HUDLayout.origin(in: CGRect(x: 0, y: 0, width: 1_440, height: 900)),
            CGPoint(x: 1_356, y: 24),
            "lower-right origin on the main screen"
        )
        expectEqual(
            HUDLayout.origin(in: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080)),
            CGPoint(x: -84, y: 24),
            "lower-right origin on a screen left of the main screen"
        )
        expectEqual(
            HUDLayout.origin(in: CGRect(x: 0, y: 68, width: 1_440, height: 832)),
            CGPoint(x: 1_356, y: 92),
            "visible-frame Dock offset"
        )
        expectEqual(
            ReadingHUDLayout.origin(
                in: CGRect(x: 0, y: 0, width: 1_440, height: 900),
                panelSize: ReadingHUDLayout.playbackPanelSize
            ),
            CGPoint(x: 1_096, y: 24),
            "reading playback lower-right origin"
        )
        expectEqual(
            ReadingHUDLayout.origin(
                in: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
                panelSize: ReadingHUDLayout.statusPanelSize
            ),
            CGPoint(x: -310, y: 24),
            "reading status lower-right origin on a left screen"
        )
        expectEqual(
            ReadingHUDLayout.origin(
                in: CGRect(x: 0, y: 68, width: 1_440, height: 832),
                panelSize: ReadingHUDLayout.playbackPanelSize
            ),
            CGPoint(x: 1_096, y: 92),
            "reading playback respects the visible-frame Dock offset"
        )
    }

    private mutating func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) {
        checkCount += 1
        guard actual == expected else {
            failureCount += 1
            fputs("FAIL: \(label): expected \(expected), got \(actual)\n", stderr)
            return
        }
    }
}
