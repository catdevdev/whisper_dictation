import Foundation

public final class QwenTTSWorkerClient: @unchecked Sendable {
    private static let protocolVersion = 1
    private static let maximumProtocolLineBytes = 2 * 1_024 * 1_024
    private static let maximumAudioChunkBytes = 1_024 * 1_024
    private static let maximumTextCharacters = 20_000
    private static let maximumTextBytes = 100_000
    private static let maximumStyleCharacters = 1_000

    private let paths: QwenRuntimePaths
    private let explicitWorkerURL: URL?
    private let eventHandler: QwenTTSEventHandler
    private let stateQueue = DispatchQueue(
        label: "com.whisper.qwen-worker-state",
        qos: .userInitiated
    )
    private let eventQueue = DispatchQueue(
        label: "com.whisper.qwen-worker-events",
        qos: .userInitiated
    )

    private var process: Process?
    private var standardInput: Pipe?
    private var standardOutput: Pipe?
    private var standardError: Pipe?
    private var outputBuffer = Data()
    private var errorTail = Data()
    private var isStopping = false
    private var runtimeStatusHandler: QwenRuntimeStatusHandler?

    public init(
        paths: QwenRuntimePaths,
        workerURL: URL? = nil,
        eventHandler: @escaping QwenTTSEventHandler
    ) {
        self.paths = paths
        explicitWorkerURL = workerURL?.standardizedFileURL
        self.eventHandler = eventHandler
    }

    public func start(
        status: QwenRuntimeStatusHandler? = nil
    ) throws {
        if let status {
            eventQueue.async {
                status(.startingWorker)
            }
        }
        try stateQueue.sync {
            try startLocked(status: status)
        }
    }

    @discardableResult
    public func loadModel(
        modelID: String = QwenTTSCatalog.defaultModelID,
        requestID: String = UUID().uuidString
    ) throws -> String {
        try validateRequestID(requestID)
        try validateModelID(modelID)
        try send([
            "command": "load",
            "id": requestID,
            "modelID": modelID,
        ])
        return requestID
    }

    @discardableResult
    public func warmUp(
        voiceID: String = QwenTTSCatalog.defaultVoiceID,
        language: QwenTTSLanguage = .russian,
        modelID: String = QwenTTSCatalog.defaultModelID,
        requestID: String = UUID().uuidString
    ) throws -> String {
        try validateRequestID(requestID)
        try validateVoiceID(voiceID)
        try validateModelID(modelID)
        try send([
            "command": "warmup",
            "id": requestID,
            "voice": voiceID,
            "language": language.rawValue,
            "modelID": modelID,
        ])
        return requestID
    }

    @discardableResult
    public func synthesize(_ request: QwenTTSRequest) throws -> String {
        try validate(request)
        var payload: [String: Any] = [
            "command": "synthesize",
            "id": request.id,
            "text": request.text,
            "voice": request.voiceID,
            "language": request.language.rawValue,
            "streamingInterval": request.streamingInterval,
            "modelID": request.modelID,
        ]
        if let style = request.style?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !style.isEmpty {
            payload["style"] = style
        }
        try send(payload)
        return request.id
    }

    public func cancel(requestID: String) throws {
        try validateRequestID(requestID)
        try send([
            "command": "cancel",
            "id": UUID().uuidString,
            "targetID": requestID,
        ])
    }

    @discardableResult
    public func requestStatus(
        requestID: String = UUID().uuidString
    ) throws -> String {
        try validateRequestID(requestID)
        try send([
            "command": "status",
            "id": requestID,
        ])
        return requestID
    }

    public func shutdown() {
        stateQueue.async { [self] in
            guard let process, process.isRunning else {
                clearProcessLocked()
                return
            }
            do {
                try writeLocked([
                    "command": "shutdown",
                    "id": UUID().uuidString,
                ])
                isStopping = true
            } catch {
                isStopping = true
                process.terminate()
                return
            }

            stateQueue.asyncAfter(deadline: .now() + 2) { [self, weak process] in
                guard let process,
                      self.process === process,
                      process.isRunning else {
                    return
                }
                process.terminate()
            }
        }
    }

