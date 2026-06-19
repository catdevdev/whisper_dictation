import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow!
    private var costLabel: NSTextField!
    private var speedLabel: NSTextField!
    private var speedSlider: NSSlider!
    private var logView: NSTextView!
    private var refreshTimer: Timer?

    private let costURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".openai_voice_costs.json")
    private let settingsURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".whisper_dictation_tts.json")
    private let stopURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".whisper_dictation_tts_stop")
    private let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".whisper_dictation/whisper_dictation.log")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        buildWindow()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        if #available(macOS 11.0, *) {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Whisper Dictation")
            button.image?.isTemplate = true
        } else {
            button.title = "W"
        }
        button.toolTip = "Whisper Dictation"
        button.target = self
        button.action = #selector(toggleWindow)
    }

    private func buildWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 388),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = "Whisper Logs & Costs"
        window.isReleasedWhenClosed = false
        window.level = .floating

        let root = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 560, height: 388))
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        costLabel = label(frame: NSRect(x: 16, y: 344, width: 528, height: 24), size: 16, bold: true)
        root.addSubview(costLabel)

        let speedTitle = label(frame: NSRect(x: 16, y: 306, width: 78, height: 24), text: "TTS speed", size: 13, bold: true)
        root.addSubview(speedTitle)

        speedSlider = NSSlider(value: currentSpeed(), minValue: 0.65, maxValue: 3.0, target: self, action: #selector(speedChanged(_:)))
        speedSlider.frame = NSRect(x: 96, y: 307, width: 344, height: 24)
        speedSlider.numberOfTickMarks = 0
        root.addSubview(speedSlider)

        speedLabel = label(frame: NSRect(x: 454, y: 306, width: 90, height: 24), size: 13, bold: true)
        root.addSubview(speedLabel)

        let resetButton = button(title: "Reset Speed", frame: NSRect(x: 16, y: 268, width: 116, height: 30), action: #selector(resetSpeed))
        root.addSubview(resetButton)

        let stopButton = button(title: "Stop TTS", frame: NSRect(x: 144, y: 268, width: 92, height: 30), action: #selector(stopTTS))
        root.addSubview(stopButton)

        let refreshButton = button(title: "Refresh Logs", frame: NSRect(x: 248, y: 268, width: 112, height: 30), action: #selector(refreshClicked))
        root.addSubview(refreshButton)

        let quitButton = button(title: "Quit", frame: NSRect(x: 468, y: 268, width: 76, height: 30), action: #selector(quit))
        root.addSubview(quitButton)

        let scrollView = NSScrollView(frame: NSRect(x: 16, y: 16, width: 528, height: 238))
        scrollView.hasVerticalScroller = true
        scrollView.autoresizingMask = [.width, .height]
        logView = NSTextView(frame: scrollView.bounds)
        logView.isEditable = false
        logView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = NSColor(calibratedRed: 0.48, green: 1.0, blue: 0.70, alpha: 1.0)
        logView.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 1.0)
        scrollView.documentView = logView
        root.addSubview(scrollView)
    }

    private func label(frame: NSRect, text: String = "", size: CGFloat, bold: Bool) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.frame = frame
        field.font = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
        return field
    }

    private func button(title: String, frame: NSRect, action: Selector) -> NSButton {
        let button = NSButton(frame: frame)
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        return button
    }

    @objc private func toggleWindow() {
        if window.isVisible {
            window.orderOut(nil)
            return
        }
        refresh()
        positionWindow()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionWindow() {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let x = frame.maxX - window.frame.width - 12
        let y = frame.maxY - window.frame.height - 12
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    @objc private func speedChanged(_ sender: NSSlider) {
        saveSpeed(sender.doubleValue)
        refresh()
    }

    @objc private func resetSpeed() {
        saveSpeed(2.0)
        refresh()
    }

    @objc private func stopTTS() {
        FileManager.default.createFile(atPath: stopURL.path, contents: Data(), attributes: nil)
    }

    @objc private func refreshClicked() {
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func refresh() {
        let speed = currentSpeed()
        speedSlider?.doubleValue = speed
        speedLabel?.stringValue = String(format: "%.2fx", speed)
        costLabel?.stringValue = costText()
        logView?.string = logTail()
        logView?.scrollToEndOfDocument(nil)
        statusItem?.button?.toolTip = String(format: "Whisper Dictation - %@", speedLabel?.stringValue ?? "")
    }

    private func currentSpeed() -> Double {
        guard
            let data = try? Data(contentsOf: settingsURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let speed = object["speed"] as? Double
        else {
            return 2.0
        }
        return min(3.0, max(0.65, speed))
    }

    private func saveSpeed(_ speed: Double) {
        let clamped = min(3.0, max(0.65, speed))
        let payload: [String: Any] = ["speed": clamped]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else { return }
        try? data.write(to: settingsURL, options: [.atomic])
    }

    private func costText() -> String {
        guard
            let data = try? Data(contentsOf: costURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return "Total Whisper spend: $0.00000"
        }
        let month = object["month"] as? String ?? ""
        let total = object["total_cost"] as? Double ?? 0.0
        return String(format: "Total Whisper spend (%@): $%.5f", month, total)
    }

    private func logTail() -> String {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else {
            return "No log file yet: \(logURL.path)"
        }
        return String(text.suffix(14000))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
