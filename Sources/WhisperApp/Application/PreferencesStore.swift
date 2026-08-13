import Combine
import Foundation

/// Single source of truth for user-editable preferences.
///
/// Views observe this object directly and playback reads the same speech store,
/// so the value shown in Settings is always the value used for the next request.
@MainActor
final class PreferencesStore: ObservableObject {
    private enum Key {
        static let transcriptionLanguage = "transcriptionLanguage"
        static let didPresentSetup = "didPresentSetupV3"
    }

    @Published var transcriptionLanguage: TranscriptionLanguage {
        didSet {
            defaults.set(
                transcriptionLanguage.rawValue,
                forKey: Key.transcriptionLanguage
            )
        }
    }

    @Published var voiceIdentifier: String {
        didSet {
            speechSettings.voiceIdentifier = voiceIdentifier
        }
    }

    @Published var speechRate: Float {
        didSet {
            speechSettings.speechRate = speechRate
        }
    }

    let speechSettings: SpeechSettingsStore
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        speechSettings = SpeechSettingsStore(defaults: defaults)

        let rawLanguage = defaults.string(forKey: Key.transcriptionLanguage)
        transcriptionLanguage = rawLanguage
            .flatMap(TranscriptionLanguage.init(rawValue:)) ?? .automatic
        voiceIdentifier = speechSettings.voiceIdentifier
        speechRate = speechSettings.speechRate
    }

    var didPresentSetup: Bool {
        get { defaults.bool(forKey: Key.didPresentSetup) }
        set { defaults.set(newValue, forKey: Key.didPresentSetup) }
    }
}
