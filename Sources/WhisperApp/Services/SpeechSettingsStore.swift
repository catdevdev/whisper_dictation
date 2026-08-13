import Foundation

final class SpeechSettingsStore {
    private enum Key {
        static let voiceIdentifier = "qwen.voiceIdentifier"
        static let speechRate = "qwen.rateMultiplier"
    }

    static let defaultVoiceIdentifier = QwenTTSCatalog.defaultVoiceID
    static let defaultSpeechRate: Float = 1
    static let supportedSpeechRate: ClosedRange<Float> = 0.5...2

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Qwen3-TTS CustomVoice speaker name.
    var voiceIdentifier: String {
        get {
            let stored = defaults.string(forKey: Key.voiceIdentifier)
            let validated = Self.validatedVoiceIdentifier(stored)

            // Repair settings written by older builds so every caller observes
            // the same catalog-backed value from this point forward.
            if stored != validated {
                defaults.set(validated, forKey: Key.voiceIdentifier)
            }
            return validated
        }
        set {
            defaults.set(
                Self.validatedVoiceIdentifier(newValue),
                forKey: Key.voiceIdentifier
            )
        }
    }

    var speechRate: Float {
        get {
            guard defaults.object(forKey: Key.speechRate) != nil else {
                return Self.defaultSpeechRate
            }
            let stored = defaults.float(forKey: Key.speechRate)
            let validated = Self.validatedSpeechRate(stored)
            if stored != validated {
                defaults.set(validated, forKey: Key.speechRate)
            }
            return validated
        }
        set {
            defaults.set(Self.validatedSpeechRate(newValue), forKey: Key.speechRate)
        }
    }

    static func validatedVoiceIdentifier(_ candidate: String?) -> String {
        let normalized = candidate?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let normalized,
              QwenTTSCatalog.voices.contains(where: { $0.id == normalized }) else {
            return defaultVoiceIdentifier
        }
        return normalized
    }

    static func validatedSpeechRate(_ candidate: Float) -> Float {
        guard candidate.isFinite else { return defaultSpeechRate }
        return supportedSpeechRate.clamp(candidate)
    }
}

private extension ClosedRange where Bound == Float {
    func clamp(_ value: Float) -> Float {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
