import XCTest
@testable import WhisperCore

final class OptionGestureMachineTests: XCTestCase {
    func testOptionTransitionTrackerUsesExplicitPhysicalState() {
        var tracker = OptionTransitionTracker()

        XCTAssertEqual(
            tracker.transition(for: .left, isPressed: true, clean: true),
            .optionDown(.left, clean: true)
        )
        XCTAssertNil(
            tracker.transition(for: .left, isPressed: true, clean: true)
        )
        XCTAssertEqual(
            tracker.transition(for: .left, isPressed: false, clean: true),
            .optionUp(.left)
        )
        XCTAssertNil(
            tracker.transition(for: .left, isPressed: false, clean: true)
        )
        XCTAssertEqual(
            tracker.transition(for: .left, isPressed: true, clean: true),
            .optionDown(.left, clean: true)
        )
    }

    func testOptionTransitionTrackerUsesInitialPhysicalSnapshot() {
        var tracker = OptionTransitionTracker(initiallyPressed: [.right])

        XCTAssertEqual(
            tracker.transition(for: .right, isPressed: false, clean: true),
            .optionUp(.right)
        )
        XCTAssertTrue(tracker.pressedKeys.isEmpty)
    }

    func testOptionTransitionTrackerNeverMarksSecondGestureKeyClean() {
        var tracker = OptionTransitionTracker()

        _ = tracker.transition(for: .left, isPressed: true, clean: true)
        XCTAssertEqual(
            tracker.transition(for: .right, isPressed: true, clean: true),
            .optionDown(.right, clean: false)
        )
        XCTAssertEqual(tracker.pressedKeys, Set([.left, .right]))
    }

    func testOptionTransitionDecoderUsesEventSnapshot() {
        var tracker = OptionTransitionTracker()

        XCTAssertEqual(
            tracker.transition(
                for: .left,
                pressedInEvent: [.left],
                clean: true
            ),
            .optionDown(.left, clean: true)
        )
        XCTAssertEqual(
            tracker.transition(
                for: .left,
                pressedInEvent: [],
                clean: true
            ),
            .optionUp(.left)
        )
    }

    func testOptionTransitionDecoderReleasesChordKeyWhileAggregateStaysSet() {
        var tracker = OptionTransitionTracker(initiallyPressed: [.left, .right])

        XCTAssertEqual(
            tracker.transition(
                for: .left,
                pressedInEvent: [.right],
                clean: false
            ),
            .optionUp(.left)
        )
        XCTAssertEqual(tracker.pressedKeys, [.right])
    }

    func testOptionTransitionDecoderResetsStaleChordOnAggregateRelease() {
        var tracker = OptionTransitionTracker(initiallyPressed: [.left, .right])

        XCTAssertEqual(
            tracker.transition(
                for: .right,
                pressedInEvent: [],
                clean: false
            ),
            .reset
        )
        XCTAssertTrue(tracker.pressedKeys.isEmpty)
    }

    func testOptionTransitionDecoderHandlesChordAndDuplicateSnapshots() {
        var tracker = OptionTransitionTracker()

        XCTAssertEqual(
            tracker.transition(for: .left, pressedInEvent: [.left], clean: true),
            .optionDown(.left, clean: true)
        )
        XCTAssertEqual(
            tracker.transition(
                for: .right,
                pressedInEvent: [.left, .right],
                clean: true
            ),
            .optionDown(.right, clean: false)
        )
        XCTAssertNil(
            tracker.transition(
                for: .right,
                pressedInEvent: [.left, .right],
                clean: true
            )
        )
        XCTAssertEqual(
            tracker.transition(for: .left, pressedInEvent: [.right], clean: false),
            .optionUp(.left)
        )
        XCTAssertEqual(
            tracker.transition(for: .right, pressedInEvent: [], clean: false),
            .optionUp(.right)
        )
        XCTAssertTrue(tracker.pressedKeys.isEmpty)
    }

