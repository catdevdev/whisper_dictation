import AppKit
import SwiftUI

@main
struct WhisperApplication: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ControlCenterView(
                controller: appDelegate.controller,
                openSettings: appDelegate.presentSettings
            )
        } label: {
            MenuBarLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let showSettingsNotification = Notification.Name(
        "com.nekoneki.whisper.show-settings"
    )

    let controller = AppController()
    private var instanceGuard: SingleInstanceGuard?
    private lazy var settingsWindowController = SettingsWindowController(
        controller: controller
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            guard let guardToken = try SingleInstanceGuard.acquire() else {
                DistributedNotificationCenter.default().postNotificationName(
                    Self.showSettingsNotification,
                    object: nil,
                    userInfo: nil,
                    deliverImmediately: true
                )
                activateExistingInstance()
                DispatchQueue.main.async {
                    NSApplication.shared.terminate(nil)
                }
                return
            }
            instanceGuard = guardToken
        } catch {
            presentStartupFailure(error)
            NSApplication.shared.terminate(nil)
            return
        }

        NSApplication.shared.setActivationPolicy(.accessory)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowSettingsNotification),
            name: Self.showSettingsNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
        controller.start()

        let forcePresentation = CommandLine.arguments.contains("--open-settings")
        let needsFirstSetup = !controller.preferences.didPresentSetup
            && !controller.isDictationOperational
        if forcePresentation || needsFirstSetup {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                presentSettings()
                if needsFirstSetup {
                    controller.preferences.didPresentSetup = true
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        controller.shutdown()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller.refreshReadiness()
        controller.refreshLoginItemState()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        presentSettings()
        return true
    }

    func presentSettings() {
        controller.refreshReadiness()
        controller.refreshLoginItemState()
        settingsWindowController.present()
    }

    @objc
    private func handleShowSettingsNotification(_ notification: Notification) {
        presentSettings()
    }

    private func activateExistingInstance() {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { $0.processIdentifier != currentPID }?
            .activate(options: [.activateAllWindows])
    }

    private func presentStartupFailure(_ error: Error) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Whisper не удалось запустить безопасно"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}
