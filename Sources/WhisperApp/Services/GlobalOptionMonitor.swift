import CoreGraphics
import Foundation
import WhisperCore

public enum GlobalOptionMonitorError: LocalizedError, Sendable {
    case alreadyRunning
    case inputMonitoringMayBeRequired
    case unableToCreateEventTap
    case unableToCreateRunLoopSource
    case unableToReenableEventTap

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "Глобальные горячие клавиши Option уже запущены."
        case .inputMonitoringMayBeRequired:
            "macOS отклонила глобальную горячую клавишу. Разрешите Whisper Мониторинг ввода в Системных настройках и перезапустите приложение."
        case .unableToCreateEventTap:
            "Не удалось запустить глобальные горячие клавиши. Проверьте Whisper в Системных настройках → Конфиденциальность и безопасность → Универсальный доступ, затем перезапустите приложение."
        case .unableToCreateRunLoopSource:
            "Не удалось подключить монитор клавиатуры. Перезапустите Whisper."
        case .unableToReenableEventTap:
            "macOS отключила глобальные горячие клавиши. Проверьте разрешения Whisper и перезапустите приложение."
        }
    }
}

public struct ObservedGestureEvent: Equatable, Sendable {
    public let event: GestureEvent
    public let timestamp: TimeInterval

    public init(event: GestureEvent, timestamp: TimeInterval) {
        self.event = event
        self.timestamp = timestamp
    }
}

/// Observes physical Option keys with a listen-only event tap and never suppresses input.
public final class GlobalOptionMonitor {
    public typealias Handler = (ObservedGestureEvent) -> Void
    public typealias FailureHandler = (GlobalOptionMonitorError) -> Void

    private let stateLock = NSLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var handler: Handler?
    private var failureHandler: FailureHandler?
    private var optionTracker = OptionTransitionTracker()
    private var isRecoveringDisabledTap = false

    public init() {}

    deinit {
        stop()
    }

    public var isRunning: Bool {
        stateLock.withLock {
            guard let eventTap else { return false }
            return CFMachPortIsValid(eventTap)
                && CGEvent.tapIsEnabled(tap: eventTap)
        }
    }

    /// Starts delivery on the main run loop. The tap is listen-only by construction.
    public func start(
        handler: @escaping Handler,
        onFailure: @escaping FailureHandler = { _ in }
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard eventTap == nil else {
            throw GlobalOptionMonitorError.alreadyRunning
        }

        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
            | CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            if !CGPreflightListenEventAccess() {
                throw GlobalOptionMonitorError.inputMonitoringMayBeRequired
            }
            throw GlobalOptionMonitorError.unableToCreateEventTap
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw GlobalOptionMonitorError.unableToCreateRunLoopSource
        }

        self.handler = handler
        failureHandler = onFailure
        eventTap = tap
        runLoopSource = source
        optionTracker.reset()
        isRecoveringDisabledTap = false
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        guard CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) else {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            CFMachPortInvalidate(tap)
            self.handler = nil
            failureHandler = nil
            eventTap = nil
            runLoopSource = nil
            throw GlobalOptionMonitorError.unableToCreateEventTap
        }
    }

    /// Stops monitoring and releases the event tap.
    public func stop() {
        let resources: (tap: CFMachPort?, source: CFRunLoopSource?) = stateLock.withLock {
            let resources = (eventTap, runLoopSource)
            eventTap = nil
            runLoopSource = nil
            handler = nil
            failureHandler = nil
            optionTracker.reset()
            isRecoveringDisabledTap = false
            return resources
        }

        if let source = resources.source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = resources.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
    }

    private static let eventTapCallback: CGEventTapCallBack = {
        _, type, event, userInfo in
        guard let userInfo else {
            return Unmanaged.passUnretained(event)
        }
        let monitor = Unmanaged<GlobalOptionMonitor>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        monitor.receive(type: type, event: event)
        return Unmanaged.passUnretained(event)
    }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let result: (CFMachPort?, Handler?, FailureHandler?, Bool) = stateLock.withLock {
                let wasAlreadyRecovering = isRecoveringDisabledTap
                isRecoveringDisabledTap = true
                optionTracker.reset()
                return (eventTap, handler, failureHandler, wasAlreadyRecovering)
            }
            guard let tap = result.0 else { return }

            if result.3 {
                stop()
                result.2?(.unableToReenableEventTap)
                return
            }

            CGEvent.tapEnable(tap: tap, enable: true)
            guard CFMachPortIsValid(tap), CGEvent.tapIsEnabled(tap: tap) else {
                stop()
                result.2?(.unableToReenableEventTap)
                return
            }
            deliver(.reset, from: event, to: result.1)
            return
        }

        stateLock.withLock {
            isRecoveringDisabledTap = false
        }

        switch type {
        case .flagsChanged:
            receiveFlagsChanged(event)
        case .keyDown:
            receiveKeyDown(event)
        default:
            break
        }
    }

    private func receiveFlagsChanged(_ event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard let optionKey = OptionKey(rawValue: keyCode) else {
            deliver(.otherKeyDown, from: event)
            return
        }

        let output: GestureEvent? = stateLock.withLock {
            return optionTracker.transition(
                for: optionKey,
                pressedInEvent: Self.pressedOptions(in: event.flags),
                clean: isCleanOptionPress(event.flags)
            )
        }
        if let output {
            deliver(output, from: event)
        }
    }

    private func receiveKeyDown(_ event: CGEvent) {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard OptionKey(rawValue: keyCode) == nil else { return }
        deliver(.otherKeyDown, from: event)
    }

    private func currentHandler() -> Handler? {
        stateLock.withLock { handler }
    }

    private func deliver(
        _ event: GestureEvent,
        from sourceEvent: CGEvent,
        to explicitHandler: Handler? = nil
    ) {
        let nanoseconds = sourceEvent.timestamp
        let timestamp = nanoseconds > 0
            ? TimeInterval(nanoseconds) / 1_000_000_000
            : ProcessInfo.processInfo.systemUptime
        (explicitHandler ?? currentHandler())?(
            ObservedGestureEvent(event: event, timestamp: timestamp)
        )
    }

    private func isCleanOptionPress(_ flags: CGEventFlags) -> Bool {
        let relevant: CGEventFlags = [
            .maskShift,
            .maskControl,
            .maskAlternate,
            .maskCommand,
            .maskSecondaryFn,
        ]
        return flags.intersection(relevant).subtracting(.maskAlternate).isEmpty
    }

    private static func pressedOptions(in flags: CGEventFlags) -> Set<OptionKey> {
        // IOLLEvent.h: NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK. Read the
        // side bits from this event rather than a second global-state snapshot.
        guard flags.contains(.maskAlternate) else { return [] }

        var pressed: Set<OptionKey> = []
        if flags.rawValue & 0x20 != 0 {
            pressed.insert(.left)
        }
        if flags.rawValue & 0x40 != 0 {
            pressed.insert(.right)
        }
        return pressed
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