    func testOptionTransitionDecoderFailsClosedAfterMissedEdge() {
        var tracker = OptionTransitionTracker()

        XCTAssertEqual(
            tracker.transition(
                for: .right,
                pressedInEvent: [.left, .right],
                clean: true
            ),
            .reset
        )
        XCTAssertEqual(tracker.pressedKeys, [.left, .right])
    }

    func testPublicDefaultsAndRawKeyCodes() {
        let configuration = GestureConfiguration()

        XCTAssertEqual(OptionKey.left.rawValue, 56)
        XCTAssertEqual(OptionKey.right.rawValue, 61)
        XCTAssertEqual(configuration.tapMaximum, 0.35)
        XCTAssertEqual(configuration.secondPressWindow, 2.0)
        XCTAssertEqual(configuration.holdDuration, 1.5)
    }

    func testQuickTapArmsAtInclusiveTapBoundary() {
        var machine = OptionGestureMachine()

        XCTAssertEqual(machine.handle(.optionDown(.left, clean: true), at: 10), [])
        XCTAssertEqual(machine.phase, .firstPress)
        XCTAssertEqual(machine.handle(.optionUp(.left), at: 10.35), [.armed])
        XCTAssertEqual(machine.phase, .armed)
    }

    func testFirstPressLongerThanTapMaximumCancelsOnce() {
        var machine = OptionGestureMachine()

        _ = machine.handle(.optionDown(.left, clean: true), at: 0)
        XCTAssertEqual(machine.handle(.tick, at: 0.350_001), [.cancelled])
        XCTAssertEqual(machine.handle(.optionUp(.left), at: 0.4), [])
        XCTAssertEqual(machine.handle(.tick, at: 1), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testSecondPressIsAcceptedAtInclusiveWindowBoundary() {
        var machine = OptionGestureMachine()
        arm(&machine, downAt: 0, upAt: 0.1, key: .left)

        XCTAssertEqual(
            machine.handle(.optionDown(.right, clean: true), at: 2.1),
            [.holding(progress: 0)]
        )
        XCTAssertEqual(machine.phase, .holding(progress: 0))
    }

    func testSecondPressPastWindowCancelsAndCanBeginANewFirstTap() {
        var machine = OptionGestureMachine()
        arm(&machine, downAt: 0, upAt: 0.1, key: .left)

        XCTAssertEqual(
            machine.handle(.optionDown(.right, clean: true), at: 2.100_001),
            [.cancelled]
        )
        XCTAssertEqual(machine.phase, .firstPress)
        XCTAssertEqual(machine.handle(.optionUp(.right), at: 2.2), [.armed])
    }

    func testArmedStateExpiresOnceWithoutSecondPress() {
        var machine = OptionGestureMachine()
        arm(&machine, downAt: 4, upAt: 4.1, key: .left)

        XCTAssertEqual(machine.handle(.tick, at: 6.1), [])
        XCTAssertEqual(machine.phase, .armed)
        XCTAssertEqual(machine.handle(.tick, at: 6.100_001), [.cancelled])
        XCTAssertEqual(machine.handle(.tick, at: 7), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testHoldReportsProgressAndStartsAtInclusiveThreshold() {
        var machine = OptionGestureMachine()
        arm(&machine, downAt: 0, upAt: 0.1, key: .left)
        XCTAssertEqual(
            machine.handle(.optionDown(.right, clean: true), at: 0.2),
            [.holding(progress: 0)]
        )

        XCTAssertEqual(machine.handle(.tick, at: 0.95), [.holding(progress: 0.5)])
        XCTAssertEqual(machine.phase, .holding(progress: 0.5))
        XCTAssertEqual(
            machine.handle(.tick, at: 1.7),
            [.holding(progress: 1), .startRecording]
        )
        XCTAssertEqual(machine.phase, .recording)
    }

    func testRepeatedTicksDoNotStartRecordingTwice() {
        var machine = OptionGestureMachine()
        startRecording(&machine, activationKey: .left)

        XCTAssertEqual(machine.handle(.tick, at: 2), [])
        XCTAssertEqual(machine.handle(.tick, at: 20), [])
        XCTAssertEqual(machine.phase, .recording)
    }

    func testEarlyActivationReleaseCancels() {
        var machine = OptionGestureMachine()
        arm(&machine, downAt: 0, upAt: 0.1, key: .left)
        _ = machine.handle(.optionDown(.right, clean: true), at: 0.2)

        XCTAssertEqual(machine.handle(.optionUp(.right), at: 1.699_999), [.cancelled])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.handle(.tick, at: 2).contains(.startRecording))
    }

    func testReleaseAtActivationThresholdStartsAndDoesNotStop() {
        var machine = OptionGestureMachine()
        arm(&machine, downAt: 0, upAt: 0.1, key: .left)
        _ = machine.handle(.optionDown(.right, clean: true), at: 0.2)

        XCTAssertEqual(
            machine.handle(.optionUp(.right), at: 1.7),
            [.holding(progress: 1), .startRecording]
        )
        XCTAssertEqual(machine.phase, .recording)
    }

    func testNextCleanOptionPressStopsOnceAndItsReleaseDoesNotArm() {
        var machine = OptionGestureMachine()
        startRecording(&machine, activationKey: .left)
        XCTAssertEqual(machine.handle(.optionUp(.left), at: 1.8), [])

        XCTAssertEqual(machine.handle(.optionDown(.right, clean: true), at: 2), [.stopRecording])
        XCTAssertEqual(machine.handle(.optionDown(.right, clean: true), at: 2.01), [])
        XCTAssertEqual(machine.handle(.optionUp(.right), at: 2.1), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testDirtyInitialPressIsIgnoredAndDirtySecondPressCancels() {
        var machine = OptionGestureMachine()

        XCTAssertEqual(machine.handle(.optionDown(.left, clean: false), at: 0), [])
        XCTAssertEqual(machine.handle(.optionUp(.left), at: 0.1), [])
        XCTAssertEqual(machine.phase, .idle)

        arm(&machine, downAt: 1, upAt: 1.1, key: .left)
        XCTAssertEqual(machine.handle(.optionDown(.right, clean: false), at: 1.2), [.cancelled])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testOrdinaryKeyCancelsEachPreActivationStage() {
        var firstPress = OptionGestureMachine()
        _ = firstPress.handle(.optionDown(.left, clean: true), at: 0)
        XCTAssertEqual(firstPress.handle(.otherKeyDown, at: 0.1), [.cancelled])

        var armed = OptionGestureMachine()
        arm(&armed, downAt: 0, upAt: 0.1, key: .left)
        XCTAssertEqual(armed.handle(.otherKeyDown, at: 0.2), [.cancelled])

        var holding = OptionGestureMachine()
        arm(&holding, downAt: 0, upAt: 0.1, key: .left)
        _ = holding.handle(.optionDown(.right, clean: true), at: 0.2)
        XCTAssertEqual(holding.handle(.otherKeyDown, at: 0.3), [.cancelled])
    }

    func testOtherKeyDoesNotStopAnActiveRecording() {
        var machine = OptionGestureMachine()
        startRecording(&machine, activationKey: .left)

        XCTAssertEqual(machine.handle(.otherKeyDown, at: 1.8), [])
        XCTAssertEqual(machine.phase, .recording)
    }

    func testOppositeOptionChordCancelsAndMismatchedReleaseIsSafe() {
        var machine = OptionGestureMachine()
        _ = machine.handle(.optionDown(.left, clean: true), at: 0)

        XCTAssertEqual(machine.handle(.optionUp(.right), at: 0.05), [])
        XCTAssertEqual(machine.phase, .firstPress)
        XCTAssertEqual(machine.handle(.optionDown(.right, clean: true), at: 0.1), [.cancelled])
        XCTAssertEqual(machine.handle(.optionUp(.right), at: 0.2), [])
        XCTAssertEqual(machine.handle(.optionUp(.left), at: 0.3), [])
        XCTAssertEqual(machine.phase, .idle)
    }

    func testDuplicateTransitionsAreIgnored() {
        var machine = OptionGestureMachine()

        XCTAssertEqual(machine.handle(.optionDown(.left, clean: true), at: 0), [])
        XCTAssertEqual(machine.handle(.optionDown(.left, clean: true), at: 0.01), [])
        XCTAssertEqual(machine.handle(.optionUp(.left), at: 0.1), [.armed])
        XCTAssertEqual(machine.handle(.optionUp(.left), at: 0.11), [])
        XCTAssertEqual(machine.phase, .armed)
    }

    func testStaleEventsCannotMutateStateOrPhysicalKeyTracking() {
        var machine = OptionGestureMachine()
        _ = machine.handle(.optionDown(.right, clean: true), at: 10)

        XCTAssertEqual(machine.handle(.optionUp(.right), at: 9), [])
        XCTAssertEqual(machine.handle(.otherKeyDown, at: 9.5), [])
        XCTAssertEqual(machine.phase, .firstPress)
        XCTAssertEqual(machine.handle(.optionUp(.right), at: 10.1), [.armed])
    }

    func testStaleMatchingReleaseCancelsHoldingForSafety() {
        var machine = OptionGestureMachine()
        arm(&machine, downAt: 30, upAt: 30.1, key: .left)
        _ = machine.handle(.optionDown(.right, clean: true), at: 30.2)
        _ = machine.handle(.tick, at: 31)

        XCTAssertEqual(machine.handle(.optionUp(.right), at: 30.9), [.cancelled])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertFalse(machine.handle(.tick, at: 32).contains(.startRecording))
    }

    func testResetAlwaysClearsStateAndAllowsFreshInput() {
        var machine = OptionGestureMachine()
        startRecording(&machine, activationKey: .left, base: 10)

        XCTAssertEqual(machine.handle(.reset, at: 1), [])
        XCTAssertEqual(machine.phase, .idle)
        XCTAssertEqual(machine.handle(.optionDown(.right, clean: true), at: 2), [])
        XCTAssertEqual(machine.handle(.optionUp(.right), at: 2.1), [.armed])
    }

    func testRightThenLeftSequenceAlsoActivates() {
        var machine = OptionGestureMachine()
        arm(&machine, downAt: 0, upAt: 0.1, key: .right)
        XCTAssertEqual(
            machine.handle(.optionDown(.left, clean: true), at: 0.2),
            [.holding(progress: 0)]
        )
        XCTAssertEqual(
            machine.handle(.tick, at: 1.7),
            [.holding(progress: 1), .startRecording]
        )
    }

    func testRouterPreservesCompleteLeftOptionDictationGesture() {
        var router = OptionCommandRouter()

        XCTAssertEqual(router.handle(.optionDown(.left, clean: true), at: 0), [])
        XCTAssertEqual(
            router.handle(.optionUp(.left), at: 0.1),
            [.dictation(.armed)]
        )
        XCTAssertEqual(
            router.handle(.optionDown(.left, clean: true), at: 0.2),
            [.dictation(.holding(progress: 0))]
        )
        XCTAssertEqual(
            router.handle(.tick, at: 1.7),
            [.dictation(.holding(progress: 1)), .dictation(.startRecording)]
        )
        XCTAssertEqual(router.dictationPhase, .recording)
        XCTAssertEqual(router.handle(.optionUp(.left), at: 1.8), [])
        XCTAssertEqual(
            router.handle(.optionDown(.left, clean: true), at: 2),
            [.dictation(.stopRecording)]
        )
        XCTAssertEqual(router.dictationPhase, .idle)
    }

    func testRouterRequiresRightTapThenHoldAndReadsOnce() {
        var router = OptionCommandRouter()

        XCTAssertEqual(router.handle(.optionDown(.right, clean: true), at: 1), [])
        XCTAssertEqual(
            router.handle(.optionDown(.right, clean: true), at: 1.01),
            []
        )
        XCTAssertEqual(
            router.handle(.optionUp(.right), at: 1.1),
            [.readingArmed]
        )
        XCTAssertEqual(
            router.handle(.optionDown(.right, clean: true), at: 1.2),
            [.readingHolding(progress: 0)]
        )
        XCTAssertEqual(
            router.handle(.optionDown(.right, clean: true), at: 1.21),
            []
        )
        XCTAssertEqual(
            router.handle(.tick, at: 1.95),
            [.readingHolding(progress: 0.5)]
        )
        XCTAssertEqual(
            router.handle(.tick, at: 2.7),
            [.readingHolding(progress: 1), .readSelection]
        )
        XCTAssertEqual(router.readingGesturePhase, .idle)
        XCTAssertEqual(router.handle(.tick, at: 3), [])
        XCTAssertEqual(router.handle(.optionUp(.right), at: 3.1), [])
    }

    func testRouterRightReleaseAtHoldThresholdReads() {
        var router = OptionCommandRouter()
        armReading(&router, downAt: 0, upAt: 0.1)
        XCTAssertEqual(
            router.handle(.optionDown(.right, clean: true), at: 0.2),
            [.readingHolding(progress: 0)]
        )
        XCTAssertEqual(
            router.handle(.optionUp(.right), at: 1.7),
            [.readingHolding(progress: 1), .readSelection]
        )
        XCTAssertEqual(router.readingGesturePhase, .idle)
    }

    func testRouterEarlyRightHoldReleaseCancelsAndCannotReadLater() {
        var router = OptionCommandRouter()
        armReading(&router, downAt: 0, upAt: 0.1)
        _ = router.handle(.optionDown(.right, clean: true), at: 0.2)

        XCTAssertEqual(
            router.handle(.optionUp(.right), at: 1.699_999),
            [.readingCancelled]
        )
        XCTAssertEqual(router.readingGesturePhase, .idle)
        XCTAssertEqual(router.handle(.tick, at: 2), [])
    }

    func testRouterRightGestureUsesConfiguredTiming() {
        let configuration = GestureConfiguration(
            tapMaximum: 0.1,
            secondPressWindow: 0.3,
            holdDuration: 0.4
        )
        var router = OptionCommandRouter(configuration: configuration)

        _ = router.handle(.optionDown(.right, clean: true), at: 0)
        XCTAssertEqual(router.handle(.optionUp(.right), at: 0.1), [.readingArmed])
        XCTAssertEqual(
            router.handle(.optionDown(.right, clean: true), at: 0.4),
            [.readingHolding(progress: 0)]
        )
        XCTAssertEqual(
            router.handle(.tick, at: 0.8),
            [.readingHolding(progress: 1), .readSelection]
        )

        var slowTap = OptionCommandRouter(configuration: configuration)
        _ = slowTap.handle(.optionDown(.right, clean: true), at: 1)
        XCTAssertEqual(slowTap.handle(.optionUp(.right), at: 1.100_001), [])
        XCTAssertEqual(slowTap.readingGesturePhase, .idle)
    }

    func testRouterArmedRightGestureExpiresAndLatePressBecomesFreshTap() {
        var expired = OptionCommandRouter()
        armReading(&expired, downAt: 0, upAt: 0.1)
        XCTAssertEqual(expired.handle(.tick, at: 2.1), [])
        XCTAssertEqual(
            expired.handle(.tick, at: 2.100_001),
            [.readingCancelled]
        )
        XCTAssertEqual(expired.readingGesturePhase, .idle)

        var latePress = OptionCommandRouter()
        armReading(&latePress, downAt: 10, upAt: 10.1)
        XCTAssertEqual(
            latePress.handle(.optionDown(.right, clean: true), at: 12.100_001),
            [.readingCancelled]
        )
        XCTAssertEqual(latePress.readingGesturePhase, .firstPress)
        XCTAssertEqual(
            latePress.handle(.optionUp(.right), at: 12.2),
            [.readingArmed]
        )
    }

    func testRouterSuppressesDirtyRightOptionAndOrdinaryChord() {
        var dirty = OptionCommandRouter()
        XCTAssertEqual(
            dirty.handle(.optionDown(.right, clean: false), at: 0),
            []
        )
        XCTAssertEqual(dirty.handle(.optionUp(.right), at: 0.1), [])

        var chord = OptionCommandRouter()
        armReading(&chord, downAt: 1, upAt: 1.1)
        XCTAssertEqual(
            chord.handle(.otherKeyDown, at: 1.2),
            [.readingCancelled]
        )
        XCTAssertEqual(chord.handle(.optionUp(.right), at: 1.3), [])

        var dirtySecondPress = OptionCommandRouter()
        armReading(&dirtySecondPress, downAt: 2, upAt: 2.1)
        XCTAssertEqual(
            dirtySecondPress.handle(
                .optionDown(.right, clean: false),
                at: 2.2
            ),
            [.readingCancelled]
        )
        XCTAssertEqual(
            dirtySecondPress.handle(.optionUp(.right), at: 2.3),
            []
        )
    }

    func testRouterRightHoldCancelsOnCrossKeyAndReset() {
        var ordinaryKey = OptionCommandRouter()
        armReading(&ordinaryKey, downAt: 0, upAt: 0.1)
        _ = ordinaryKey.handle(.optionDown(.right, clean: true), at: 0.2)
        XCTAssertEqual(
            ordinaryKey.handle(.otherKeyDown, at: 0.3),
            [.readingCancelled]
        )
        XCTAssertEqual(ordinaryKey.handle(.tick, at: 2), [])

        var leftCross = OptionCommandRouter()
        armReading(&leftCross, downAt: 10, upAt: 10.1)
        _ = leftCross.handle(.optionDown(.right, clean: true), at: 10.2)
        XCTAssertEqual(
            leftCross.handle(.optionDown(.left, clean: false), at: 10.3),
            [.readingCancelled]
        )
        XCTAssertEqual(leftCross.handle(.optionUp(.left), at: 10.4), [])
        XCTAssertEqual(leftCross.handle(.optionUp(.right), at: 10.5), [])
        XCTAssertEqual(leftCross.dictationPhase, .idle)

        var reset = OptionCommandRouter()
        armReading(&reset, downAt: 20, upAt: 20.1)
        _ = reset.handle(.optionDown(.right, clean: true), at: 20.2)
        XCTAssertEqual(
            reset.handle(.reset, at: .nan),
            [.readingCancelled]
        )
        XCTAssertEqual(reset.readingGesturePhase, .idle)
        XCTAssertEqual(reset.handle(.tick, at: 22), [])
    }

    func testRouterCrossOptionChordCancelsBothPendingGestures() {
        var leftThenRight = OptionCommandRouter()
        _ = leftThenRight.handle(.optionDown(.left, clean: true), at: 0)
        XCTAssertEqual(
            leftThenRight.handle(.optionDown(.right, clean: false), at: 0.1),
            [.dictation(.cancelled)]
        )
        XCTAssertEqual(leftThenRight.handle(.optionUp(.right), at: 0.2), [])
        XCTAssertEqual(leftThenRight.handle(.optionUp(.left), at: 0.3), [])
        XCTAssertEqual(leftThenRight.dictationPhase, .idle)
        XCTAssertEqual(leftThenRight.readingGesturePhase, .idle)

        var rightThenLeft = OptionCommandRouter()
        _ = rightThenLeft.handle(.optionDown(.right, clean: true), at: 1)
        XCTAssertEqual(
            rightThenLeft.handle(.optionDown(.left, clean: true), at: 1.1),
            []
        )
        XCTAssertEqual(rightThenLeft.handle(.optionUp(.left), at: 1.2), [])
        XCTAssertEqual(rightThenLeft.handle(.optionUp(.right), at: 1.3), [])
        XCTAssertEqual(rightThenLeft.dictationPhase, .idle)

        var armedRightThenLeft = OptionCommandRouter()
        armReading(&armedRightThenLeft, downAt: 2, upAt: 2.1)
        XCTAssertEqual(
            armedRightThenLeft.handle(
                .optionDown(.left, clean: true),
                at: 2.2
            ),
            [.readingCancelled]
        )
        XCTAssertEqual(
            armedRightThenLeft.handle(.optionUp(.left), at: 2.3),
            []
        )
        XCTAssertEqual(armedRightThenLeft.dictationPhase, .idle)
        XCTAssertEqual(armedRightThenLeft.readingGesturePhase, .idle)

        var armedLeftThenRight = OptionCommandRouter()
        _ = armedLeftThenRight.handle(
            .optionDown(.left, clean: true),
            at: 3
        )
        _ = armedLeftThenRight.handle(.optionUp(.left), at: 3.1)
        XCTAssertEqual(
            armedLeftThenRight.handle(
                .optionDown(.right, clean: true),
                at: 3.2
            ),
            [.dictation(.cancelled)]
        )
        XCTAssertEqual(
            armedLeftThenRight.handle(.optionUp(.right), at: 3.3),
            []
        )
        XCTAssertEqual(armedLeftThenRight.readingGesturePhase, .idle)
    }

    func testRouterOrdinaryKeyCancelsPendingLeftGesture() {
        var router = OptionCommandRouter()
        _ = router.handle(.optionDown(.left, clean: true), at: 0)

        XCTAssertEqual(
            router.handle(.otherKeyDown, at: 0.1),
            [.dictation(.cancelled)]
        )
        XCTAssertEqual(router.handle(.optionUp(.left), at: 0.2), [])
        XCTAssertEqual(router.dictationPhase, .idle)
    }

    func testRouterRightOptionNeverStopsOrReadsDuringRecording() {
        var router = OptionCommandRouter()
        startRecording(&router)

        XCTAssertEqual(
            router.handle(.optionDown(.right, clean: true), at: 1.8),
            []
        )
        XCTAssertEqual(router.handle(.optionUp(.right), at: 1.9), [])
        XCTAssertEqual(router.dictationPhase, .recording)
        XCTAssertEqual(
            router.handle(.optionDown(.left, clean: true), at: 2),
            [.dictation(.stopRecording)]
        )
    }

    func testRouterHeldRightAfterReadCannotStartLeftDictation() {
        var router = OptionCommandRouter()
        armReading(&router, downAt: 0, upAt: 0.1)
        _ = router.handle(.optionDown(.right, clean: true), at: 0.2)
        XCTAssertEqual(
            router.handle(.tick, at: 1.7),
            [.readingHolding(progress: 1), .readSelection]
        )

        XCTAssertEqual(
            router.handle(.optionDown(.left, clean: true), at: 1.8),
            []
        )
        XCTAssertEqual(router.handle(.optionUp(.left), at: 1.9), [])
        XCTAssertEqual(router.dictationPhase, .idle)
        XCTAssertEqual(router.handle(.optionUp(.right), at: 2), [])
    }

    func testRouterResetClearsBothGesturesAtAnyTimestamp() {
        var router = OptionCommandRouter()
        _ = router.handle(.optionDown(.left, clean: true), at: 10)
        _ = router.handle(.reset, at: .nan)
        XCTAssertEqual(router.dictationPhase, .idle)
        XCTAssertEqual(router.handle(.optionUp(.left), at: 10.1), [])

        _ = router.handle(.optionDown(.right, clean: true), at: 20)
        XCTAssertEqual(
            router.handle(.optionUp(.right), at: 20.1),
            [.readingArmed]
        )
        XCTAssertEqual(
            router.handle(.reset, at: 1),
            [.readingCancelled]
        )
        XCTAssertEqual(router.handle(.optionUp(.right), at: 20.1), [])
        XCTAssertEqual(router.readingGesturePhase, .idle)

        XCTAssertEqual(
            router.handle(.optionDown(.right, clean: true), at: 21),
            []
        )
        XCTAssertEqual(
            router.handle(.optionUp(.right), at: 21.1),
            [.readingArmed]
        )
    }

    func testRouterStaleRightReleaseFailsClosed() {
        var router = OptionCommandRouter()
        armReading(&router, downAt: 10, upAt: 10.1)
        _ = router.handle(.optionDown(.right, clean: true), at: 10.2)

        XCTAssertEqual(
            router.handle(.optionUp(.right), at: 10.15),
            [.readingCancelled]
        )
        XCTAssertEqual(router.handle(.optionUp(.right), at: 10.3), [])
        XCTAssertEqual(router.readingGesturePhase, .idle)

        XCTAssertEqual(
            router.handle(.optionDown(.right, clean: true), at: 11),
            []
        )
        XCTAssertEqual(
            router.handle(.optionUp(.right), at: 11.1),
            [.readingArmed]
        )
    }

    func testRouterNonFiniteRightReleaseCancelsPresentedGesture() {
        var router = OptionCommandRouter()
        armReading(&router, downAt: 0, upAt: 0.1)
        _ = router.handle(.optionDown(.right, clean: true), at: 0.2)

        XCTAssertEqual(
            router.handle(.optionUp(.right), at: .nan),
            [.readingCancelled]
        )
        XCTAssertEqual(router.readingGesturePhase, .idle)
        XCTAssertEqual(router.handle(.tick, at: 2), [])
    }

    private func arm(
        _ machine: inout OptionGestureMachine,
        downAt: TimeInterval,
        upAt: TimeInterval,
        key: OptionKey
    ) {
        XCTAssertEqual(machine.handle(.optionDown(key, clean: true), at: downAt), [])
        XCTAssertEqual(machine.handle(.optionUp(key), at: upAt), [.armed])
    }

    private func startRecording(
        _ machine: inout OptionGestureMachine,
        activationKey: OptionKey,
        base: TimeInterval = 0
    ) {
        let firstKey: OptionKey = activationKey == .left ? .right : .left
        arm(&machine, downAt: base, upAt: base + 0.1, key: firstKey)
        XCTAssertEqual(
            machine.handle(.optionDown(activationKey, clean: true), at: base + 0.2),
            [.holding(progress: 0)]
        )
        XCTAssertEqual(
            machine.handle(.tick, at: base + 1.7),
            [.holding(progress: 1), .startRecording]
        )
    }

    private func startRecording(_ router: inout OptionCommandRouter) {
        XCTAssertEqual(router.handle(.optionDown(.left, clean: true), at: 0), [])
        XCTAssertEqual(
            router.handle(.optionUp(.left), at: 0.1),
            [.dictation(.armed)]
        )
        XCTAssertEqual(
            router.handle(.optionDown(.left, clean: true), at: 0.2),
            [.dictation(.holding(progress: 0))]
        )
        XCTAssertEqual(
            router.handle(.tick, at: 1.7),
            [.dictation(.holding(progress: 1)), .dictation(.startRecording)]
        )
        XCTAssertEqual(router.handle(.optionUp(.left), at: 1.75), [])
    }

    private func armReading(
        _ router: inout OptionCommandRouter,
        downAt: TimeInterval,
        upAt: TimeInterval
    ) {
        XCTAssertEqual(
            router.handle(.optionDown(.right, clean: true), at: downAt),
            []
        )
        XCTAssertEqual(
            router.handle(.optionUp(.right), at: upAt),
            [.readingArmed]
        )
    }
}
