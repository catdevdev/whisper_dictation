import AppKit
import SwiftUI

@MainActor
final class HUDPanelController {
    private let model = HUDViewModel()
    private var panel: NonActivatingHUDPanel?
    private var dismissTask: Task<Void, Never>?
    private var lastAnnouncementKey: String?

    func update(for phase: DictationPhase) {
        dismissTask?.cancel()

        switch phase {
        case .idle:
            lastAnnouncementKey = nil
            hide()
        case .armed:
            announce("dictation-armed", "Диктовка активирована")
            present(.armed)
        case let .holding(progress):
            present(.holding(progress: progress))
        case let .recording(level):
            announce("dictation-recording", "Запись началась")
            present(.recording(level: level))
        case .transcribing:
            announce("dictation-transcribing", "Распознаю запись")
            present(.transcribing)
        case .success:
            announce("dictation-success", "Диктовка вставлена")
            present(.success)
            dismiss(after: 1.4)
        case let .failure(message):
            announce("dictation-failure-\(message)", message)
            present(.failure(message: message))
            dismiss(after: 4)
        }
    }

    func hide() {
        dismissTask?.cancel()
        panel?.orderOut(nil)
    }

    private func present(_ presentation: HUDPresentation) {
        model.presentation = presentation
        let panel = makePanelIfNeeded()
        if !panel.isVisible {
            position(panel)
            panel.orderFrontRegardless()
        }
    }

    private func dismiss(after seconds: TimeInterval) {
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func announce(_ key: String, _ message: String) {
        guard lastAnnouncementKey != key else { return }
        lastAnnouncementKey = key
        AccessibilityAnnouncer.announce(message)
    }

    private func makePanelIfNeeded() -> NonActivatingHUDPanel {
        if let panel { return panel }

        let contentSize = NSSize(
            width: HUDLayout.panelSize.width,
            height: HUDLayout.panelSize.height
        )
        let panel = NonActivatingHUDPanel(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
        panel.setContentSize(contentSize)
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }

        let origin = HUDLayout.origin(
            in: visibleFrame,
            panelSize: panel.frame.size
        )
        panel.setFrameOrigin(origin)
    }
}

private final class NonActivatingHUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
