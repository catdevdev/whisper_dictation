import Foundation

public struct QwenTTSVoice: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    public let localeIdentifier: String

    public init(id: String, displayName: String, localeIdentifier: String) {
        self.id = id
        self.displayName = displayName
        self.localeIdentifier = localeIdentifier
    }
}

public enum QwenTTSLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic = "Auto"
    case chinese = "Chinese"
    case english = "English"
    case japanese = "Japanese"
    case korean = "Korean"
    case german = "German"
    case french = "French"
    case russian = "Russian"
    case portuguese = "Portuguese"
    case spanish = "Spanish"
    case italian = "Italian"

    public var id: String { rawValue }
}

public enum QwenTTSCatalog {
    public static let defaultModelID =
        "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16"
    public static let mlxAudioVersion = "0.4.6"
    public static let defaultVoiceID = "Serena"
    public static let defaultStreamingInterval: TimeInterval = 0.32

    public static let voices: [QwenTTSVoice] = [
        QwenTTSVoice(id: "Vivian", displayName: "Vivian", localeIdentifier: "zh-CN"),
        QwenTTSVoice(id: "Serena", displayName: "Serena", localeIdentifier: "zh-CN"),
        QwenTTSVoice(id: "Uncle_Fu", displayName: "Uncle Fu", localeIdentifier: "zh-CN"),
        QwenTTSVoice(id: "Dylan", displayName: "Dylan", localeIdentifier: "zh-CN"),
        QwenTTSVoice(id: "Eric", displayName: "Eric", localeIdentifier: "zh-CN"),
        QwenTTSVoice(id: "Ryan", displayName: "Ryan", localeIdentifier: "en-US"),
        QwenTTSVoice(id: "Aiden", displayName: "Aiden", localeIdentifier: "en-US"),
        QwenTTSVoice(id: "Ono_Anna", displayName: "Ono Anna", localeIdentifier: "ja-JP"),
        QwenTTSVoice(id: "Sohee", displayName: "Sohee", localeIdentifier: "ko-KR"),
    ]

    public static let languages = QwenTTSLanguage.allCases
}

public struct QwenTTSRequest: Equatable, Sendable {
    public let id: String
    public let text: String
    public let voiceID: String
    public let language: QwenTTSLanguage
    public let style: String?
    public let streamingInterval: TimeInterval
    public let modelID: String

    public init(
        id: String = UUID().uuidString,
        text: String,
        voiceID: String = QwenTTSCatalog.defaultVoiceID,
        language: QwenTTSLanguage = .automatic,
        style: String? = nil,
        streamingInterval: TimeInterval = QwenTTSCatalog.defaultStreamingInterval,
        modelID: String = QwenTTSCatalog.defaultModelID
    ) {
        self.id = id
        self.text = text
        self.voiceID = voiceID
        self.language = language
        self.style = style
        self.streamingInterval = streamingInterval
        self.modelID = modelID
    }
}

public enum QwenRuntimeStatus: Equatable, Sendable {
    case checkingRuntime
    case runtimeAvailable
    case locatingUV
    case creatingEnvironment
    case installingDependencies
    case startingWorker
    case ready
}

public typealias QwenRuntimeStatusHandler =
    @Sendable (QwenRuntimeStatus) -> Void

public struct QwenTTSReady: Equatable, Sendable {
    public let protocolVersion: Int
    public let pythonVersion: String
    public let mlxAudioVersion: String
    public let defaultModelID: String
    public let loadedModelID: String?
    public let voices: [QwenTTSVoice]
    public let languages: [QwenTTSLanguage]

    public init(
        protocolVersion: Int,
        pythonVersion: String,
        mlxAudioVersion: String,
        defaultModelID: String,
        loadedModelID: String?,
        voices: [QwenTTSVoice],
        languages: [QwenTTSLanguage]
    ) {
        self.protocolVersion = protocolVersion
        self.pythonVersion = pythonVersion
        self.mlxAudioVersion = mlxAudioVersion
        self.defaultModelID = defaultModelID
        self.loadedModelID = loadedModelID
        self.voices = voices
        self.languages = languages
    }
}

public struct QwenTTSWorkerStatus: Equatable, Sendable {
    public let requestID: String?
    public let state: String
    public let detail: String?
    public let modelID: String?
    public let activeRequestID: String?
    public let pendingCount: Int?

    public init(
        requestID: String?,
        state: String,
        detail: String?,
        modelID: String?,
        activeRequestID: String?,
        pendingCount: Int?
    ) {
        self.requestID = requestID
        self.state = state
        self.detail = detail
        self.modelID = modelID
        self.activeRequestID = activeRequestID
        self.pendingCount = pendingCount
    }
}

public enum QwenPCMAudioFormat: String, Sendable {
    case float32LittleEndian = "f32le"
}

public struct QwenPCMAudioChunk: Equatable, Sendable {
    public let requestID: String
    public let sequence: Int
    public let sampleRate: Int
    public let channels: Int
    public let format: QwenPCMAudioFormat
    public let data: Data
    public let isFinal: Bool

    public init(
        requestID: String,
        sequence: Int,
        sampleRate: Int,
        channels: Int,
        format: QwenPCMAudioFormat,
        data: Data,
        isFinal: Bool
    ) {
        self.requestID = requestID
        self.sequence = sequence
        self.sampleRate = sampleRate
        self.channels = channels
        self.format = format
        self.data = data
        self.isFinal = isFinal
    }
}

public struct QwenTTSCompletion: Equatable, Sendable {
    public let requestID: String
    public let operation: String
    public let modelID: String?
    public let sampleRate: Int?
    public let chunkCount: Int?
    public let sampleCount: Int?

    public init(
        requestID: String,
        operation: String,
        modelID: String?,
        sampleRate: Int?,
        chunkCount: Int?,
        sampleCount: Int?
    ) {
        self.requestID = requestID
        self.operation = operation
        self.modelID = modelID
        self.sampleRate = sampleRate
        self.chunkCount = chunkCount
        self.sampleCount = sampleCount
    }
}

public struct QwenTTSFailure: Error, Equatable, Sendable {
    public let requestID: String?
    public let code: String
    public let message: String
    public let isRecoverable: Bool

    public init(
        requestID: String?,
        code: String,
        message: String,
        isRecoverable: Bool
    ) {
        self.requestID = requestID
        self.code = code
        self.message = message
        self.isRecoverable = isRecoverable
    }
}

public enum QwenTTSEvent: Equatable, Sendable {
    case ready(QwenTTSReady)
    case status(QwenTTSWorkerStatus)
    case audio(QwenPCMAudioChunk)
    case completed(QwenTTSCompletion)
    case cancelled(requestID: String, operation: String?)
    case failure(QwenTTSFailure)
    case terminated(exitCode: Int32, stderr: String?)
}

public typealias QwenTTSEventHandler =
    @Sendable (QwenTTSEvent) -> Void
