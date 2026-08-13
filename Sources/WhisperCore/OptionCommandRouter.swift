import Foundation

/// Commands produced after assigning left Shift and right Option distinct roles.
public enum OptionCommand: Equatable, Sendable {
    case dictation(GestureAction)
    case readingArmed
    case readingHolding(progress: Double)
    case readingCancelled
    case readSelection
}

/// Routes two independent tap-then-hold gestures.
///
/// Left Shift owns the faster dictation gesture handled by
/// ``OptionGestureMachine``. Right Option keeps a longer hold, and only a quick
/// right-Option tap followed by a clean, sustained right-Option press may read
/// selected text. Events from one physical key are never allowed to complete
/// the other key's gesture.
public struct OptionCommandRouter: Sendable {
    public var dictationPhase: OptionGesturePhase {
        dictationMachine.phase
    }

    public var readingGesturePhase: OptionGesturePhase {
        readingMachine.phase
    }

    private var dictationMachine: OptionGestureMachine
    private var readingMachine: OptionGestureMachine
    private var rightOptionIsDown = false
    private var lastRightOptionTimestamp: TimeInterval?

    public init(
        dictationConfiguration: GestureConfiguration = .dictation,
        readingConfiguration: GestureConfiguration = .reading
    ) {
        dictationMachine = OptionGestureMachine(
            configuration: dictationConfiguration
        )
        readingMachine = OptionGestureMachine(
            configuration: readingConfiguration
        )
    }

    /// Preserves the existing single-configuration API for callers that
    /// intentionally want identical timing for both gestures.
    public init(configuration: GestureConfiguration) {
        self.init(
            dictationConfiguration: configuration,
            readingConfiguration: configuration
        )
    }

    /// Reduces one monitor or timer event into app-level commands.
    ///
    /// A reset is accepted regardless of timestamp. Chords, cross-key
    /// sequences, and interrupted holds cancel pending presentation state.
    /// Right Option is never forwarded to the dictation machine, so it cannot
    /// stop an active recording.
    @discardableResult
    public mutating func handle(
        _ event: GestureEvent,
        at timestamp: TimeInterval
    ) -> [OptionCommand] {
        if case .reset = event {
            return reset(at: timestamp)
        }

        guard timestamp.isFinite else {
            if case .optionUp(.right) = event {
                return cancelReading(clearPhysicalState: true, at: timestamp)
            }
            return []
        }

        switch event {
        case let .optionDown(.left, clean):
            let readingWasPending = isReadingPending
            let rightWasDown = rightOptionIsDown
            let readingCancellation = cancelReading(
                clearPhysicalState: false,
                at: timestamp
            )

            // A left press cannot double as the first dictation press when it
            // interrupted an armed/holding right gesture.
            guard !readingWasPending else {
                return readingCancellation
            }

            return readingCancellation + dictationCommands(
                for: .optionDown(.left, clean: clean && !rightWasDown),
                at: timestamp
            )

        case .optionUp(.left):
            return dictationCommands(for: .optionUp(.left), at: timestamp)

        case let .optionDown(.right, clean):
            guard acceptsRightTransition(at: timestamp) else {
                return []
            }
            guard !rightOptionIsDown else {
                return []
            }

            rightOptionIsDown = true

            let dictationWasPending = isDictationPending
            let dictationCancellations = cancelPendingDictation(at: timestamp)

            // Cross-key sequences and right Option during recording fail
            // closed. Its matching release will be consumed harmlessly.
            guard !dictationWasPending, dictationMachine.phase != .recording else {
                _ = readingMachine.handle(.reset, at: timestamp)
                return dictationCancellations
            }

            return dictationCancellations + readingCommands(
                for: .optionDown(.right, clean: clean),
                at: timestamp
            )

        case .optionUp(.right):
            guard acceptsRightTransition(at: timestamp) else {
                return cancelReading(clearPhysicalState: true, at: timestamp)
            }
            guard rightOptionIsDown else {
                return []
            }

            rightOptionIsDown = false
            return readingCommands(for: .optionUp(.right), at: timestamp)

        case .otherKeyDown:
            let readingCancellation = cancelReading(
                clearPhysicalState: false,
                at: timestamp
            )
            return readingCancellation + cancelPendingDictation(at: timestamp)

        case .tick:
            return dictationCommands(for: .tick, at: timestamp)
                + readingCommands(for: .tick, at: timestamp)

        case .reset:
            // Handled before timestamp validation.
            return []
        }
    }

    private var isDictationPending: Bool {
        switch dictationMachine.phase {
        case .firstPress, .armed, .holding:
            true
        case .idle, .recording:
            false
        }
    }

    private var isReadingPending: Bool {
        switch readingMachine.phase {
        case .firstPress, .armed, .holding:
            true
        case .idle, .recording:
            false
        }
    }

    private var hasPresentedReadingGesture: Bool {
        switch readingMachine.phase {
        case .armed, .holding:
            true
        case .idle, .firstPress, .recording:
            false
        }
    }

    private mutating func acceptsRightTransition(at timestamp: TimeInterval) -> Bool {
        if let lastRightOptionTimestamp, timestamp < lastRightOptionTimestamp {
            return false
        }
        lastRightOptionTimestamp = timestamp
        return true
    }

    private mutating func cancelPendingDictation(
        at timestamp: TimeInterval
    ) -> [OptionCommand] {
        guard isDictationPending else {
            return []
        }
        _ = dictationMachine.handle(.reset, at: timestamp)
        return [.dictation(.cancelled)]
    }

    private mutating func dictationCommands(
        for event: GestureEvent,
        at timestamp: TimeInterval
    ) -> [OptionCommand] {
        dictationMachine.handle(event, at: timestamp).map(OptionCommand.dictation)
    }

    private mutating func readingCommands(
        for event: GestureEvent,
        at timestamp: TimeInterval
    ) -> [OptionCommand] {
        let wasPresented = hasPresentedReadingGesture
        let actions = readingMachine.handle(event, at: timestamp)
        var commands: [OptionCommand] = []

        for action in actions {
            switch action {
            case .armed:
                commands.append(.readingArmed)
            case let .holding(progress):
                commands.append(.readingHolding(progress: progress))
            case .cancelled:
                if wasPresented {
                    commands.append(.readingCancelled)
                }
            case .startRecording:
                commands.append(.readSelection)
                // Reading is a one-shot command, not a persistent gesture
                // machine recording state. Keep the physical-key bit until
                // release so cross-key input still fails closed.
                _ = readingMachine.handle(.reset, at: timestamp)
            case .stopRecording:
                // The reading machine is reset as soon as it emits the
                // one-shot read command, so this action is unreachable.
                break
            }
        }

        return commands
    }

    private mutating func cancelReading(
        clearPhysicalState: Bool,
        at timestamp: TimeInterval
    ) -> [OptionCommand] {
        let shouldNotify = hasPresentedReadingGesture
        _ = readingMachine.handle(.reset, at: timestamp)
        if clearPhysicalState {
            rightOptionIsDown = false
        }
        return shouldNotify ? [.readingCancelled] : []
    }

    private mutating func reset(at timestamp: TimeInterval) -> [OptionCommand] {
        let readingCancellation = hasPresentedReadingGesture
            ? [OptionCommand.readingCancelled]
            : []
        _ = dictationMachine.handle(.reset, at: timestamp)
        _ = readingMachine.handle(.reset, at: timestamp)
        rightOptionIsDown = false
        lastRightOptionTimestamp = nil
        return readingCancellation
    }
}
