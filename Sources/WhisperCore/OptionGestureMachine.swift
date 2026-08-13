import Foundation

/// The two physical modifier keys assigned to Whisper gestures.
///
/// The legacy `left`/`right` case names describe the two gesture channels:
/// left Shift starts dictation, while right Option reads selected text.
public enum OptionKey: Int, CaseIterable, Hashable, Sendable {
    case left = 56
    case right = 61
}

/// Timing thresholds for the tap-then-hold dictation gesture.
public struct GestureConfiguration: Equatable, Sendable {
    /// Faster activation for voice dictation through left Shift.
    public static let dictation = GestureConfiguration(holdDuration: 1.0)

    /// Reading keeps the longer hold to avoid accidental playback.
    public static let reading = GestureConfiguration(holdDuration: 1.5)

    public var tapMaximum: TimeInterval
    public var secondPressWindow: TimeInterval
    public var holdDuration: TimeInterval

    public init(
        tapMaximum: TimeInterval = 0.35,
        secondPressWindow: TimeInterval = 2.0,
        holdDuration: TimeInterval = 1.5
    ) {
        self.tapMaximum = tapMaximum
        self.secondPressWindow = secondPressWindow
        self.holdDuration = holdDuration
    }
}

/// Input understood by ``OptionGestureMachine``. The `optionDown` and
/// `optionUp` names are retained for source compatibility; events may represent
/// either the left-Shift dictation channel or right-Option reading channel.
///
/// Time is deliberately supplied to `handle(_:at:)` instead of read from a
/// clock, which keeps the reducer deterministic and straightforward to test.
public enum GestureEvent: Equatable, Sendable {
    case optionDown(OptionKey, clean: Bool)
    case optionUp(OptionKey)
    case otherKeyDown
    case tick
    case reset
}

/// Effects produced by ``OptionGestureMachine`` for its caller to perform.
public enum GestureAction: Equatable, Sendable {
    case armed
    case holding(progress: Double)
    case cancelled
    case startRecording
    case stopRecording
}

/// A presentation-friendly view of the gesture recognizer's current state.
public enum OptionGesturePhase: Equatable, Sendable {
    case idle
    case firstPress
    case armed
    case holding(progress: Double)
    case recording
}

/// Recognizes a quick modifier-key tap followed by a sustained press.
///
/// This type has no timer or event-tap dependency. The owner forwards keyboard
/// events and periodic ticks using a monotonic timestamp, then performs the
/// returned actions. A single machine should be kept for the lifetime of the
/// keyboard monitor.
public struct OptionGestureMachine: Sendable {
    public typealias Phase = OptionGesturePhase

    public let configuration: GestureConfiguration
    public private(set) var phase: Phase = .idle

    private enum State: Sendable {
        case idle
        case firstPress(key: OptionKey, pressedAt: TimeInterval)
        case armed(at: TimeInterval)
        case holding(key: OptionKey, pressedAt: TimeInterval, progress: Double)
        case recording
    }

    private var state: State = .idle
    private var pressedGestureKeys: Set<OptionKey> = []
    private var lastTimestamp: TimeInterval?

    public init(configuration: GestureConfiguration = GestureConfiguration()) {
        self.configuration = configuration
    }

