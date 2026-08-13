import Darwin
import Foundation

/// Dependency-free verification for application state transitions. This target
/// deliberately compiles only AppState.swift, so it never touches TCC or Keychain.
@main
private enum WhisperAppStateVerification {
    static func main() {
        var verifier = Verifier()
        verifier.verifyReadinessUsesRequiredCapabilities()
        verifier.verifyMatchingFailureRecovery()
        verifier.verifyRecoverableTranscriptDoesNotBlockDictation()

        if verifier.failureCount == 0 {
            print("WhisperApp state verification passed (\(verifier.checkCount) checks)")
        } else {
            fputs(
                "WhisperApp state verification failed: \(verifier.failureCount) of "
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

    mutating func verifyReadinessUsesRequiredCapabilities() {
        expect(
            AppReadiness(
                microphone: .allowed,
                accessibility: .allowed,
                hasAPIKey: true
            ).canDictate,
            "microphone, Accessibility, and an API key are sufficient"
        )
        expect(
            !AppReadiness(
                microphone: .denied,
                accessibility: .allowed,
                hasAPIKey: true
            ).canDictate,
            "microphone remains required"
        )
        expect(
            !AppReadiness(
                microphone: .allowed,
                accessibility: .denied,
                hasAPIKey: true
            ).canDictate,
            "Accessibility remains required"
        )
        expect(
            !AppReadiness(
                microphone: .allowed,
                accessibility: .allowed,
                hasAPIKey: false
            ).canDictate,
            "API key remains required"
        )
    }

    mutating func verifyMatchingFailureRecovery() {
        let keychainMessage = "Не удалось прочитать ключ OpenAI из Связки ключей."
        let unrelatedMessage = "Нет связи с OpenAI."

        expectEqual(
            DictationPhase.failure(message: keychainMessage)
                .clearingFailure(matching: keychainMessage),
            .idle,
            "successful refresh clears the matching Keychain read failure"
        )
        expectEqual(
            DictationPhase.failure(message: unrelatedMessage)
                .clearingFailure(matching: keychainMessage),
            .failure(message: unrelatedMessage),
            "successful refresh preserves an unrelated failure"
        )
        expectEqual(
            DictationPhase.success.clearingFailure(matching: keychainMessage),
            .success,
            "successful refresh preserves a non-failure phase"
        )
    }

    mutating func verifyRecoverableTranscriptDoesNotBlockDictation() {
        expect(
            DictationAdmissionPolicy.canBegin(
                hasActiveSession: false,
                hasRecoverableTranscript: true
            ),
            "a recoverable transcript never blocks a new dictation"
        )
        expect(
            !DictationAdmissionPolicy.canBegin(
                hasActiveSession: true,
                hasRecoverableTranscript: false
            ),
            "an active dictation still prevents a concurrent session"
        )
    }

    private mutating func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) {
        checkCount += 1
        guard !condition() else { return }
        failureCount += 1
        fputs("FAIL: \(label)\n", stderr)
    }

    private mutating func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) {
        expect(actual == expected, "\(label): expected \(expected), got \(actual)")
    }
}
