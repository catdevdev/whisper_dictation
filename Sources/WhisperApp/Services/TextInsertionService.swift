import AppKit
import ApplicationServices
import Foundation

/// The application that owns the field where text should be inserted.
public struct TextInsertionTarget: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let bundleIdentifier: String?
    public let localizedName: String?

    public init(
        processIdentifier: pid_t,
        bundleIdentifier: String? = nil,
        localizedName: String? = nil
    ) {
        self.processIdentifier = processIdentifier
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
    }
}

public enum TextInsertionMethod: Equatable, Sendable {
    case clipboardPaste
}

public enum TextInsertionError: LocalizedError, Sendable {
    case targetUnavailable
    case targetIdentityChanged
    case targetNotFrontmost
    case accessibilityPermissionRequired
    case secureTextField
    case focusedFieldInspectionFailed
    case unableToWritePasteboard
    case unableToCreateKeyboardEventSource
    case unableToCreateKeyboardEvent

    public var errorDescription: String? {
        switch self {
        case .targetUnavailable:
            "The application selected for dictation is no longer running."
        case .targetIdentityChanged:
            "The application selected for dictation no longer matches the captured process."
        case .targetNotFrontmost:
            "The application selected for dictation is no longer frontmost."
        case .accessibilityPermissionRequired:
            "Allow Accessibility access for Whisper before inserting dictated text."
        case .secureTextField:
            "Whisper does not insert dictated text into secure text fields."
        case .focusedFieldInspectionFailed:
            "The destination field could not be checked safely. Focus it again and retry."
        case .unableToWritePasteboard:
            "The transcript could not be written to the clipboard."
        case .unableToCreateKeyboardEventSource:
            "A paste keyboard event source could not be created."
        case .unableToCreateKeyboardEvent:
            "A paste keyboard event could not be created."
        }
    }
}

/// Copies a transcript to the shared clipboard, then pastes it into the
/// frontmost captured destination with the physical Command-V shortcut.
@MainActor
public final class TextInsertionService {
    private enum FocusedFieldInspectionOutcome: Sendable {
        case safe
        case unavailable
        case accessibilityPermissionRequired
        case secureTextField
        case inspectionFailed
    }

    private enum SecureFieldStatus {
        case notSecure
        case secure
        case inspectionFailed
    }

    private enum ElementLookup {
        case element(AXUIElement)
        case unavailable
        case failed

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    private enum StringLookup {
        case value(String)
        case unavailable
        case failed
    }

