import AppKit
import ApplicationServices
import Foundation

struct SelectedTextTarget: Equatable, Sendable {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let localizedName: String?
}

enum SelectedTextError: LocalizedError, Sendable {
    case accessibilityRequired
    case targetUnavailable
    case targetIdentityChanged
    case targetNoLongerFrontmost
    case focusedElementUnavailable
    case secureTextField
    case copyUnavailable
    case clipboardSnapshotUnavailable
    case clipboardChanged
    case clipboardRestoreFailed
    case rightOptionStillPressed
    case requestInProgress
    case noSelection

    var errorDescription: String? {
        switch self {
        case .accessibilityRequired:
            "Разрешите Whisper Универсальный доступ, чтобы читать выделенный текст."
        case .targetUnavailable:
            "Приложение с выделенным текстом уже закрыто."
        case .targetIdentityChanged:
            "Приложение с выделенным текстом изменилось. Выделите текст ещё раз."
        case .targetNoLongerFrontmost:
            "Активное приложение изменилось. Вернитесь к тексту и повторите жест."
        case .focusedElementUnavailable:
            "Не удалось определить активное поле с текстом."
        case .secureTextField:
            "Whisper не читает текст из защищённых полей."
        case .copyUnavailable:
            "Не удалось безопасно запросить выделенный текст у приложения."
        case .clipboardSnapshotUnavailable:
            "Не удалось безопасно сохранить текущий буфер обмена."
        case .clipboardChanged:
            "Буфер обмена изменился во время чтения. Повторите жест."
        case .clipboardRestoreFailed:
            "Не удалось восстановить прежний буфер обмена."
        case .rightOptionStillPressed:
            "Отпустите правую Option и повторите жест."
        case .requestInProgress:
            "Whisper уже получает выделенный текст."
        case .noSelection:
            "Сначала выделите текст, затем нажмите правую Option."
        }
    }
}

private enum AccessibilitySelectionProbeResult: Sendable {
    case selected(String)
    case secureTextField
    case unavailable
    case timedOut
    case cancelled
}

/// Resolves a background Accessibility request exactly once. `NSLock`
/// protects every mutable field, including the hand-off of the continuation,
/// so the unchecked conformance does not expose unsynchronised state.
private final class AccessibilityProbeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:
        CheckedContinuation<AccessibilitySelectionProbeResult, Never>?
    private var bufferedResult: AccessibilitySelectionProbeResult?
    private var isResolved = false

    func install(
        _ continuation:
            CheckedContinuation<AccessibilitySelectionProbeResult, Never>
    ) {
        let resultToResume: AccessibilitySelectionProbeResult?

        lock.lock()
        if isResolved {
            resultToResume = bufferedResult
            bufferedResult = nil
        } else {
            self.continuation = continuation
            resultToResume = nil
        }
        lock.unlock()

        if let resultToResume {
            continuation.resume(returning: resultToResume)
        }
    }

    func resolve(_ result: AccessibilitySelectionProbeResult) {
        let continuationToResume:
            CheckedContinuation<AccessibilitySelectionProbeResult, Never>?

        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        continuationToResume = continuation
        continuation = nil
        if continuationToResume == nil {
            bufferedResult = result
        }
        lock.unlock()

        continuationToResume?.resume(returning: result)
    }
}

/// Keeps synchronous Accessibility IPC away from the main actor. Some apps
/// ignore AX messaging timeouts transiently, so callers also get a hard
/// asynchronous deadline; a tardy worker can finish without delaying input.
private final class AccessibilitySelectionProbeExecutor: Sendable {
    static let shared = AccessibilitySelectionProbeExecutor()

    private static let maximumAncestorDepth = 4
    private static let workerBudgetNanoseconds: UInt64 = 520_000_000
    private static let callerDeadlineNanoseconds: UInt64 = 580_000_000
    private static let messagingTimeoutSeconds: Float = 0.11
    private static let retryDelaySeconds = 0.008

