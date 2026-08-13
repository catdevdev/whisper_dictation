import AppKit
import ApplicationServices
import Foundation
import OSLog

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
    case accessibilityValueInsertion
    case accessibilityMenuPaste
    case unicodeTextInsertion
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
            "A Unicode text event source could not be created."
        case .unableToCreateKeyboardEvent:
            "A Unicode text event could not be created."
        }
    }
}

/// Copies a transcript to the shared clipboard, then inserts it into the
/// frontmost captured destination without relying on a physical V key.
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

    enum AccessibilityTextInsertionOutcome: Equatable, Sendable {
        case inserted
        case unavailable
        case accessibilityPermissionRequired
        case secureTextField
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
    private nonisolated static let maximumTextAncestorDepth = 8
    private nonisolated static let clipboardPropagationDelayNanoseconds: UInt64 =
        80_000_000
    private nonisolated static let unicodeKeyHoldNanoseconds: UInt64 = 8_000_000
    private nonisolated static let unicodeEventDelayNanoseconds: UInt64 = 8_000_000
    private nonisolated static let maximumUnicodeUnitsPerEvent = 16
    private nonisolated static let unicodeCarrierKeyCode: CGKeyCode = 0
    private nonisolated static let logger = Logger(
        subsystem: "com.nekoneki.whisper-dictation.app",
        category: "TextInsertion"
    )

    private let pasteboard: NSPasteboard
    private let eventPoster: (CGEvent, pid_t) -> Void

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.eventPoster = { event, processIdentifier in
            event.postToPid(processIdentifier)
        }
    }

    /// Internal injection seam for verifying that Unicode fallback events stay
    /// scoped to the destination instead of entering the global HID stream.
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

    /// Leaves the transcript on the shared clipboard and inserts it only after
    /// confirming that the captured destination is still frontmost.
    @discardableResult
    public func insert(
        _ text: String,
        into target: TextInsertionTarget
    ) async throws -> TextInsertionMethod {
        try Task.checkCancellation()

        // Copy first so a successfully transcribed result remains recoverable
        // even when the destination disappears or rejects text insertion.
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
        // insertion matches how native applications observe a new owner reliably.
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
            Self.logInsertionRoute(
                "accessibility-menu",
                target: target
            )
            return .accessibilityMenuPaste
        case .unavailable:
            Self.logUnavailableRoute(
                "accessibility-menu",
                target: target
            )
        case .failed:
            Self.logFailedRoute(
                "accessibility-menu",
                target: target
            )
            break
        }

        try validate(target)
        try validateFrontmost(target)
        switch await insertUsingAccessibilityValue(
            text,
            processIdentifier: target.processIdentifier
        ) {
        case .inserted:
            Self.logInsertionRoute(
                "accessibility-value",
                target: target
            )
            return .accessibilityValueInsertion
        case .accessibilityPermissionRequired:
            throw TextInsertionError.accessibilityPermissionRequired
        case .secureTextField:
            throw TextInsertionError.secureTextField
        case .unavailable:
            Self.logUnavailableRoute(
                "accessibility-value",
                target: target
            )
            try await postUnicodeText(
                text,
                to: target.processIdentifier
            )
            Self.logInsertionRoute("unicode-events", target: target)
            return .unicodeTextInsertion
        case .failed:
            Self.logFailedRoute(
                "accessibility-value",
                target: target
            )
            try await postUnicodeText(
                text,
                to: target.processIdentifier
            )
            Self.logInsertionRoute("unicode-events", target: target)
            return .unicodeTextInsertion
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

    /// Creates targeted text events with an explicit Unicode payload. The
    /// carrier key is never V, and no keyboard-layout modifier participates.
    func makeUnicodeInsertionEvents(
        _ text: String
    ) throws -> [(text: String, keyDown: CGEvent, keyUp: CGEvent)] {
        guard let source = CGEventSource(stateID: .privateState) else {
            throw TextInsertionError.unableToCreateKeyboardEventSource
        }
        return try Self.unicodeChunks(text).map { chunk in
            guard let keyDown = CGEvent(
                      keyboardEventSource: source,
                      virtualKey: Self.unicodeCarrierKeyCode,
                      keyDown: true
                  ),
                  let keyUp = CGEvent(
                      keyboardEventSource: source,
                      virtualKey: Self.unicodeCarrierKeyCode,
                      keyDown: false
                  ) else {
                throw TextInsertionError.unableToCreateKeyboardEvent
            }
            let units = Array(chunk.utf16)
            units.withUnsafeBufferPointer { buffer in
                keyDown.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: buffer.baseAddress
                )
            }
            keyDown.flags = []
            keyUp.flags = []
            return (chunk, keyDown, keyUp)
        }
    }

    nonisolated static func unicodeChunks(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        var currentUnitCount = 0

        for character in text {
            let characterText = String(character)
            let characterUnitCount = characterText.utf16.count
            if !current.isEmpty,
               currentUnitCount + characterUnitCount
                   > maximumUnicodeUnitsPerEvent {
                chunks.append(current)
                current = ""
                currentUnitCount = 0
            }
            current.append(character)
            currentUnitCount += characterUnitCount
        }
        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    /// Computes an AXValue edit using the UTF-16 offsets exposed by macOS
    /// Accessibility. Internal for deterministic Unicode/caret regression tests.
    nonisolated static func replacingTextValue(
        _ currentValue: String,
        selectedRange: CFRange,
        with insertedText: String
    ) -> (value: String, caretRange: CFRange)? {
        let source = currentValue as NSString
        guard selectedRange.location >= 0,
              selectedRange.length >= 0,
              selectedRange.location <= source.length,
              selectedRange.length <= source.length - selectedRange.location else {
            return nil
        }

        let value = source.replacingCharacters(
            in: NSRange(
                location: selectedRange.location,
                length: selectedRange.length
            ),
            with: insertedText
        )
        return (
            value,
            CFRange(
                location: selectedRange.location
                    + (insertedText as NSString).length,
                length: 0
            )
        )
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

    /// Internal so tests can prove fallback carries the transcript itself and
    /// never emits a physical V that RussianWin could translate into "м".
    func postUnicodeText(
        _ text: String,
        to processIdentifier: pid_t
    ) async throws {
        for events in try makeUnicodeInsertionEvents(text) {
            eventPoster(events.keyDown, processIdentifier)
            // Keep key-up guaranteed even if cancellation arrives mid-event.
            try? await Task.sleep(
                nanoseconds: Self.unicodeKeyHoldNanoseconds
            )
            eventPoster(events.keyUp, processIdentifier)
            try await Task.sleep(
                nanoseconds: Self.unicodeEventDelayNanoseconds
            )
        }
    }

    private func insertUsingAccessibilityValue(
        _ text: String,
        processIdentifier: pid_t
    ) async -> AccessibilityTextInsertionOutcome {
        await Task.detached(priority: .userInitiated) {
            Self.performAccessibilityTextInsertion(
                text,
                processIdentifier: processIdentifier
            )
        }.value
    }

    /// Uses the editable element's AXValue and AXSelectedTextRange so no
    /// keyboard event, input source, or remapper participates in insertion.
    nonisolated static func performAccessibilityTextInsertion(
        _ text: String,
        processIdentifier: pid_t
    ) -> AccessibilityTextInsertionOutcome {
        guard AXIsProcessTrusted() else {
            return .accessibilityPermissionRequired
        }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + accessibilityOverallTimeoutNanoseconds
        let focused: AXUIElement
        switch focusedElement(for: processIdentifier, deadline: deadline) {
        case let .element(element):
            focused = element
        case .unavailable:
            return .unavailable
        case .failed:
            return .failed
        }

        switch secureFieldStatus(for: focused, deadline: deadline) {
        case .secure:
            return .secureTextField
        case .inspectionFailed:
            return .failed
        case .notSecure:
            break
        }

        // Setting AXValue on a browser-backed control can bypass the DOM input
        // event expected by web frameworks. Let Unicode key events reach those
        // editors instead, while retaining direct AX edits for native fields.
        guard !isWebBackedOrIndeterminate(
            focused,
            deadline: deadline
        ) else {
            return .unavailable
        }

        var current = focused
        var visited: [AXUIElement] = []
        var observedFailure = false

        for depth in 0...maximumTextAncestorDepth {
            visited.append(current)
            switch replaceSelectedTextValue(
                text,
                in: current,
                deadline: deadline
            ) {
            case .inserted:
                return .inserted
            case .failed:
                observedFailure = true
            case .unavailable, .accessibilityPermissionRequired, .secureTextField:
                break
            }

            guard depth < maximumTextAncestorDepth else { break }
            switch elementAttribute(
                kAXParentAttribute,
                from: current,
                deadline: deadline
            ) {
            case let .element(parent):
                guard !visited.contains(where: { CFEqual($0, parent) }) else {
                    break
                }
                current = parent
            case .unavailable:
                break
            case .failed:
                observedFailure = true
                break
            }
        }

        return observedFailure ? .failed : .unavailable
    }

    nonisolated static func replaceSelectedTextValue(
        _ text: String,
        in element: AXUIElement,
        deadline: UInt64
    ) -> AccessibilityTextInsertionOutcome {
        let role: String?
        switch stringAttribute(
            kAXRoleAttribute,
            from: element,
            deadline: deadline
        ) {
        case let .value(value):
            role = value
        case .unavailable:
            role = nil
        case .failed:
            return .failed
        }
        guard isEditableTextRole(role) else { return .unavailable }

        guard attributeIsSettable(
            kAXValueAttribute,
            on: element,
            deadline: deadline
        ) else {
            return .unavailable
        }

        let currentValue: String
        switch stringAttribute(
            kAXValueAttribute,
            from: element,
            deadline: deadline
        ) {
        case let .value(value):
            currentValue = value
        case .unavailable:
            return .unavailable
        case .failed:
            return .failed
        }

        let selectedRange: CFRange
        if let range = rangeAttribute(
            kAXSelectedTextRangeAttribute,
            from: element,
            deadline: deadline
        ) {
            selectedRange = range
        } else if currentValue.isEmpty {
            selectedRange = CFRange(location: 0, length: 0)
        } else {
            return .unavailable
        }

        guard let replacement = replacingTextValue(
            currentValue,
            selectedRange: selectedRange,
            with: text
        ) else {
            return .failed
        }

        guard hasTimeRemaining(until: deadline) else { return .failed }
        let setResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            replacement.value as CFString
        )
        guard setResult == .success else {
            if setResult == .cannotComplete,
               case let .value(observedValue) = stringAttribute(
                   kAXValueAttribute,
                   from: element,
                   deadline: deadline
               ),
               observedValue == replacement.value {
                return .inserted
            }
            return setResult == .attributeUnsupported
                || setResult == .noValue
                || setResult == .notImplemented
                ? .unavailable
                : .failed
        }

        if attributeIsSettable(
            kAXSelectedTextRangeAttribute,
            on: element,
            deadline: deadline
        ), var caretRange = Optional(replacement.caretRange),
           let caretValue = AXValueCreate(.cfRange, &caretRange) {
            _ = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextRangeAttribute as CFString,
                caretValue
            )
        }
        return .inserted
    }

    nonisolated static func isEditableTextRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == (kAXTextFieldRole as String)
            || role == (kAXTextAreaRole as String)
            || role == (kAXComboBoxRole as String)
    }

    private nonisolated static func isWebBackedOrIndeterminate(
        _ element: AXUIElement,
        deadline: UInt64
    ) -> Bool {
        var current = element
        var visited: [AXUIElement] = []

        for depth in 0...maximumTextAncestorDepth {
            visited.append(current)
            switch stringAttribute(
                kAXRoleAttribute,
                from: current,
                deadline: deadline
            ) {
            case let .value(role):
                if role == "AXWebArea" { return true }
            case .unavailable:
                break
            case .failed:
                return true
            }

            guard depth < maximumTextAncestorDepth else { break }
            switch elementAttribute(
                kAXParentAttribute,
                from: current,
                deadline: deadline
            ) {
            case let .element(parent):
                guard !visited.contains(where: { CFEqual($0, parent) }) else {
                    return false
                }
                current = parent
            case .unavailable:
                return false
            case .failed:
                return true
            }
        }
        return false
    }

    private nonisolated static func logInsertionRoute(
        _ route: String,
        target: TextInsertionTarget
    ) {
        logger.notice(
            "Insertion succeeded route=\(route, privacy: .public) target=\(target.bundleIdentifier ?? "unknown", privacy: .public)"
        )
    }

    private nonisolated static func logUnavailableRoute(
        _ route: String,
        target: TextInsertionTarget
    ) {
        logger.info(
            "Insertion unavailable route=\(route, privacy: .public) target=\(target.bundleIdentifier ?? "unknown", privacy: .public)"
        )
    }

    private nonisolated static func logFailedRoute(
        _ route: String,
        target: TextInsertionTarget
    ) {
        logger.error(
            "Insertion failed route=\(route, privacy: .public) target=\(target.bundleIdentifier ?? "unknown", privacy: .public)"
        )
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

    private nonisolated static func attributeIsSettable(
        _ attribute: String,
        on element: AXUIElement,
        deadline: UInt64
    ) -> Bool {
        guard hasTimeRemaining(until: deadline) else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element,
            attribute as CFString,
            &settable
        ) == .success else {
            return false
        }
        return settable.boolValue
    }

    private nonisolated static func rangeAttribute(
        _ attribute: String,
        from element: AXUIElement,
        deadline: UInt64
    ) -> CFRange? {
        guard hasTimeRemaining(until: deadline) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            attribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
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
