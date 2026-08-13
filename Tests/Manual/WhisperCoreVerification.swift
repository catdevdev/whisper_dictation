import Darwin
import Foundation
import WhisperCore

/// Dependency-free verification for machines where SwiftPM/XCTest is not
/// installed correctly. Build WhisperCore as a module, link this executable,
/// and run it; every failed assertion is printed and produces exit status 1.
@main
private enum WhisperCoreVerification {
    static func main() {
        var verifier = Verifier()
        verifier.verifyConfigurationAndKeys()
        verifier.verifyGestureBoundaries()
        verifier.verifyGestureCancellation()
        verifier.verifyGestureEventSafety()
        verifier.verifyOptionTransitionOrdering()
        verifier.verifyOptionCommandRouting()
        verifier.verifyMultipartEncoding()
        verifier.verifyUnicodeTextChunking()

        if verifier.failureCount == 0 {
            print("WhisperCore manual verification passed (\(verifier.checkCount) checks)")
        } else {
            fputs(
                "WhisperCore manual verification failed: \(verifier.failureCount) of "
                    + "\(verifier.checkCount) checks failed\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }
    }
}

private struct Verifier {
    private(set) var checkCount = 0
    private(set) var failureCount = 0

    mutating func verifyConfigurationAndKeys() {
        let defaults = GestureConfiguration()
        expectEqual(OptionKey.left.rawValue, 56, "left Shift raw key code")
        expectEqual(OptionKey.right.rawValue, 61, "right Option raw key code")
        expectEqual(defaults.tapMaximum, 0.35, "default tap boundary")
        expectEqual(defaults.secondPressWindow, 2.0, "default second-press window")
        expectEqual(defaults.holdDuration, 1.5, "default hold threshold")
    }

    mutating func verifyGestureBoundaries() {
        var machine = OptionGestureMachine()
        expectEqual(
            machine.handle(.optionDown(.left, clean: true), at: 0),
            [],
            "first clean down"
        )
        expectEqual(machine.phase, .firstPress, "phase while first Option is down")
        expectEqual(
            machine.handle(.optionUp(.left), at: 0.35),
            [.armed],
            "tap maximum is inclusive"
        )
        expectEqual(machine.phase, .armed, "phase after first tap")
        expectEqual(
            machine.handle(.optionDown(.right, clean: true), at: 2.35),
            [.holding(progress: 0)],
            "second-press window is inclusive"
        )
        expectEqual(
            machine.handle(.tick, at: 3.10),
            [.holding(progress: 0.5)],
            "hold progress"
        )
        expectEqual(
            machine.handle(.tick, at: 3.85),
            [.holding(progress: 1), .startRecording],
            "hold duration is inclusive"
        )
        expectEqual(machine.handle(.tick, at: 10), [], "recording starts only once")
        expectEqual(
            machine.handle(.optionUp(.right), at: 10.1),
            [],
            "activation release does not stop"
        )
        expectEqual(
            machine.handle(.optionDown(.left, clean: true), at: 10.2),
            [.stopRecording],
            "next clean Option down stops"
        )
        expectEqual(
            machine.handle(.optionDown(.left, clean: true), at: 10.21),
            [],
            "duplicate stop down is ignored"
        )
        expectEqual(
            machine.handle(.optionUp(.left), at: 10.3),
            [],
            "stop-key release does not arm"
        )

        var slowTap = OptionGestureMachine()
        _ = slowTap.handle(.optionDown(.left, clean: true), at: 0)
        expectEqual(
            slowTap.handle(.optionUp(.left), at: 0.350_001),
            [.cancelled],
            "tap over maximum cancels"
        )

        var expired = OptionGestureMachine()
        arm(&expired, key: .right, downAt: 0, upAt: 0.1, label: "expired window setup")
        expectEqual(
            expired.handle(.optionDown(.left, clean: true), at: 2.100_001),
            [.cancelled],
            "second press over window cancels"
        )
        expectEqual(expired.phase, .firstPress, "late down can begin a new first tap")
    }

    mutating func verifyGestureCancellation() {
        var early = OptionGestureMachine()
        arm(&early, key: .left, downAt: 0, upAt: 0.1, label: "early release setup")
        _ = early.handle(.optionDown(.right, clean: true), at: 0.2)
        expectEqual(
            early.handle(.optionUp(.right), at: 1.699_999),
            [.cancelled],
            "early activation release cancels"
        )
        expectEqual(early.handle(.tick, at: 2), [], "cancelled hold cannot start later")

        var ordinaryKey = OptionGestureMachine()
        arm(
            &ordinaryKey,
            key: .right,
            downAt: 0,
            upAt: 0.1,
            label: "ordinary key setup"
        )
        _ = ordinaryKey.handle(.optionDown(.left, clean: true), at: 0.2)
        expectEqual(
            ordinaryKey.handle(.otherKeyDown, at: 0.3),
            [.cancelled],
            "ordinary key cancels holding"
        )

        var dirty = OptionGestureMachine()
        arm(&dirty, key: .left, downAt: 0, upAt: 0.1, label: "dirty press setup")
        expectEqual(
            dirty.handle(.optionDown(.right, clean: false), at: 0.2),
            [.cancelled],
            "dirty second press cancels"
        )

        var chord = OptionGestureMachine()
        _ = chord.handle(.optionDown(.left, clean: true), at: 0)
        expectEqual(
            chord.handle(.optionDown(.right, clean: true), at: 0.1),
            [.cancelled],
            "two-Option chord cancels"
        )

        var dirtyInitial = OptionGestureMachine()
        expectEqual(
            dirtyInitial.handle(.optionDown(.left, clean: false), at: 0),
            [],
            "dirty initial press is ignored"
        )
        expectEqual(dirtyInitial.handle(.optionUp(.left), at: 0.1), [], "dirty release is ignored")
        expectEqual(dirtyInitial.phase, .idle, "dirty initial press stays idle")
    }

    mutating func verifyGestureEventSafety() {
        var duplicate = OptionGestureMachine()
        _ = duplicate.handle(.optionDown(.right, clean: true), at: 10)
        expectEqual(
            duplicate.handle(.optionDown(.right, clean: true), at: 10.01),
            [],
            "duplicate down"
        )
        expectEqual(
            duplicate.handle(.optionUp(.left), at: 10.02),
            [],
            "unmatched opposite release"
        )
        expectEqual(
            duplicate.handle(.optionUp(.right), at: 10.1),
            [.armed],
            "matched release after duplicates"
        )
        expectEqual(duplicate.handle(.optionUp(.right), at: 10.11), [], "duplicate up")

        var stale = OptionGestureMachine()
        _ = stale.handle(.optionDown(.left, clean: true), at: 20)
        expectEqual(stale.handle(.optionUp(.left), at: 19), [], "stale release")
        expectEqual(stale.phase, .firstPress, "stale event cannot mutate phase")
        expectEqual(
            stale.handle(.optionUp(.left), at: 20.1),
            [.armed],
            "physical key tracking survives stale release"
        )
        expectEqual(stale.handle(.reset, at: 1), [], "reset accepts any timestamp")
        expectEqual(stale.phase, .idle, "reset phase")
        expectEqual(
            stale.handle(.optionDown(.right, clean: true), at: 2),
            [],
            "fresh input after reset"
        )

        var delayedRelease = OptionGestureMachine()
        arm(
            &delayedRelease,
            key: .left,
            downAt: 30,
            upAt: 30.1,
            label: "delayed holding release setup"
        )
        _ = delayedRelease.handle(.optionDown(.right, clean: true), at: 30.2)
        _ = delayedRelease.handle(.tick, at: 31)
        expectEqual(
            delayedRelease.handle(.optionUp(.right), at: 30.9),
            [.cancelled],
            "stale matching release safely cancels holding"
        )
        expectEqual(
            delayedRelease.phase,
            .idle,
            "stale holding release cannot start recording later"
        )

        var recording = OptionGestureMachine()
        arm(&recording, key: .left, downAt: 0, upAt: 0.1, label: "recording setup")
        _ = recording.handle(.optionDown(.right, clean: true), at: 0.2)
        _ = recording.handle(.tick, at: 1.7)
        expectEqual(
            recording.handle(.otherKeyDown, at: 1.8),
            [],
            "ordinary key does not stop recording"
        )
        expectEqual(recording.phase, .recording, "recording remains active")
    }

    mutating func verifyOptionTransitionOrdering() {
        var tracker = OptionTransitionTracker()
        expectEqual(
            tracker.transition(for: .left, isPressed: true, clean: true),
            .optionDown(.left, clean: true),
            "physical gesture-key down creates one transition"
        )
        expectEqual(
            tracker.transition(for: .left, isPressed: true, clean: true),
            nil,
            "duplicate physical gesture-key down is ignored"
        )
        expectEqual(
            tracker.transition(for: .left, isPressed: false, clean: true),
            .optionUp(.left),
            "physical gesture-key release creates one transition"
        )
        expectEqual(
            tracker.transition(for: .left, isPressed: false, clean: true),
            nil,
            "unmatched physical gesture-key release is ignored"
        )
        expectEqual(
            tracker.transition(for: .left, isPressed: true, clean: true),
            .optionDown(.left, clean: true),
            "physical repress is a fresh down"
        )

        tracker.reset(to: [.right])
        expectEqual(
            tracker.transition(for: .right, isPressed: false, clean: true),
            .optionUp(.right),
            "release after monitor startup uses initial hardware snapshot"
        )
        _ = tracker.transition(for: .left, isPressed: true, clean: true)
        expectEqual(
            tracker.transition(for: .right, isPressed: true, clean: true),
            .optionDown(.right, clean: false),
            "second physical gesture key is never a clean press"
        )
        expectEqual(
            tracker.pressedKeys,
            Set([.left, .right]),
            "tracker retains both pressed gesture keys"
        )

        var eventSnapshots = OptionTransitionTracker()
        expectEqual(
            eventSnapshots.transition(
                for: .right,
                pressedInEvent: [.right],
                clean: true
            ),
            .optionDown(.right, clean: true),
            "modifier snapshot starts right Option"
        )
        expectEqual(
            eventSnapshots.transition(
                for: .right,
                pressedInEvent: [],
                clean: true
            ),
            .optionUp(.right),
            "next modifier snapshot releases right Option"
        )

        var twoKeyChord = OptionTransitionTracker(
            initiallyPressed: [.left, .right]
        )
        expectEqual(
            twoKeyChord.transition(
                for: .left,
                pressedInEvent: [.right],
                clean: false
            ),
            .optionUp(.left),
            "event key releases one side while chord aggregate remains set"
        )
        expectEqual(
            twoKeyChord.pressedKeys,
            Set([.right]),
            "two-Option chord retains the key that remains down"
        )

        var interruptedChord = OptionTransitionTracker(
            initiallyPressed: [.left, .right]
        )
        expectEqual(
            interruptedChord.transition(
                for: .right,
                pressedInEvent: [],
                clean: false
            ),
            .reset,
            "aggregate release resets a chord with a missing earlier edge"
        )
        expectEqual(
            interruptedChord.pressedKeys,
            Set<OptionKey>(),
            "interrupted chord cannot leave a stuck Option key"
        )

        var fullChord = OptionTransitionTracker()
        expectEqual(
            fullChord.transition(
                for: .left,
                pressedInEvent: [.left],
                clean: true
            ),
            .optionDown(.left, clean: true),
            "chord starts with left Shift"
        )
        expectEqual(
            fullChord.transition(
                for: .right,
                pressedInEvent: [.left, .right],
                clean: true
            ),
            .optionDown(.right, clean: false),
            "second chord key is not clean"
        )
        expectEqual(
            fullChord.transition(
                for: .right,
                pressedInEvent: [.left, .right],
                clean: true
            ),
            nil,
            "duplicate chord snapshot is ignored"
        )
        expectEqual(
            fullChord.transition(
                for: .left,
                pressedInEvent: [.right],
                clean: false
            ),
            .optionUp(.left),
            "chord releases left while right remains"
        )
        expectEqual(
            fullChord.transition(
                for: .right,
                pressedInEvent: [],
                clean: false
            ),
            .optionUp(.right),
            "chord releases right"
        )
        expectEqual(
            fullChord.pressedKeys,
            Set<OptionKey>(),
            "full chord sequence leaves no stuck Option"
        )
    }

    mutating func verifyOptionCommandRouting() {
        var dictation = OptionCommandRouter()
        expectEqual(
            dictation.handle(.optionDown(.left, clean: true), at: 0),
            [],
            "router left first down"
        )
        expectEqual(
            dictation.handle(.optionUp(.left), at: 0.1),
            [.dictation(.armed)],
            "router left tap arms dictation"
        )
        expectEqual(
            dictation.handle(.optionDown(.left, clean: true), at: 0.2),
            [.dictation(.holding(progress: 0))],
            "router left second press starts hold"
        )
        expectEqual(
            dictation.handle(.tick, at: 1.7),
            [.dictation(.holding(progress: 1)), .dictation(.startRecording)],
            "router left hold starts recording"
        )
        expectEqual(
            dictation.handle(.optionUp(.left), at: 1.8),
            [],
            "router left activation release does not stop"
        )

        expectEqual(
            dictation.handle(.optionDown(.right, clean: true), at: 1.9),
            [],
            "right Option cannot stop recording"
        )
        expectEqual(
            dictation.handle(.optionUp(.right), at: 1.95),
            [],
            "right Option cannot read during recording"
        )
        expectEqual(
            dictation.dictationPhase,
            .recording,
            "right Option leaves recording active"
        )
        expectEqual(
            dictation.handle(.optionDown(.left, clean: true), at: 2),
            [.dictation(.stopRecording)],
            "next left Shift stops recording"
        )

        var reading = OptionCommandRouter()
        expectEqual(
            reading.handle(.optionDown(.right, clean: true), at: 10),
            [],
            "right reading first tap down"
        )
        expectEqual(
            reading.handle(.optionUp(.right), at: 10.1),
            [.readingArmed],
            "right reading first tap arms"
        )
        expectEqual(
            reading.handle(.optionDown(.right, clean: true), at: 10.2),
            [.readingHolding(progress: 0)],
            "right reading second press starts hold"
        )
        expectEqual(
            reading.handle(.tick, at: 10.95),
            [.readingHolding(progress: 0.5)],
            "right reading reports hold progress"
        )
        expectEqual(
            reading.handle(.tick, at: 11.7),
            [.readingHolding(progress: 1), .readSelection],
            "right reading hold emits one read command"
        )
        expectEqual(
            reading.handle(.tick, at: 20),
            [],
            "right reading command is not repeated"
        )
        expectEqual(
            reading.handle(.optionUp(.right), at: 20.1),
            [],
            "right activation release is consumed"
        )

        var dirtyRight = OptionCommandRouter()
        _ = dirtyRight.handle(.optionDown(.right, clean: false), at: 0)
        expectEqual(
            dirtyRight.handle(.optionUp(.right), at: 0.1),
            [],
            "dirty right Option is suppressed"
        )

        var earlyRelease = OptionCommandRouter()
        _ = earlyRelease.handle(.optionDown(.right, clean: true), at: 0)
        _ = earlyRelease.handle(.optionUp(.right), at: 0.1)
        _ = earlyRelease.handle(.optionDown(.right, clean: true), at: 0.2)
        expectEqual(
            earlyRelease.handle(.optionUp(.right), at: 1.699_999),
            [.readingCancelled],
            "early right activation release cancels"
        )
        expectEqual(
            earlyRelease.handle(.tick, at: 2),
            [],
            "cancelled right hold cannot read later"
        )

        var ordinaryChord = OptionCommandRouter()
        _ = ordinaryChord.handle(.optionDown(.right, clean: true), at: 0)
        _ = ordinaryChord.handle(.optionUp(.right), at: 0.1)
        expectEqual(
            ordinaryChord.handle(.otherKeyDown, at: 0.2),
            [.readingCancelled],
            "ordinary chord cancels armed right read"
        )
        expectEqual(
            ordinaryChord.handle(.optionUp(.right), at: 0.3),
            [],
            "suppressed right release does not read"
        )

        var holdingChord = OptionCommandRouter()
        _ = holdingChord.handle(.optionDown(.right, clean: true), at: 0)
        _ = holdingChord.handle(.optionUp(.right), at: 0.1)
        _ = holdingChord.handle(.optionDown(.right, clean: true), at: 0.2)
        expectEqual(
            holdingChord.handle(.optionDown(.left, clean: false), at: 0.3),
            [.readingCancelled],
            "cross-key press cancels right hold"
        )
        expectEqual(
            holdingChord.handle(.tick, at: 2),
            [],
            "cross-key-cancelled right hold cannot read later"
        )

        var crossChord = OptionCommandRouter()
        _ = crossChord.handle(.optionDown(.left, clean: true), at: 0)
        expectEqual(
            crossChord.handle(.optionDown(.right, clean: false), at: 0.1),
            [.dictation(.cancelled)],
            "mixed modifier chord cancels pending left gesture"
        )
        expectEqual(
            crossChord.handle(.optionUp(.right), at: 0.2),
            [],
            "mixed modifier chord suppresses right read"
        )
        expectEqual(crossChord.dictationPhase, .idle, "cross chord leaves router idle")

        var rightCrossChord = OptionCommandRouter()
        _ = rightCrossChord.handle(.optionDown(.right, clean: true), at: 0)
        _ = rightCrossChord.handle(.optionUp(.right), at: 0.1)
        expectEqual(
            rightCrossChord.handle(.optionDown(.left, clean: true), at: 0.2),
            [.readingCancelled],
            "left Shift cannot complete an armed right gesture"
        )
        expectEqual(
            rightCrossChord.handle(.optionUp(.left), at: 0.3),
            [],
            "cross-key left release cannot arm dictation"
        )
        expectEqual(
            rightCrossChord.dictationPhase,
            .idle,
            "right-to-left cross gesture leaves dictation idle"
        )

        var reset = OptionCommandRouter()
        _ = reset.handle(.optionDown(.right, clean: true), at: 20)
        _ = reset.handle(.optionUp(.right), at: 20.1)
        expectEqual(
            reset.handle(.reset, at: .nan),
            [.readingCancelled],
            "router reset cancels presented right gesture at NaN timestamp"
        )
        expectEqual(
            reset.handle(.optionUp(.right), at: 20.1),
            [],
            "router reset clears pending right read"
        )
        expectEqual(reset.dictationPhase, .idle, "router reset clears dictation state")

        var stale = OptionCommandRouter()
        _ = stale.handle(.optionDown(.right, clean: true), at: 30)
        _ = stale.handle(.optionUp(.right), at: 30.1)
        _ = stale.handle(.optionDown(.right, clean: true), at: 30.2)
        expectEqual(
            stale.handle(.optionUp(.right), at: 30.15),
            [.readingCancelled],
            "stale right release fails closed"
        )
        expectEqual(
            stale.handle(.optionUp(.right), at: 30.3),
            [],
            "stale release cannot be replayed as a read"
        )

        var configured = OptionCommandRouter(
            configuration: GestureConfiguration(
                tapMaximum: 0.1,
                secondPressWindow: 0.2,
                holdDuration: 0.3
            )
        )
        _ = configured.handle(.optionDown(.right, clean: true), at: 0)
        expectEqual(
            configured.handle(.optionUp(.right), at: 0.1),
            [.readingArmed],
            "configured right tap boundary is inclusive"
        )
        expectEqual(
            configured.handle(.optionDown(.right, clean: true), at: 0.3),
            [.readingHolding(progress: 0)],
            "configured right second-press boundary is inclusive"
        )
        expectEqual(
            configured.handle(.optionUp(.right), at: 0.6),
            [.readingHolding(progress: 1), .readSelection],
            "configured right hold boundary is inclusive"
        )
    }

    mutating func verifyMultipartEncoding() {
        let empty = MultipartFormData(boundary: "Empty")
        expectEqual(
            empty.body,
            Data("--Empty--\r\n".utf8),
            "empty multipart closing boundary"
        )
        expectEqual(
            empty.contentType,
            "multipart/form-data; boundary=Empty",
            "multipart content type"
        )

        let binary = Data([0x00, 0x0D, 0x0A, 0xFF])
        var form = MultipartFormData(boundary: "B")
        form.appendField(name: "model", value: "whisper-1")
        form.appendFile(name: "file", filename: "a.wav", mimeType: "audio/wav", data: binary)

        var expected = Data(
            ("--B\r\n"
                + "Content-Disposition: form-data; name=\"model\"\r\n"
                + "\r\n"
                + "whisper-1\r\n"
                + "--B\r\n"
                + "Content-Disposition: form-data; name=\"file\"; filename=\"a.wav\"\r\n"
                + "Content-Type: audio/wav\r\n"
                + "\r\n").utf8
        )
        expected.append(binary)
        expected.append(contentsOf: "\r\n--B--\r\n".utf8)

        expectEqual(form.body, expected, "multipart exact bytes and part order")
        expectEqual(form.body, form.body, "multipart encoding is idempotent")
        expectEqual(form.count, 2, "multipart part count")

        var safe = MultipartFormData(boundary: "Safe")
        safe.appendFile(
            name: "na\"me\r\nx",
            filename: "a\\b\"\n.wav",
            mimeType: "audio/wav\r\nX-Evil: yes",
            data: Data()
        )
        let safeBody = String(decoding: safe.body, as: UTF8.self)
        expect(
            safeBody.contains("name=\"na\\\"me%0D%0Ax\""),
            "multipart field name escaping"
        )
        expect(
            safeBody.contains("filename=\"a\\\\b\\\"%0A.wav\""),
            "multipart filename escaping"
        )
        expect(!safeBody.contains("\r\nX-Evil:"), "multipart MIME header injection blocked")
        let closingBoundaryCount = occurrences(
            of: Data("--Safe--\r\n".utf8),
            in: safe.body
        )
        expectEqual(
            closingBoundaryCount,
            1,
            "one closing multipart boundary"
        )
    }

    mutating func verifyUnicodeTextChunking() {
        expectEqual(
            UnicodeTextChunker.chunks(of: ""),
            [],
            "empty Unicode text has no chunks"
        )
        expectEqual(
            UnicodeTextChunker.chunks(of: "abcdef", maximumUTF16Units: 3),
            ["abc", "def"],
            "ASCII text respects the UTF-16 limit"
        )
        expectEqual(
            UnicodeTextChunker.chunks(of: "A😀B", maximumUTF16Units: 2),
            ["A", "😀", "B"],
            "surrogate pair stays intact"
        )

        let decomposedCharacter = "e\u{301}"
        expectEqual(
            UnicodeTextChunker.chunks(
                of: "A\(decomposedCharacter)B",
                maximumUTF16Units: 2
            ),
            ["A", decomposedCharacter, "B"],
            "combining sequence stays intact"
        )

        let familyEmoji = "👨‍👩‍👧‍👦"
        expectEqual(
            UnicodeTextChunker.chunks(of: familyEmoji, maximumUTF16Units: 2),
            [familyEmoji],
            "oversized grapheme cluster stays intact"
        )

        let mixedText = "Hello, мир 👋🏽 — cafe\u{301}"
        let chunks = UnicodeTextChunker.chunks(of: mixedText, maximumUTF16Units: 5)
        expectEqual(chunks.joined(), mixedText, "Unicode chunks reassemble losslessly")
        expect(
            chunks.allSatisfy { chunk in
                chunk.utf16.count <= 5 || chunk.count == 1
            },
            "only one oversized grapheme may exceed the UTF-16 limit"
        )
        expectEqual(
            UnicodeTextChunker.chunks(of: "ab", maximumUTF16Units: 0),
            ["a", "b"],
            "invalid UTF-16 limit is clamped"
        )
    }

    private mutating func arm(
        _ machine: inout OptionGestureMachine,
        key: OptionKey,
        downAt: TimeInterval,
        upAt: TimeInterval,
        label: String
    ) {
        expectEqual(
            machine.handle(.optionDown(key, clean: true), at: downAt),
            [],
            "\(label): down"
        )
        expectEqual(
            machine.handle(.optionUp(key), at: upAt),
            [.armed],
            "\(label): up"
        )
    }

    private mutating func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
        checkCount += 1
        guard !condition() else { return }
        failureCount += 1
        fputs("FAIL: \(label)\n", stderr)
    }

    private mutating func expectEqual<T: Equatable>(
        _ actual: @autoclosure () -> T,
        _ expected: @autoclosure () -> T,
        _ label: String
    ) {
        checkCount += 1
        let actualValue = actual()
        let expectedValue = expected()
        guard actualValue != expectedValue else { return }
        failureCount += 1
        fputs(
            "FAIL: \(label)\n  expected: \(String(describing: expectedValue))"
                + "\n  actual:   \(String(describing: actualValue))\n",
            stderr
        )
    }

    private func occurrences(of needle: Data, in haystack: Data) -> Int {
        guard !needle.isEmpty, haystack.count >= needle.count else { return 0 }
        var count = 0
        var index = haystack.startIndex
        let lastStart = haystack.index(haystack.endIndex, offsetBy: -needle.count)

        while index <= lastStart {
            let end = haystack.index(index, offsetBy: needle.count)
            if haystack[index..<end].elementsEqual(needle) {
                count += 1
                index = end
            } else {
                index = haystack.index(after: index)
            }
        }
        return count
    }
}