    private func startLocked(
        status: QwenRuntimeStatusHandler?
    ) throws {
        guard process?.isRunning != true else {
            throw QwenRuntimeError.workerAlreadyRunning
        }
        guard FileManager.default.isExecutableFile(
            atPath: paths.pythonExecutable.path
        ) else {
            throw QwenRuntimeError.invalidEnvironment
        }
        guard let workerURL = resolvedWorkerURL() else {
            throw QwenRuntimeError.bundledWorkerMissing
        }
        let workerValues = try? workerURL.resourceValues(
            forKeys: [.isRegularFileKey]
        )
        guard FileManager.default.fileExists(atPath: workerURL.path),
              workerValues?.isRegularFile == true else {
            throw QwenRuntimeError.bundledWorkerMissing
        }

        runtimeStatusHandler = status
        outputBuffer.removeAll(keepingCapacity: true)
        errorTail.removeAll(keepingCapacity: true)
        isStopping = false

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let workerProcess = Process()
        workerProcess.executableURL = paths.pythonExecutable
        workerProcess.arguments = ["-I", "-u", workerURL.path]
        workerProcess.currentDirectoryURL = paths.rootDirectory
        workerProcess.environment = workerEnvironment()
        workerProcess.standardInput = inputPipe
        workerProcess.standardOutput = outputPipe
        workerProcess.standardError = errorPipe

        inputPipe.fileHandleForWriting.writeabilityHandler = nil
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.stateQueue.async { [weak self] in
                self?.consumeOutputLocked(data)
            }
        }
        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.stateQueue.async { [weak self] in
                self?.consumeErrorLocked(data)
            }
        }
        workerProcess.terminationHandler = { [weak self, weak workerProcess] process in
            let status = process.terminationStatus
            self?.stateQueue.async { [weak self, weak workerProcess] in
                guard let self,
                      let workerProcess,
                      self.process === workerProcess else {
                    return
                }
                self.handleTerminationLocked(exitCode: status)
            }
        }

        standardInput = inputPipe
        standardOutput = outputPipe
        standardError = errorPipe
        process = workerProcess

        do {
            try workerProcess.run()
        } catch {
            clearProcessLocked()
            throw QwenRuntimeError.workerLaunchFailed(
                safeProcessErrorDescription(error)
            )
        }
    }

    private func resolvedWorkerURL() -> URL? {
        if let explicitWorkerURL {
            return explicitWorkerURL
        }
        return Bundle.main.url(
            forResource: "qwen_tts_worker",
            withExtension: "py"
        )
    }

    private func workerEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let unsafeKeys = [
            "DYLD_FRAMEWORK_PATH",
            "DYLD_INSERT_LIBRARIES",
            "DYLD_LIBRARY_PATH",
            "PYTHONHOME",
            "PYTHONPATH",
            "VIRTUAL_ENV",
        ]
        for key in unsafeKeys {
            environment.removeValue(forKey: key)
        }
        environment["HF_HOME"] = paths.modelCacheDirectory.path
        environment["HF_HUB_CACHE"] = paths.modelCacheDirectory
            .appendingPathComponent("hub", isDirectory: true).path
        environment["TRANSFORMERS_CACHE"] = paths.modelCacheDirectory
            .appendingPathComponent("transformers", isDirectory: true).path
        environment["PYTHONNOUSERSITE"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        return environment
    }

    private func send(_ payload: [String: Any]) throws {
        try stateQueue.sync {
            try writeLocked(payload)
        }
    }

    private func writeLocked(_ payload: [String: Any]) throws {
        guard let process,
              process.isRunning,
              let handle = standardInput?.fileHandleForWriting,
              !isStopping else {
            throw QwenRuntimeError.workerNotRunning
        }
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw QwenRuntimeError.invalidRequest(
                "The command could not be encoded as JSON."
            )
        }

        var data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.sortedKeys]
            )
        } catch {
            throw QwenRuntimeError.invalidRequest(
                "The command could not be encoded as JSON."
            )
        }
        guard data.count < Self.maximumProtocolLineBytes else {
            throw QwenRuntimeError.invalidRequest(
                "The encoded command exceeds the protocol limit."
            )
        }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw QwenRuntimeError.workerLaunchFailed(
                "The worker command pipe closed unexpectedly."
            )
        }
    }

    private func consumeOutputLocked(_ data: Data) {
        outputBuffer.append(data)
        guard outputBuffer.count <= Self.maximumProtocolLineBytes
                || outputBuffer.contains(0x0A) else {
            failProtocolLocked("A worker message exceeded the protocol limit.")
            return
        }

        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= Self.maximumProtocolLineBytes else {
                failProtocolLocked("A worker message exceeded the protocol limit.")
                return
            }
            do {
                let envelope = try JSONDecoder().decode(
                    WorkerEnvelope.self,
                    from: Data(line)
                )
                try deliver(envelope)
            } catch let error as QwenRuntimeError {
                failProtocolLocked(error.localizedDescription)
                return
            } catch {
                failProtocolLocked("A worker message was not valid NDJSON.")
                return
            }
        }
        if outputBuffer.count > Self.maximumProtocolLineBytes {
            failProtocolLocked("A worker message exceeded the protocol limit.")
        }
    }

    private func consumeErrorLocked(_ data: Data) {
        errorTail.append(data)
        let maximumBytes = 16_384
        if errorTail.count > maximumBytes {
            errorTail.removeFirst(errorTail.count - maximumBytes)
        }
    }

    private func deliver(_ envelope: WorkerEnvelope) throws {
        let event: QwenTTSEvent
        switch envelope.type {
        case "ready":
            guard let protocolVersion = envelope.protocolVersion,
                  protocolVersion == Self.protocolVersion,
                  let pythonVersion = envelope.pythonVersion,
                  let mlxAudioVersion = envelope.mlxAudioVersion,
                  let defaultModelID = envelope.defaultModelID,
                  let workerVoices = envelope.voices,
                  let workerLanguages = envelope.languages else {
                throw QwenRuntimeError.protocolViolation(
                    "The ready event is incomplete."
                )
            }
            let voices = workerVoices.map {
                QwenTTSVoice(
                    id: $0.id,
                    displayName: $0.displayName,
                    localeIdentifier: $0.locale
                )
            }
            let languages = workerLanguages.compactMap(QwenTTSLanguage.init(rawValue:))
            guard !voices.isEmpty,
                  languages.count == workerLanguages.count else {
                throw QwenRuntimeError.protocolViolation(
                    "The worker catalog is invalid."
                )
            }
            event = .ready(
                QwenTTSReady(
                    protocolVersion: protocolVersion,
                    pythonVersion: pythonVersion,
                    mlxAudioVersion: mlxAudioVersion,
                    defaultModelID: defaultModelID,
                    loadedModelID: envelope.modelID,
                    voices: voices,
                    languages: languages
                )
            )
            deliverRuntimeStatus(.ready)

        case "status":
            guard let state = envelope.state else {
                throw QwenRuntimeError.protocolViolation(
                    "The status event has no state."
                )
            }
            event = .status(
                QwenTTSWorkerStatus(
                    requestID: envelope.id,
                    state: state,
                    detail: envelope.detail,
                    modelID: envelope.modelID,
                    activeRequestID: envelope.activeID,
                    pendingCount: envelope.pendingCount
                )
            )

        case "audio":
            guard let requestID = envelope.id,
                  isValidRequestID(requestID),
                  let sequence = envelope.sequence,
                  sequence >= 0,
                  let sampleRate = envelope.sampleRate,
                  (8_000...192_000).contains(sampleRate),
                  let channels = envelope.channels,
                  channels == 1,
                  let rawFormat = envelope.format,
                  let format = QwenPCMAudioFormat(rawValue: rawFormat),
                  let encoded = envelope.base64Data,
                  encoded.utf8.count <= Self.maximumAudioChunkBytes * 2,
                  let audioData = Data(base64Encoded: encoded),
                  !audioData.isEmpty,
                  audioData.count <= Self.maximumAudioChunkBytes,
                  audioData.count.isMultiple(of: MemoryLayout<Float>.size * channels)
            else {
                throw QwenRuntimeError.protocolViolation(
                    "An audio event contains invalid PCM metadata."
                )
            }
            event = .audio(
                QwenPCMAudioChunk(
                    requestID: requestID,
                    sequence: sequence,
                    sampleRate: sampleRate,
                    channels: channels,
                    format: format,
                    data: audioData,
                    isFinal: envelope.isFinal ?? false
                )
            )

        case "completed":
            guard let requestID = envelope.id,
                  isValidRequestID(requestID),
                  let operation = envelope.operation,
                  !operation.isEmpty else {
                throw QwenRuntimeError.protocolViolation(
                    "The completion event is incomplete."
                )
            }
            event = .completed(
                QwenTTSCompletion(
                    requestID: requestID,
                    operation: operation,
                    modelID: envelope.modelID,
                    sampleRate: envelope.sampleRate,
                    chunkCount: envelope.chunks,
                    sampleCount: envelope.samples
                )
            )

        case "cancelled":
            guard let requestID = envelope.id,
                  isValidRequestID(requestID) else {
                throw QwenRuntimeError.protocolViolation(
                    "The cancellation event has no valid id."
                )
            }
            event = .cancelled(
                requestID: requestID,
                operation: envelope.operation
            )

        case "error":
            guard let code = envelope.code,
                  !code.isEmpty,
                  let message = envelope.message,
                  !message.isEmpty,
                  let recoverable = envelope.recoverable else {
                throw QwenRuntimeError.protocolViolation(
                    "The worker error event is incomplete."
                )
            }
            event = .failure(
                QwenTTSFailure(
                    requestID: envelope.id,
                    code: code,
                    message: message,
                    isRecoverable: recoverable
                )
            )

        default:
            throw QwenRuntimeError.protocolViolation(
                "Unknown worker event type."
            )
        }
        enqueue(event)
    }

    private func failProtocolLocked(_ message: String) {
        enqueue(
            .failure(
                QwenTTSFailure(
                    requestID: nil,
                    code: "protocol_error",
                    message: message,
                    isRecoverable: false
                )
            )
        )
        isStopping = true
        process?.terminate()
    }

    private func handleTerminationLocked(exitCode: Int32) {
        let stderr = String(decoding: errorTail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeError = stderr.isEmpty ? nil : String(stderr.suffix(8_000))
        clearProcessLocked()
        enqueue(.terminated(exitCode: exitCode, stderr: safeError))
    }

    private func clearProcessLocked() {
        standardOutput?.fileHandleForReading.readabilityHandler = nil
        standardError?.fileHandleForReading.readabilityHandler = nil
        standardInput?.fileHandleForWriting.writeabilityHandler = nil
        process?.terminationHandler = nil
        try? standardInput?.fileHandleForWriting.close()
        try? standardOutput?.fileHandleForReading.close()
        try? standardError?.fileHandleForReading.close()
        standardInput = nil
        standardOutput = nil
        standardError = nil
        process = nil
        outputBuffer.removeAll(keepingCapacity: false)
        errorTail.removeAll(keepingCapacity: false)
        runtimeStatusHandler = nil
        isStopping = false
    }

    private func deliverRuntimeStatus(_ status: QwenRuntimeStatus) {
        guard let runtimeStatusHandler else { return }
        eventQueue.async {
            runtimeStatusHandler(status)
        }
    }

    private func enqueue(_ event: QwenTTSEvent) {
        eventQueue.async { [eventHandler] in
            eventHandler(event)
        }
    }

    private func validate(_ request: QwenTTSRequest) throws {
        try validateRequestID(request.id)
        try validateVoiceID(request.voiceID)
        try validateModelID(request.modelID)
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QwenRuntimeError.invalidRequest("Text must not be empty.")
        }
        guard request.text.count <= Self.maximumTextCharacters,
              request.text.utf8.count <= Self.maximumTextBytes else {
            throw QwenRuntimeError.invalidRequest(
                "Text exceeds the local synthesis limit."
            )
        }
        if let style = request.style,
           style.count > Self.maximumStyleCharacters {
            throw QwenRuntimeError.invalidRequest(
                "Style exceeds \(Self.maximumStyleCharacters) characters."
            )
        }
        guard request.streamingInterval.isFinite,
              (0.16...2.0).contains(request.streamingInterval) else {
            throw QwenRuntimeError.invalidRequest(
                "Streaming interval must be between 0.16 and 2 seconds."
            )
        }
    }

    private func validateRequestID(_ requestID: String) throws {
        guard isValidRequestID(requestID) else {
            throw QwenRuntimeError.invalidRequest(
                "Request ids must be 1-128 safe ASCII characters."
            )
        }
    }

    private func isValidRequestID(_ requestID: String) -> Bool {
        let bytes = Array(requestID.utf8)
        guard (1...128).contains(bytes.count),
              let first = bytes.first,
              isASCIIAlphaNumeric(first) else {
            return false
        }
        return bytes.allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 0x2E || $0 == 0x3A
                || $0 == 0x5F || $0 == 0x2D
        }
    }

    private func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
    }

    private func validateVoiceID(_ voiceID: String) throws {
        guard QwenTTSCatalog.voices.contains(where: { $0.id == voiceID }) else {
            throw QwenRuntimeError.invalidRequest("The selected voice is unsupported.")
        }
    }

    private func validateModelID(_ modelID: String) throws {
        let pattern = #"^mlx-community/Qwen3-TTS-12Hz-(0\.6B|1\.7B)-CustomVoice-(bf16|8bit|6bit|4bit)$"#
        guard modelID.range(
            of: pattern,
            options: .regularExpression
        ).map({ $0 == modelID.startIndex..<modelID.endIndex }) == true else {
            throw QwenRuntimeError.invalidRequest(
                "The model must be an MLX Qwen3-TTS CustomVoice release."
            )
        }
    }

    private func safeProcessErrorDescription(_ error: Error) -> String {
        if let cocoaError = error as? CocoaError {
            return cocoaError.localizedDescription
        }
        return "The process could not be launched."
    }
}

private struct WorkerEnvelope: Decodable {
    let type: String
    let id: String?
    let protocolVersion: Int?
    let pythonVersion: String?
    let mlxAudioVersion: String?
    let defaultModelID: String?
    let modelID: String?
    let voices: [WorkerVoice]?
    let languages: [String]?
    let state: String?
    let detail: String?
    let activeID: String?
    let pendingCount: Int?
    let sequence: Int?
    let sampleRate: Int?
    let channels: Int?
    let format: String?
    let base64Data: String?
    let isFinal: Bool?
    let operation: String?
    let chunks: Int?
    let samples: Int?
    let code: String?
    let message: String?
    let recoverable: Bool?

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case protocolVersion
        case pythonVersion
        case mlxAudioVersion
        case defaultModelID
        case modelID
        case voices
        case languages
        case state
        case detail
        case activeID
        case pendingCount
        case sequence
        case sampleRate
        case channels
        case format
        case base64Data = "data"
        case isFinal
        case operation
        case chunks
        case samples
        case code
        case message
        case recoverable
    }
}

private struct WorkerVoice: Decodable {
    let id: String
    let displayName: String
    let locale: String
}