    private nonisolated static let accessibilityMessagingTimeout: Float = 0.2
    private nonisolated static let accessibilityOverallTimeoutNanoseconds: UInt64 =
        900_000_000
    private nonisolated static let maximumSecureFieldAncestorDepth = 4
    private nonisolated static let clipboardPropagationDelayNanoseconds: UInt64 =
        80_000_000
    private nonisolated static let pasteKeyHoldNanoseconds: UInt64 = 35_000_000
    private nonisolated static let physicalVKeyCode: CGKeyCode = 9

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Resolves the frontmost destination at the moment recording begins.
    public func captureTarget(
        excludingCurrentProcess: Bool = true
    ) -> TextInsertionTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            return nil
        }
        if excludingCurrentProcess,
           application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return nil
        }
        return TextInsertionTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            localizedName: application.localizedName
        )
    }

    /// Leaves the transcript on the shared clipboard and sends Command-V only
    /// after confirming that the captured destination is still frontmost.
    @discardableResult
    public func insert(
        _ text: String,
        into target: TextInsertionTarget
    ) async throws -> TextInsertionMethod {
        try Task.checkCancellation()

        // Copy first so a successfully transcribed result remains recoverable
        // even when the destination disappears or rejects the paste shortcut.
        try writeTranscriptToClipboard(text)
        try validate(target)

        switch await inspectFocusedField(processIdentifier: target.processIdentifier) {
        case .safe, .unavailable:
            break
        case .accessibilityPermissionRequired:
            throw TextInsertionError.accessibilityPermissionRequired
        case .secureTextField:
            throw TextInsertionError.secureTextField
        case .inspectionFailed:
            throw TextInsertionError.focusedFieldInspectionFailed
        }

        // The pasteboard API is synchronous, but a short boundary before the
        // shortcut matches how native applications observe a new owner reliably.
        try await Task.sleep(nanoseconds: Self.clipboardPropagationDelayNanoseconds)
        try Task.checkCancellation()
        guard pasteboard.string(forType: .string) == text else {
            // A clipboard manager or another process won the race. Restore the
            // transcript and stop instead of pasting unrelated clipboard data.
            try writeTranscriptToClipboard(text)
            throw TextInsertionError.unableToWritePasteboard
        }

        try validate(target)
        try validateFrontmost(target)
        try await postPasteShortcut()
        return .clipboardPaste
    }

    /// Internal for deterministic service verification with a named pasteboard.
    @discardableResult
    func writeTranscriptToClipboard(_ text: String) throws -> Int {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string),
              pasteboard.string(forType: .string) == text else {
            throw TextInsertionError.unableToWritePasteboard
        }
        return pasteboard.changeCount
    }

    /// Internal so tests can verify the layout-independent shortcut without
    /// posting an event to the user's active application.
    func makePasteShortcutEvents() throws -> (keyDown: CGEvent, keyUp: CGEvent) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw TextInsertionError.unableToCreateKeyboardEventSource
        }
        guard let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: Self.physicalVKeyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: Self.physicalVKeyCode,
                  keyDown: false
              ) else {
            throw TextInsertionError.unableToCreateKeyboardEvent
        }

        // Key code 9 is the physical V key, so the shortcut is independent of
        // the active Russian, Ukrainian, or English keyboard layout.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        return (keyDown, keyUp)
    }

    private func validate(_ target: TextInsertionTarget) throws {
        guard target.processIdentifier > 0,
              let runningApplication = NSRunningApplication(
                  processIdentifier: target.processIdentifier
              ),
              !runningApplication.isTerminated else {
            throw TextInsertionError.targetUnavailable
        }
        guard let capturedBundleIdentifier = target.bundleIdentifier,
              !capturedBundleIdentifier.isEmpty,
              runningApplication.bundleIdentifier == capturedBundleIdentifier else {
            throw TextInsertionError.targetIdentityChanged
        }
    }

    private func validateFrontmost(_ target: TextInsertionTarget) throws {
        guard let frontmostApplication = NSWorkspace.shared.frontmostApplication,
              frontmostApplication.processIdentifier == target.processIdentifier,
              frontmostApplication.bundleIdentifier == target.bundleIdentifier else {
            throw TextInsertionError.targetNotFrontmost
        }
    }

    private func postPasteShortcut() async throws {
        let events = try makePasteShortcutEvents()
        events.keyDown.post(tap: .cghidEventTap)

        // Always emit key-up, including when cancellation arrives during the
        // short hold, so the destination never observes a stuck synthetic key.
        try? await Task.sleep(nanoseconds: Self.pasteKeyHoldNanoseconds)
        events.keyUp.post(tap: .cghidEventTap)
        try Task.checkCancellation()
    }

    private func inspectFocusedField(
        processIdentifier: pid_t
    ) async -> FocusedFieldInspectionOutcome {
        // AX IPC can block until the destination's messaging timeout when an
        // application is hung. Keep the synchronous work off MainActor.
        await Task.detached(priority: .userInitiated) {
            Self.performFocusedFieldInspection(
                processIdentifier: processIdentifier
            )
        }.value
    }

    private nonisolated static func performFocusedFieldInspection(
        processIdentifier: pid_t
    ) -> FocusedFieldInspectionOutcome {
        guard AXIsProcessTrusted() else {
            return .accessibilityPermissionRequired
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + accessibilityOverallTimeoutNanoseconds

        switch focusedElement(for: processIdentifier, deadline: deadline) {
        case let .element(focusedElement):
            switch secureFieldStatus(
                for: focusedElement,
                deadline: deadline
            ) {
            case .secure:
                return .secureTextField
            case .inspectionFailed:
                return .inspectionFailed
            case .notSecure:
                return .safe
            }
        case .unavailable:
            return .unavailable
        case .failed:
            return .inspectionFailed
        }
    }

    private nonisolated static func focusedElement(
        for processIdentifier: pid_t,
        deadline: UInt64
    ) -> ElementLookup {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(
            application,
            accessibilityMessagingTimeout
        )

        let applicationLookup = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: application,
            deadline: deadline
        )
        switch applicationLookup {
        case let .element(element):
            return .element(element)
        case .failed, .unavailable:
            break
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, accessibilityMessagingTimeout)
        switch elementAttribute(
            kAXFocusedUIElementAttribute,
            from: system,
            deadline: deadline
        ) {
        case let .element(element):
            var ownerPID: pid_t = 0
            guard AXUIElementGetPid(element, &ownerPID) == .success,
                  ownerPID == processIdentifier else {
                return applicationLookup.isFailure ? .failed : .unavailable
            }
            return .element(element)
        case .unavailable:
            return applicationLookup.isFailure ? .failed : .unavailable
        case .failed:
            return .failed
        }
    }

    private nonisolated static func secureFieldStatus(
        for focusedElement: AXUIElement,
        deadline: UInt64
    ) -> SecureFieldStatus {
        var current = focusedElement

        for depth in 0...maximumSecureFieldAncestorDepth {
            switch stringAttribute(
                kAXSubroleAttribute,
                from: current,
                deadline: deadline
            ) {
            case let .value(subrole):
                if subrole == (kAXSecureTextFieldSubrole as String) {
                    return .secure
                }
            case .unavailable:
                break
            case .failed:
                return .inspectionFailed
            }

            guard depth < maximumSecureFieldAncestorDepth else { break }
            switch elementAttribute(
                kAXParentAttribute,
                from: current,
                deadline: deadline
            ) {
            case let .element(parent):
                guard !CFEqual(current, parent) else { return .notSecure }
                current = parent
            case .unavailable:
                return .notSecure
            case .failed:
                return .inspectionFailed
            }
        }

        return .notSecure
    }

    private nonisolated static func elementAttribute(
        _ attribute: String,
        from element: AXUIElement,
        deadline: UInt64
    ) -> ElementLookup {
        guard hasTimeRemaining(until: deadline) else { return .failed }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        guard result == .success else {
            return result == .attributeUnsupported || result == .noValue
                ? .unavailable
                : .failed
        }
        guard let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .unavailable
        }

        let child = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(child, accessibilityMessagingTimeout)
        return .element(child)
    }

    private nonisolated static func stringAttribute(
        _ attribute: String,
        from element: AXUIElement,
        deadline: UInt64
    ) -> StringLookup {
        guard hasTimeRemaining(until: deadline) else { return .failed }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        )
        guard result == .success else {
            return result == .attributeUnsupported || result == .noValue
                ? .unavailable
                : .failed
        }
        guard let string = value as? String else { return .unavailable }
        return .value(string)
    }

    private nonisolated static func hasTimeRemaining(
        until deadline: UInt64
    ) -> Bool {
        DispatchTime.now().uptimeNanoseconds < deadline
    }
}
