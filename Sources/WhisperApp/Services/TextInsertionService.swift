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
    case accessibilityMenuPaste
    case keyboardShortcutPaste
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
/// frontmost captured destination without entering the global HID stream.
@MainActor
public final class TextInsertionService {
    private enum FocusedFieldInspectionOutcome: Sendable {
        case safe
        case unavailable
        case accessibilityPermissionRequired
        case secureTextField
        case inspectionFailed
    }

    private enum MenuPasteOutcome: Sendable {
        case pasted
        case unavailable
        case failed
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

    private enum StringLookup: Equatable {
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
    private nonisolated static let modifierTransitionDelayNanoseconds: UInt64 =
        20_000_000
    private nonisolated static let leftCommandKeyCode: CGKeyCode = 55
    private nonisolated static let physicalVKeyCode: CGKeyCode = 9

    private let pasteboard: NSPasteboard
    private let eventPoster: (CGEvent, pid_t) -> Void

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.eventPoster = { event, processIdentifier in
            event.postToPid(processIdentifier)
        }
    }

    /// Internal injection seam for verifying that fallback events stay scoped
    /// to the captured destination instead of entering the global HID stream.
    init(
        pasteboard: NSPasteboard,
        eventPoster: @escaping (CGEvent, pid_t) -> Void
    ) {
        self.pasteboard = pasteboard
        self.eventPoster = eventPoster
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

    /// Leaves the transcript on the shared clipboard and triggers Paste only
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
        switch await pasteUsingAccessibilityMenu(
            processIdentifier: target.processIdentifier
        ) {
        case .pasted:
            return .accessibilityMenuPaste
        case .unavailable, .failed:
            try await postPasteShortcut(to: target.processIdentifier)
            return .keyboardShortcutPaste
        }
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
    func makePasteShortcutEvents() throws -> (
        commandDown: CGEvent,
        keyDown: CGEvent,
        keyUp: CGEvent,
        commandUp: CGEvent
    ) {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw TextInsertionError.unableToCreateKeyboardEventSource
        }
        guard let commandDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: Self.leftCommandKeyCode,
                  keyDown: true
              ),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: Self.physicalVKeyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: Self.physicalVKeyCode,
                  keyDown: false
              ),
              let commandUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: Self.leftCommandKeyCode,
                  keyDown: false
              ) else {
            throw TextInsertionError.unableToCreateKeyboardEvent
        }

        // The sequence is posted directly to the captured process. Explicit
        // Command state therefore reaches the destination without a global
        // input remapper translating physical key code 9 first.
        commandDown.flags = .maskCommand
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        commandUp.flags = []
        return (commandDown, keyDown, keyUp, commandUp)
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

    /// Internal so the regression suite can prove every fallback event targets
    /// the captured process and never traverses Karabiner's global HID path.
    func postPasteShortcut(to processIdentifier: pid_t) async throws {
        let events = try makePasteShortcutEvents()
        eventPoster(events.commandDown, processIdentifier)
        try? await Task.sleep(
            nanoseconds: Self.modifierTransitionDelayNanoseconds
        )
        eventPoster(events.keyDown, processIdentifier)

        // Always emit key-up, including when cancellation arrives during the
        // short hold, so the destination never observes a stuck synthetic key.
        try? await Task.sleep(nanoseconds: Self.pasteKeyHoldNanoseconds)
        eventPoster(events.keyUp, processIdentifier)
        try? await Task.sleep(
            nanoseconds: Self.modifierTransitionDelayNanoseconds
        )
        eventPoster(events.commandUp, processIdentifier)
        try Task.checkCancellation()
    }

    private func pasteUsingAccessibilityMenu(
        processIdentifier: pid_t
    ) async -> MenuPasteOutcome {
        await Task.detached(priority: .userInitiated) {
            Self.performAccessibilityMenuPaste(
                processIdentifier: processIdentifier
            )
        }.value
    }

    private nonisolated static func performAccessibilityMenuPaste(
        processIdentifier: pid_t
    ) -> MenuPasteOutcome {
        guard AXIsProcessTrusted() else { return .failed }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + accessibilityOverallTimeoutNanoseconds
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(
            application,
            accessibilityMessagingTimeout
        )

        switch elementAttribute(
            kAXMenuBarAttribute,
            from: application,
            deadline: deadline
        ) {
        case let .element(menuBar):
            guard let pasteItem = findStandardPasteItem(
                in: menuBar,
                deadline: deadline
            ) else {
                return .unavailable
            }
            guard boolAttribute(
                kAXEnabledAttribute,
                from: pasteItem,
                deadline: deadline
            ) != false else {
                return .unavailable
            }
            return AXUIElementPerformAction(
                pasteItem,
                kAXPressAction as CFString
            ) == .success ? .pasted : .failed
        case .unavailable:
            return .unavailable
        case .failed:
            return .failed
        }
    }

    private nonisolated static func findStandardPasteItem(
        in menuBar: AXUIElement,
        deadline: UInt64
    ) -> AXUIElement? {
        for topLevelItem in childElements(
            of: menuBar,
            deadline: deadline
        ) {
            for menu in childElements(
                of: topLevelItem,
                deadline: deadline
            ) {
                for item in childElements(of: menu, deadline: deadline) {
                    let commandCharacter: String?
                    switch stringAttribute(
                        kAXMenuItemCmdCharAttribute,
                        from: item,
                        deadline: deadline
                    ) {
                    case let .value(value):
                        commandCharacter = value
                    case .unavailable, .failed:
                        commandCharacter = nil
                    }

                    let title: String?
                    switch stringAttribute(
                        kAXTitleAttribute,
                        from: item,
                        deadline: deadline
                    ) {
                    case let .value(value):
                        title = value
                    case .unavailable, .failed:
                        title = nil
                    }

                    guard isStandardPasteMenuItem(
                        commandCharacter: commandCharacter,
                        modifiers: integerAttribute(
                            kAXMenuItemCmdModifiersAttribute,
                            from: item,
                            deadline: deadline
                        ),
                        title: title
                    ) else {
                        continue
                    }
                    return item
                }
            }
        }
        return nil
    }

    /// Accessibility exposes the ordinary Paste command as Command-V with no
    /// extra modifiers. Localized titles cover applications that omit command
    /// metadata while excluding Paste-and-Match-Style variants.
    nonisolated static func isStandardPasteMenuItem(
        commandCharacter: String?,
        modifiers: Int?,
        title: String?
    ) -> Bool {
        if commandCharacter?.caseInsensitiveCompare("V") == .orderedSame,
           modifiers == 0 {
            return true
        }
        guard commandCharacter == nil, modifiers == nil, let title else {
            return false
        }
        return ["Paste", "Вставить", "Вставити"].contains(title)
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

    private nonisolated static func integerAttribute(
        _ attribute: String,
        from element: AXUIElement,
        deadline: UInt64
    ) -> Int? {
        guard hasTimeRemaining(until: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber else {
            return nil
        }
        return number.intValue
    }

    private nonisolated static func boolAttribute(
        _ attribute: String,
        from element: AXUIElement,
        deadline: UInt64
    ) -> Bool? {
        guard hasTimeRemaining(until: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let number = value as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    private nonisolated static func childElements(
        of element: AXUIElement,
        deadline: UInt64
    ) -> [AXUIElement] {
        guard hasTimeRemaining(until: deadline) else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &value
        ) == .success,
        let children = value as? [AXUIElement] else {
            return []
        }
        for child in children {
            AXUIElementSetMessagingTimeout(child, accessibilityMessagingTimeout)
        }
        return children
    }

    private nonisolated static func hasTimeRemaining(
        until deadline: UInt64
    ) -> Bool {
        DispatchTime.now().uptimeNanoseconds < deadline
    }
}