    /// Reduces one keyboard/timer event into zero or more caller-owned effects.
    ///
    /// Timestamps must use one monotonic time base. Events older than the last
    /// accepted event, duplicate key transitions, and unmatched releases are
    /// ignored so delayed event-tap delivery cannot corrupt the state machine.
    @discardableResult
    public mutating func handle(
        _ event: GestureEvent,
        at timestamp: TimeInterval
    ) -> [GestureAction] {
        if case .reset = event {
            reset(at: timestamp)
            return []
        }

        guard timestamp.isFinite else { return [] }
        if let lastTimestamp, timestamp < lastTimestamp {
            if case let .optionUp(key) = event,
               case let .holding(activeKey, _, _) = state,
               activeKey == key,
               pressedGestureKeys.remove(key) != nil {
                var actions: [GestureAction] = []
                cancelPendingGesture(into: &actions)
                return actions
            }
            return []
        }
        lastTimestamp = timestamp

        let reportsProgress = event == .tick
        var actions = advance(to: timestamp, reportsProgress: reportsProgress)

        switch event {
        case let .optionDown(key, clean):
            guard !pressedGestureKeys.contains(key) else {
                return actions
            }

            let isOnlyGestureKey = pressedGestureKeys.isEmpty
            pressedGestureKeys.insert(key)
            let isCleanPress = clean && isOnlyGestureKey

            switch state {
            case .idle:
                if isCleanPress {
                    transition(to: .firstPress(key: key, pressedAt: timestamp))
                }

            case .firstPress, .holding:
                cancelPendingGesture(into: &actions)

            case let .armed(armedAt):
                if isCleanPress,
                   elapsed(from: armedAt, to: timestamp) <= validSecondPressWindow {
                    transition(to: .holding(key: key, pressedAt: timestamp, progress: 0))
                    actions.append(.holding(progress: 0))
                    actions.append(contentsOf: advance(to: timestamp, reportsProgress: false))
                } else {
                    cancelPendingGesture(into: &actions)
                }

            case .recording:
                if isCleanPress {
                    transition(to: .idle)
                    actions.append(.stopRecording)
                }
            }

        case let .optionUp(key):
            guard pressedGestureKeys.remove(key) != nil else {
                return actions
            }

            switch state {
            case let .firstPress(activeKey, pressedAt) where activeKey == key:
                if elapsed(from: pressedAt, to: timestamp) <= validTapMaximum {
                    transition(to: .armed(at: timestamp))
                    actions.append(.armed)
                } else {
                    cancelPendingGesture(into: &actions)
                }

            case let .holding(activeKey, _, _) where activeKey == key:
                // `advance` runs before the release. If the threshold was met,
                // state is already `.recording`, and release intentionally does
                // nothing. Otherwise this was an early release.
                cancelPendingGesture(into: &actions)

            default:
                break
            }

        case .otherKeyDown:
            switch state {
            case .firstPress, .armed, .holding:
                cancelPendingGesture(into: &actions)
            case .idle, .recording:
                break
            }

        case .tick:
            break

        case .reset:
            // Handled before timestamp validation so reset is always reliable.
            break
        }

        return actions
    }

    private var validTapMaximum: TimeInterval {
        max(0, configuration.tapMaximum)
    }

    private var validSecondPressWindow: TimeInterval {
        max(0, configuration.secondPressWindow)
    }

    private var validHoldDuration: TimeInterval {
        max(0, configuration.holdDuration)
    }

    private func elapsed(from start: TimeInterval, to end: TimeInterval) -> TimeInterval {
        max(0, end - start)
    }

    private mutating func advance(
        to timestamp: TimeInterval,
        reportsProgress: Bool
    ) -> [GestureAction] {
        switch state {
        case let .firstPress(_, pressedAt):
            guard elapsed(from: pressedAt, to: timestamp) > validTapMaximum else {
                return []
            }
            transition(to: .idle)
            return [.cancelled]

        case let .armed(armedAt):
            guard elapsed(from: armedAt, to: timestamp) > validSecondPressWindow else {
                return []
            }
            transition(to: .idle)
            return [.cancelled]

        case let .holding(key, pressedAt, previousProgress):
            let duration = validHoldDuration
            let progress = duration == 0
                ? 1
                : min(1, elapsed(from: pressedAt, to: timestamp) / duration)

            if progress >= 1 {
                transition(to: .recording)
                return [.holding(progress: 1), .startRecording]
            }

            transition(to: .holding(key: key, pressedAt: pressedAt, progress: progress))
            if reportsProgress, progress > previousProgress {
                return [.holding(progress: progress)]
            }
            return []

        case .idle, .recording:
            return []
        }
    }

    private mutating func cancelPendingGesture(into actions: inout [GestureAction]) {
        switch state {
        case .firstPress, .armed, .holding:
            transition(to: .idle)
            actions.append(.cancelled)
        case .idle, .recording:
            break
        }
    }

    private mutating func transition(to newState: State) {
        state = newState
        switch newState {
        case .idle:
            phase = .idle
        case .firstPress:
            phase = .firstPress
        case .armed:
            phase = .armed
        case let .holding(_, _, progress):
            phase = .holding(progress: progress)
        case .recording:
            phase = .recording
        }
    }

    private mutating func reset(at timestamp: TimeInterval) {
        state = .idle
        phase = .idle
        pressedGestureKeys.removeAll(keepingCapacity: true)
        lastTimestamp = timestamp.isFinite ? timestamp : nil
    }
}
