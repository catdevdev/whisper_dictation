import Foundation

enum DictationPhase: Equatable, Sendable {
    case idle
    case armed
    case holding(progress: Double)
    case recording(level: Double)
    case transcribing
    case success
    case failure(message: String)

    var isBusy: Bool {
        switch self {
        case .holding, .recording, .transcribing:
            true
        case .idle, .armed, .success, .failure:
            false
        }
    }

    var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    var isHolding: Bool {
        if case .holding = self { return true }
        return false
    }

    func clearingFailure(matching message: String) -> DictationPhase {
        guard case let .failure(currentMessage) = self,
              currentMessage == message else {
            return self
        }
        return .idle
    }
}

enum ReadingPhase: Equatable, Sendable {
    case idle
    case preparing
    case speaking
    case paused

    var isActive: Bool {
        self != .idle
    }
}

struct SpeechVoiceOption: Identifiable, Equatable, Sendable {
    let identifier: String
    let name: String
    let language: String
    let quality: String

    var id: String { identifier }

    var title: String {
        [name, language, quality]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

enum AccessState: Equatable, Sendable {
    case checking
    case allowed
    case denied
}

enum HotkeyStatus: Equatable, Sendable {
    case checking
    case active
    case needsAccessibility
    case unavailable(message: String)

    var isActive: Bool {
        self == .active
    }
}

enum LoginItemStatus: Equatable, Sendable {
    case disabled
    case enabled
    case requiresApproval

    var isEnabled: Bool {
        self == .enabled
    }
}

struct AppNotice: Identifiable, Equatable, Sendable {
    enum Tone: Equatable, Sendable {
        case success
        case information
        case failure
    }

    let id: UUID
    let tone: Tone
    let message: String

    init(
        id: UUID = UUID(),
        tone: Tone,
        message: String
    ) {
        self.id = id
        self.tone = tone
        self.message = message
    }
}

enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic = "auto"
    case russian = "ru"
    case ukrainian = "uk"
    case english = "en"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Определять автоматически"
        case .russian: "Русский"
        case .ukrainian: "Украинский"
        case .english: "Английский"
        }
    }

    var requestValue: String? {
        self == .automatic ? nil : rawValue
    }
}

struct AppReadiness: Equatable, Sendable {
    var microphone: AccessState = .checking
    var accessibility: AccessState = .checking
    var hasAPIKey = false

    var canDictate: Bool {
        microphone == .allowed
            && accessibility == .allowed
            && hasAPIKey
    }
}

enum DictationAdmissionPolicy {
    static func canBegin(
        hasActiveSession: Bool,
        hasRecoverableTranscript _: Bool
    ) -> Bool {
        !hasActiveSession
    }
}
