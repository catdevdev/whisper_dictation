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
            "Глобальные горячие клавиши Shift/Option уже запущены."
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

/// Observes left Shift and right Option with a listen-only event tap and never
/// suppresses input.
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

    // IOLLEvent.h device-specific modifier bits. Aggregate masks cannot tell
    // left Shift from right Shift or left Option from right Option.
    private static let leftShiftDeviceMask: UInt64 = 0x02
    private static let rightShiftDeviceMask: UInt64 = 0x04
    private static let leftOptionDeviceMask: UInt64 = 0x20
    private static let rightOptionDeviceMask: UInt64 = 0x40

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
                pressedInEvent: Self.pressedGestureKeys(in: event.flags),
                clean: Self.isCleanGesturePress(
                    for: optionKey,
                    flags: event.flags
                )
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

    static func isCleanGesturePress(
        for key: OptionKey,
        flags: CGEventFlags
    ) -> Bool {
        let relevant: CGEventFlags = [
            .maskShift,
            .maskControl,
            .maskAlternate,
            .maskCommand,
            .maskSecondaryFn,
        ]
        let allowed: CGEventFlags = key == .left ? .maskShift : .maskAlternate
        guard flags.intersection(relevant).subtracting(allowed).isEmpty else {
            return false
        }

        let rawFlags = flags.rawValue
        switch key {
        case .left:
            return rawFlags & leftShiftDeviceMask != 0
                && rawFlags & rightShiftDeviceMask == 0
        case .right:
            return rawFlags & rightOptionDeviceMask != 0
                && rawFlags & leftOptionDeviceMask == 0
        }
    }

    static func pressedGestureKeys(in flags: CGEventFlags) -> Set<OptionKey> {
        // Read side bits from this event rather than a second, potentially stale
        // global-state snapshot.
        var pressed: Set<OptionKey> = []
        if flags.rawValue & leftShiftDeviceMask != 0 {
            pressed.insert(.left)
        }
        if flags.rawValue & rightOptionDeviceMask != 0 {
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