    private let queue = DispatchQueue(
        label: "com.whisper.selection-accessibility",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let deadlineQueue = DispatchQueue(
        label: "com.whisper.selection-accessibility-deadline",
        qos: .userInteractive
    )

    func selection(
        for processIdentifier: pid_t
    ) async throws -> AccessibilitySelectionProbeResult {
        try Task.checkCancellation()

        let completion = AccessibilityProbeCompletion()
        let workerDeadline = DispatchTime.now().uptimeNanoseconds
            + Self.workerBudgetNanoseconds

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                completion.install(continuation)

                queue.async {
                    completion.resolve(
                        Self.probe(
                            processIdentifier: processIdentifier,
                            deadline: workerDeadline
                        )
                    )
                }

                // Keep the hard deadline independent from AX workers. A
                // misbehaving target must not starve its own timeout callback.
                deadlineQueue.asyncAfter(
                    deadline: .now()
                        + .nanoseconds(
                            Int(Self.callerDeadlineNanoseconds)
                        )
                ) {
                    completion.resolve(.timedOut)
                }
            }
        } onCancel: {
            completion.resolve(.cancelled)
        }

        if case .cancelled = result {
            throw CancellationError()
        }
        try Task.checkCancellation()
        return result
    }

    private static func probe(
        processIdentifier: pid_t,
        deadline: UInt64
    ) -> AccessibilitySelectionProbeResult {
        guard !hasExpired(deadline) else {
            return .timedOut
        }

        guard let focusedElement = focusedElement(
            for: processIdentifier,
            deadline: deadline
        ) else {
            return hasExpired(deadline) ? .timedOut : .unavailable
        }

        var current: AXUIElement? = focusedElement
        var visited: [AXUIElement] = []
        var selectedText: String?

        for _ in 0...maximumAncestorDepth {
            guard let element = current else {
                break
            }
            guard !hasExpired(deadline) else {
                return selectedText.map(Self.selectedResult) ?? .timedOut
            }

            visited.append(element)

            if stringAttribute(
                kAXSubroleAttribute,
                from: element,
                deadline: deadline
            ) == (kAXSecureTextFieldSubrole as String) {
                return .secureTextField
            }

            if selectedText == nil,
               let candidate = stringAttribute(
                   kAXSelectedTextAttribute,
                   from: element,
                   deadline: deadline
               ),
               !candidate.trimmingCharacters(
                   in: .whitespacesAndNewlines
               ).isEmpty {
                selectedText = candidate
            }

            guard !hasExpired(deadline),
                  let parent = elementAttribute(
                      kAXParentAttribute,
                      from: element,
                      deadline: deadline
                  ),
                  !visited.contains(where: { CFEqual($0, parent) }) else {
                break
            }
            current = parent
        }

        return selectedText.map(Self.selectedResult) ?? (
            hasExpired(deadline) ? .timedOut : .unavailable
        )
    }

    private static func focusedElement(
        for processIdentifier: pid_t,
        deadline: UInt64
    ) -> AXUIElement? {
        let application = AXUIElementCreateApplication(processIdentifier)
        configureMessagingTimeout(for: application)
        if let focused = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: application,
            deadline: deadline
        ) {
            return focused
        }

        guard !hasExpired(deadline) else {
            return nil
        }

        // Some cross-platform applications expose focus only through the
        // system-wide element even though their own AX app does not.
        let system = AXUIElementCreateSystemWide()
        configureMessagingTimeout(for: system)
        guard let focused = elementAttribute(
            kAXFocusedUIElementAttribute,
            from: system,
            deadline: deadline
        ) else {
            return nil
        }

        var ownerPID: pid_t = 0
        guard AXUIElementGetPid(focused, &ownerPID) == .success,
              ownerPID == processIdentifier else {
            return nil
        }
        return focused
    }

    private static func selectedResult(
        _ text: String
    ) -> AccessibilitySelectionProbeResult {
        .selected(text)
    }

    private static func elementAttribute(
        _ attribute: String,
        from element: AXUIElement,
        deadline: UInt64
    ) -> AXUIElement? {
        guard let value = attributeValue(
            attribute,
            from: element,
            deadline: deadline
        ),
            CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        let result = unsafeBitCast(value, to: AXUIElement.self)
        configureMessagingTimeout(for: result)
        return result
    }

    private static func stringAttribute(
        _ attribute: String,
        from element: AXUIElement,
        deadline: UInt64
    ) -> String? {
        attributeValue(
            attribute,
            from: element,
            deadline: deadline
        ) as? String
    }

    private static func attributeValue(
        _ attribute: String,
        from element: AXUIElement,
        deadline: UInt64
    ) -> CFTypeRef? {
        for attempt in 0..<2 {
            guard !hasExpired(deadline) else {
                return nil
            }

            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(
                element,
                attribute as CFString,
                &value
            )
            if result == .success {
                return value
            }
            guard result == .cannotComplete,
                  attempt == 0,
                  !hasExpired(deadline) else {
                return nil
            }
            Thread.sleep(forTimeInterval: retryDelaySeconds)
        }
        return nil
    }

    private static func configureMessagingTimeout(
        for element: AXUIElement
    ) {
        AXUIElementSetMessagingTimeout(
            element,
            messagingTimeoutSeconds
        )
    }

    private static func hasExpired(_ deadline: UInt64) -> Bool {
        DispatchTime.now().uptimeNanoseconds >= deadline
    }
}

