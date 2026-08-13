import AppKit
import SwiftUI

/// Owns exactly one Settings window and brings that same window forward for
/// menu clicks, first launch, app reopen, and duplicate-launch commands.
@MainActor
final class SettingsWindowController: NSWindowController {
    private var hasPositionedWindow = false

    init(controller: AppController) {
        let hostingController = NSHostingController(
            rootView: SettingsView(controller: controller)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Настройки Whisper"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 620))
        window.minSize = NSSize(width: 720, height: 580)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.setFrameAutosaveName("WhisperSettingsWindow")

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func present() {
        guard let window else { return }
        if !hasPositionedWindow,
           !window.setFrameUsingName("WhisperSettingsWindow") {
            window.center()
        }
        hasPositionedWindow = true

        NSApplication.shared.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}
