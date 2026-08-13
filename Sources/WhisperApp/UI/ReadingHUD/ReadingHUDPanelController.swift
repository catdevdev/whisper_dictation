import AppKit
import SwiftUI

/// A compact lower-right HUD for the reading gesture and Qwen speech controls.
/// Its non-activating panel keeps the selected app active while accepting mouse
/// input during playback.
@MainActor
final class ReadingHUDPanelController {
    private let model = ReadingHUDViewModel()
    private let actions: ReadingHUDActions
    private var panel: NonActivatingReadingHUDPanel?
    private var errorDismissTask: Task<Void, Never>?
    private var lastAnnouncementKey: String?

    init(actions: ReadingHUDActions) {
        self.actions = actions
    }

    func update(
        phase: ReadingPhase,
        progress: Double,
        voiceName: String?,
        rate: Float
    ) {
        errorDismissTask?.cancel()
        errorDismissTask = nil
        guard phase != .idle else {
            lastAnnouncementKey = nil
            hide()
            return
        }

        let announcement = switch phase {
        case .idle: ""
        case .preparing: "Qwen готовит речь"
        case .speaking: "Чтение началось"
        case .paused: "Чтение на паузе"
        }
        announce("reading-\(phase)", announcement)

        present(
            .reading(
                phase: phase,
                progress: Self.clamp(progress),
                voiceName: voiceName,
                rate: rate
            )
        )
    }

    func showGesture(progress: Double) {
        errorDismissTask?.cancel()
        errorDismissTask = nil
        announce("reading-gesture", "Чтение выделения активировано")
        present(.gesture(progress: Self.clamp(progress)))
    }

    func hideGesture() {
        guard case .gesture = model.presentation else { return }
        lastAnnouncementKey = nil
        hide()
    }

    func hide() {
        panel?.ignoresMouseEvents = true
        panel?.orderOut(nil)
    }

    func showError(_ message: String, duration: TimeInterval = 3) {
        errorDismissTask?.cancel()
        announce("reading-error-\(message)", message)
        let presentation = ReadingHUDPresentation.error(message: message)
        present(presentation)
        errorDismissTask = Task { [weak self] in
            let nanoseconds = UInt64(max(duration, 0.5) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled,
                  let self,
                  model.presentation == presentation else {
                return
            }
            panel?.orderOut(nil)
            errorDismissTask = nil
            lastAnnouncementKey = nil
        }
    }

    private func present(_ presentation: ReadingHUDPresentation) {
        model.presentation = presentation
        let panel = makePanelIfNeeded()
        let isPlayback: Bool
        if case .reading = presentation {
            isPlayback = true
        } else {
            isPlayback = false
        }
        let panelSize = isPlayback
            ? ReadingHUDLayout.playbackPanelSize
            : ReadingHUDLayout.statusPanelSize
        let sizeChanged = panel.frame.size != panelSize
        if sizeChanged {
            panel.setContentSize(panelSize)
        }
        panel.ignoresMouseEvents = !isPlayback
        if sizeChanged || !panel.isVisible {
            position(panel, panelSize: panelSize)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func makePanelIfNeeded() -> NonActivatingReadingHUDPanel {
        if let panel { return panel }

        let panel = NonActivatingReadingHUDPanel(
            contentRect: NSRect(
                origin: .zero,
                size: ReadingHUDLayout.statusPanelSize
            ),
            styleMask: [
                .borderless,
                .nonactivatingPanel,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .ignoresCycle
        ]
        panel.animationBehavior = NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
        panel.contentView = NSHostingView(
            rootView: ReadingHUDView(model: model, actions: actions)
        )
        panel.setContentSize(ReadingHUDLayout.statusPanelSize)
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel, panelSize: NSSize) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }

        let origin = ReadingHUDLayout.origin(
            in: visibleFrame,
            panelSize: panelSize
        )
        panel.setFrameOrigin(origin)
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value.isFinite ? value : 0, 0), 1)
    }

    private func announce(_ key: String, _ message: String) {
        guard lastAnnouncementKey != key, !message.isEmpty else { return }
        lastAnnouncementKey = key
        AccessibilityAnnouncer.announce(message)
    }
}

private final class NonActivatingReadingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