/// Reads the current selection from the application captured when the reading
/// gesture completes.
///
/// Accessibility is the first and privacy-preserving path. Applications that
/// do not expose `AXSelectedText` receive a targeted Command-C event. The
/// fallback accepts only a fresh pasteboard generation and restores a deep
/// snapshot only while that generation still owns the pasteboard.
@MainActor
final class SelectedTextService {
    private struct PasteboardSnapshot: Sendable {
        struct Entry: Sendable {
            let type: String
            let data: Data
        }

        let changeCount: Int
        let items: [[Entry]]
    }

    private struct FreshPasteboardValue: Sendable {
        let changeCount: Int
        let text: String?
    }

    private static let rightOptionKeyCode: CGKeyCode = 61
    private static let copyKeyCode: CGKeyCode = 8
    private static let optionReleaseWaitNanoseconds: UInt64 = 1_250_000_000
    private static let pasteboardWaitNanoseconds: UInt64 = 650_000_000
    private static let pollNanoseconds: UInt64 = 12_000_000
    private static let stabilizationNanoseconds: UInt64 = 18_000_000

    private var requestInProgress = false

    func captureTarget() throws -> SelectedTextTarget {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier > 0,
              application.processIdentifier
                != ProcessInfo.processInfo.processIdentifier,
              let bundleIdentifier = application.bundleIdentifier,
              !bundleIdentifier.isEmpty else {
            throw SelectedTextError.targetUnavailable
        }

        return SelectedTextTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: bundleIdentifier,
            localizedName: application.localizedName
        )
    }

    func readSelection(from target: SelectedTextTarget) async throws -> String {
        guard !requestInProgress else {
            throw SelectedTextError.requestInProgress
        }
        requestInProgress = true
        defer { requestInProgress = false }

        try Task.checkCancellation()
        try validate(target, requireFrontmost: true)

        guard AXIsProcessTrusted() else {
            throw SelectedTextError.accessibilityRequired
        }

        let accessibilityResult = try await AccessibilitySelectionProbeExecutor
            .shared.selection(for: target.processIdentifier)
        switch accessibilityResult {
        case let .selected(text):
            try Task.checkCancellation()
            try validate(target, requireFrontmost: true)
            return text
        case .secureTextField:
            throw SelectedTextError.secureTextField
        case .unavailable, .timedOut:
            break
        case .cancelled:
            throw CancellationError()
        }

        return try await selectionUsingTargetedCopy(from: target)
    }

    private func validate(
        _ target: SelectedTextTarget,
        requireFrontmost: Bool
    ) throws {
        guard target.processIdentifier > 0,
              let runningApplication = NSRunningApplication(
                  processIdentifier: target.processIdentifier
              ),
              !runningApplication.isTerminated else {
            throw SelectedTextError.targetUnavailable
        }
        guard runningApplication.bundleIdentifier == target.bundleIdentifier else {
            throw SelectedTextError.targetIdentityChanged
        }
        if requireFrontmost {
            guard NSWorkspace.shared.frontmostApplication?
                .processIdentifier == target.processIdentifier else {
                throw SelectedTextError.targetNoLongerFrontmost
            }
        }
    }

    private func selectionUsingTargetedCopy(
        from target: SelectedTextTarget
    ) async throws -> String {
        try await waitBrieflyForRightOptionRelease()
        try Task.checkCancellation()
        try validate(target, requireFrontmost: true)

        let pasteboard = NSPasteboard.general
        let snapshot = try stableSnapshot(of: pasteboard)
        guard pasteboard.changeCount == snapshot.changeCount else {
            throw SelectedTextError.clipboardChanged
        }

        try postCopy(to: target.processIdentifier)

        guard let freshValue = try await waitForFreshPasteboardValue(
            pasteboard,
            after: snapshot.changeCount
        ) else {
            try Task.checkCancellation()
            throw SelectedTextError.noSelection
        }

        guard pasteboard.changeCount == freshValue.changeCount else {
            // A clipboard manager or another application wrote after the
            // targeted copy. Never overwrite that newer value.
            throw SelectedTextError.clipboardChanged
        }

        guard restore(snapshot, to: pasteboard) else {
            throw SelectedTextError.clipboardRestoreFailed
        }

        try Task.checkCancellation()
        try validate(target, requireFrontmost: true)
        guard let text = freshValue.text,
              !text.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            throw SelectedTextError.noSelection
        }
        return text
    }

    private func waitBrieflyForRightOptionRelease() async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + Self.optionReleaseWaitNanoseconds
        while CGEventSource.keyState(
            .combinedSessionState,
            key: Self.rightOptionKeyCode
        ),
            DispatchTime.now().uptimeNanoseconds < deadline {
            try Task.checkCancellation()
            try await Task.sleep(nanoseconds: Self.pollNanoseconds)
        }
        guard !CGEventSource.keyState(
            .combinedSessionState,
            key: Self.rightOptionKeyCode
        ) else {
            throw SelectedTextError.rightOptionStillPressed
        }
    }

    private func postCopy(to processIdentifier: pid_t) throws {
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: Self.copyKeyCode,
                  keyDown: true
              ),
              let keyUp = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: Self.copyKeyCode,
                  keyDown: false
              ) else {
            throw SelectedTextError.copyUnavailable
        }

        // Do not inherit the still-physical right Option modifier from the
        // gesture. Both events intentionally carry Command and nothing else.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
    }

    private func waitForFreshPasteboardValue(
        _ pasteboard: NSPasteboard,
        after originalChangeCount: Int
    ) async throws -> FreshPasteboardValue? {
        let deadline = DispatchTime.now().uptimeNanoseconds
            + Self.pasteboardWaitNanoseconds
        var observedChangeCount: Int?

        while DispatchTime.now().uptimeNanoseconds < deadline {
            let changeCount = pasteboard.changeCount
            if changeCount != originalChangeCount {
                if let observedChangeCount,
                   observedChangeCount != changeCount {
                    // More than one pasteboard generation cannot be
                    // unambiguously attributed to our one targeted copy.
                    throw SelectedTextError.clipboardChanged
                }
                observedChangeCount = changeCount
                let firstText = pasteboard.string(forType: .string)

                // Give applications that publish multiple flavors in quick
                // succession a chance to finish, then attribute only the
                // stable generation we actually inspected.
                await nonCancellableDelay(
                    nanoseconds: Self.stabilizationNanoseconds
                )
                guard pasteboard.changeCount == changeCount else {
                    throw SelectedTextError.clipboardChanged
                }
                if let text = pasteboard.string(forType: .string) ?? firstText,
                   !text.isEmpty {
                    return FreshPasteboardValue(
                        changeCount: changeCount,
                        text: text
                    )
                }
            }
            await nonCancellableDelay(nanoseconds: Self.pollNanoseconds)
        }
        if let observedChangeCount,
           pasteboard.changeCount == observedChangeCount {
            return FreshPasteboardValue(
                changeCount: observedChangeCount,
                text: pasteboard.string(forType: .string)
            )
        }
        return nil
    }

    private func nonCancellableDelay(nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(
                deadline: .now()
                    + .nanoseconds(Int(min(nanoseconds, UInt64(Int.max))))
            ) {
                continuation.resume()
            }
        }
    }

    private func stableSnapshot(
        of pasteboard: NSPasteboard
    ) throws -> PasteboardSnapshot {
        for _ in 0..<2 {
            let changeCount = pasteboard.changeCount
            var couldSnapshotEveryType = true
            let items = (pasteboard.pasteboardItems ?? []).map { item in
                item.types.compactMap {
                    type -> PasteboardSnapshot.Entry? in
                    guard let data = item.data(forType: type) else {
                        couldSnapshotEveryType = false
                        return nil
                    }
                    return PasteboardSnapshot.Entry(
                        type: type.rawValue,
                        data: Data(data)
                    )
                }
            }
            if pasteboard.changeCount == changeCount,
               couldSnapshotEveryType {
                return PasteboardSnapshot(
                    changeCount: changeCount,
                    items: items
                )
            }
        }
        throw SelectedTextError.clipboardSnapshotUnavailable
    }

    private func restore(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard
    ) -> Bool {
        pasteboard.clearContents()
        guard !snapshot.items.isEmpty else {
            return true
        }

        let items = snapshot.items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(
                    entry.data,
                    forType: NSPasteboard.PasteboardType(entry.type)
                )
            }
            return item
        }
        return pasteboard.writeObjects(items)
    }
}
