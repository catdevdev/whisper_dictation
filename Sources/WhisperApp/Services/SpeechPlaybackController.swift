import AVFoundation
import NaturalLanguage
import WhisperCore

/// Streams Qwen3-TTS PCM into a native macOS audio graph while preserving the
/// existing playback contract used by the menu UI and the Chrome bridge.
@MainActor
final class SpeechPlaybackController {
    enum State: String {
        case idle
        case buffering
        case speaking
        case paused
    }

    struct Request {
        let sessionID: String
        let requestID: String?
        let text: String
        let language: String?
        /// Retained for protocol compatibility. App settings are canonical.
        let rate: Float?
        /// Retained for protocol compatibility. App settings are canonical.
        let voiceIdentifier: String?
    }

    private struct SpeechUnit {
        let text: String
        let utf16Offset: Int
        let utf16Length: Int
        var workerRequestID: String?
        var expectedSequence = 0
        var audioStartSample: Int64?
        var generatedSamples: Int64 = 0
        var finalSamples: Int64?
        var generationComplete = false
    }

    private let settings: SpeechSettingsStore
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()

    private var worker: QwenTTSWorkerClient?
    private var runtimeTask: Task<Void, Never>?
    private var runtimePreparationTask: Task<QwenRuntimePaths, Error>?
    private var boundaryTask: Task<Void, Never>?
    private var sessionToken: UUID?
    private var request: Request?
    private var sessionLanguage: QwenTTSLanguage = .automatic
    private var sessionVoiceID = SpeechSettingsStore.defaultVoiceIdentifier
    private var sentenceSegments: [SentenceSegment] = []
    private var wordRanges: [NSRange] = []
    private var units: [SpeechUnit] = []
    private var nextUnitToGenerate = 0
    private var activeGenerationID: String?
    private var unitByWorkerRequestID: [String: Int] = [:]
    private var totalScheduledSamples: Int64 = 0
    private var pendingScheduledBuffers = 0
    private var sampleRate: Int?
    private var engineIsConfigured = false
    private var desiredPaused = false
    private var frozenSamplePosition: Int64?
    private var lastBoundaryRange: NSRange?
    private(set) var currentUTF16Offset = 0
    private(set) var activeVoiceName: String?
    private(set) var runtimeStatus: QwenRuntimeStatus?

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChanged?(state, request?.sessionID)
        }
    }

    var currentSessionID: String? { request?.sessionID }

    var onStateChanged: ((State, String?) -> Void)?
    var onBoundary: ((_ sessionID: String, _ offset: Int, _ length: Int) -> Void)?
    var onEnded: ((_ sessionID: String) -> Void)?
    var onError: ((_ sessionID: String?, _ error: Error) -> Void)?
    var onVoiceChanged: ((String?) -> Void)?
    var onRuntimeStatusChanged: ((QwenRuntimeStatus) -> Void)?

    var textUTF16Length: Int {
        guard let request else { return 0 }
        return (request.text as NSString).length
    }

    var progress: Double {
        let length = textUTF16Length
        guard length > 0 else { return 0 }
        return min(max(Double(currentUTF16Offset) / Double(length), 0), 1)
    }

    init(settings: SpeechSettingsStore) {
        self.settings = settings
        audioEngine.attach(playerNode)
        audioEngine.attach(timePitch)
    }

    func speak(_ newRequest: Request) {
        stop(notify: false)

        guard !newRequest.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            onError?(newRequest.sessionID, PlaybackError.emptyText)
            return
        }
        guard (newRequest.text as NSString).length <= 200_000 else {
            onError?(newRequest.sessionID, PlaybackError.textTooLong)
            return
        }

        let token = UUID()
        request = newRequest
        sessionLanguage = SpeechLanguageResolver.resolve(
            explicitLanguage: newRequest.language,
            text: newRequest.text
        )
        sessionToken = token
        sentenceSegments = SentenceChunker.segments(in: newRequest.text)
        wordRanges = Self.wordRanges(in: newRequest.text)
        units = Self.speechUnits(
            in: newRequest.text,
            sentenceSegments: sentenceSegments,
            startingAtUTF16Offset: 0
        )
        currentUTF16Offset = 0
        desiredPaused = false
        configureVoiceAndRate()
        state = .buffering
        startBoundaryUpdates(for: token)
        prepareWorkerIfNeeded(for: token)
    }

    func pause() {
        guard request != nil, state != .idle else { return }
        updateBoundaryFromPlayer()
        frozenSamplePosition = liveRenderedSamplePosition()
        desiredPaused = true
        if playerNode.isPlaying {
            playerNode.pause()
        }
        state = .paused
    }

    func resume() {
        guard request != nil, desiredPaused else { return }
        desiredPaused = false
        frozenSamplePosition = nil
        if pendingScheduledBuffers > 0 {
            do {
                try startAudioEngineIfNeeded()
                playerNode.play()
                state = .speaking
            } catch {
                failPlayback(error)
            }
        } else {
            state = .buffering
        }
        if let token = sessionToken {
            startNextGeneration(for: token)
        }
    }

    func togglePause() {
        state == .paused ? resume() : pause()
    }

    /// Persists the canonical app rate and applies it to the live audio graph.
    /// `AVAudioUnitTimePitch.rate` is realtime-adjustable, so active playback
    /// changes speed without rebuilding or rescheduling the pipeline.
    func applySpeechRate(_ rate: Float) {
        settings.speechRate = rate
        timePitch.rate = effectiveRate
    }

    func stop() {
        stop(notify: true)
    }

    func skipTokens(_ amount: Int) {
        guard request != nil, !wordRanges.isEmpty, amount != 0 else { return }
        let clampedAmount = min(max(amount, -100), 100)
        let currentIndex = wordRanges.lastIndex {
            $0.location <= currentUTF16Offset
        } ?? 0
        let targetIndex = min(
            max(currentIndex + clampedAmount, 0),
            wordRanges.count - 1
        )
        restart(atUTF16Offset: wordRanges[targetIndex].location)
    }

    func seek(toUTF16Offset requestedOffset: Int) {
        guard let request, !wordRanges.isEmpty else { return }
        let textLength = (request.text as NSString).length
        let clamped = min(max(requestedOffset, 0), textLength)
        if clamped == textLength {
            restart(atUTF16Offset: textLength)
            return
        }
        let tokenOffset = wordRanges.first {
            NSMaxRange($0) > clamped
        }?.location ?? textLength
        restart(atUTF16Offset: tokenOffset)
    }

    func previousSentence() {
        navigateSentence(delta: -1)
    }

    func nextSentence() {
        navigateSentence(delta: 1)
    }

    private func navigateSentence(delta: Int) {
        guard !sentenceSegments.isEmpty else { return }
        let currentIndex = sentenceSegments.lastIndex {
            $0.utf16Offset <= currentUTF16Offset
        } ?? 0
        let target = min(max(currentIndex + delta, 0), sentenceSegments.count - 1)
        restart(atUTF16Offset: sentenceSegments[target].utf16Offset)
    }

    private func restart(atUTF16Offset requestedOffset: Int) {
        guard let request else { return }
        let textLength = (request.text as NSString).length
        let offset = min(max(requestedOffset, 0), textLength)
        if offset >= textLength {
            finishNormally()
            return
        }

        let preservePaused = desiredPaused || state == .paused
        cancelActiveGeneration()
        resetAudioPipeline()

        let token = UUID()
        sessionToken = token
        units = Self.speechUnits(
            in: request.text,
            sentenceSegments: sentenceSegments,
            startingAtUTF16Offset: offset
        )
        nextUnitToGenerate = 0
        activeGenerationID = nil
        unitByWorkerRequestID.removeAll()
        currentUTF16Offset = offset
        lastBoundaryRange = nil
        desiredPaused = preservePaused
        state = preservePaused ? .paused : .buffering
        onBoundary?(request.sessionID, offset, 0)
        startBoundaryUpdates(for: token)
        prepareWorkerIfNeeded(for: token)
    }

    private func prepareWorkerIfNeeded(for token: UUID) {
        if worker != nil {
            startNextGeneration(for: token)
            return
        }

        runtimeTask?.cancel()
        let preparationTask: Task<QwenRuntimePaths, Error>
        do {
            if let existing = runtimePreparationTask {
                preparationTask = existing
            } else {
                let bootstrapper = try QwenRuntimeBootstrapper()
                let statusHandler = runtimeStatusHandler()
                let created = Task {
                    try await bootstrapper.prepare(status: statusHandler)
                }
                runtimePreparationTask = created
                preparationTask = created
            }
        } catch {
            failPlayback(error)
            return
        }

        runtimeTask = Task { [weak self, preparationTask] in
            guard let self else { return }
            do {
                let paths = try await preparationTask.value
                try Task.checkCancellation()
                guard sessionToken == token, request != nil else { return }

                let client = QwenTTSWorkerClient(
                    paths: paths,
                    eventHandler: { [weak self] event in
                        DispatchQueue.main.async { [weak self] in
                            self?.receive(event)
                        }
                    }
                )
                try client.start(status: runtimeStatusHandler())
                guard sessionToken == token, request != nil else {
                    client.shutdown()
                    return
                }
                worker = client
                runtimeTask = nil
                startNextGeneration(for: token)
            } catch is CancellationError {
                return
            } catch {
                runtimePreparationTask = nil
                guard sessionToken == token else { return }
                runtimeTask = nil
                failPlayback(error)
            }
        }
    }

    private func startNextGeneration(for token: UUID) {
        guard sessionToken == token,
              activeGenerationID == nil,
              nextUnitToGenerate < units.count,
              request != nil,
              let worker else {
            finishIfPossible()
            return
        }
        guard canGenerateNextUnit else { return }

        let unitIndex = nextUnitToGenerate
        let generationID = "tts-\(UUID().uuidString.lowercased())"
        units[unitIndex].workerRequestID = generationID
        activeGenerationID = generationID
        unitByWorkerRequestID[generationID] = unitIndex

        let qwenRequest = QwenTTSRequest(
            id: generationID,
            text: units[unitIndex].text,
            voiceID: sessionVoiceID,
            language: sessionLanguage,
            style: Self.styleInstruction(for: sessionLanguage),
            streamingInterval: QwenTTSCatalog.defaultStreamingInterval
        )

        do {
            try worker.synthesize(qwenRequest)
            nextUnitToGenerate += 1
        } catch {
            activeGenerationID = nil
            unitByWorkerRequestID[generationID] = nil
            failPlayback(error)
        }
    }

    private func receive(_ event: QwenTTSEvent) {
        guard request != nil else {
            if case .terminated = event {
                worker = nil
            }
            return
        }

        switch event {
        case .ready:
            publishRuntimeStatus(.ready)

        case .status:
            break

        case let .audio(chunk):
            receiveAudio(chunk)

        case let .completed(completion):
            receiveCompletion(completion)

        case let .cancelled(requestID, _):
            if activeGenerationID == requestID {
                activeGenerationID = nil
            }

        case let .failure(failure):
            guard failure.requestID == nil
                    || unitByWorkerRequestID[failure.requestID!] != nil else {
                return
            }
            failPlayback(
                PlaybackError.generationFailed(failure.message)
            )

        case let .terminated(exitCode, stderr):
            worker = nil
            let detail = stderr?.isEmpty == false
                ? stderr!
                : "Qwen worker exited with code \(exitCode)."
            failPlayback(PlaybackError.generationFailed(detail))
        }
    }

    private func receiveAudio(_ chunk: QwenPCMAudioChunk) {
        guard let token = sessionToken,
              let unitIndex = unitByWorkerRequestID[chunk.requestID],
              units.indices.contains(unitIndex),
              activeGenerationID == chunk.requestID else {
            return
        }
        guard chunk.sequence == units[unitIndex].expectedSequence else {
            failPlayback(PlaybackError.invalidAudio)
            return
        }
        units[unitIndex].expectedSequence += 1

        do {
            let buffer = try makePCMBuffer(from: chunk)
            let frames = Int64(buffer.frameLength)
            guard frames > 0 else { return }

            try configureAudioEngine(sampleRate: chunk.sampleRate)
            if units[unitIndex].audioStartSample == nil {
                units[unitIndex].audioStartSample = totalScheduledSamples
            }
            units[unitIndex].generatedSamples += frames
            totalScheduledSamples += frames
            pendingScheduledBuffers += 1

            playerNode.scheduleBuffer(
                buffer,
                completionCallbackType: .dataPlayedBack
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduledBufferDidPlay(for: token)
                }
            }

            if !desiredPaused {
                try startAudioEngineIfNeeded()
                if !playerNode.isPlaying {
                    playerNode.play()
                }
                state = .speaking
            }
            updateBoundaryFromPlayer()
        } catch {
            failPlayback(error)
        }
    }

    private func receiveCompletion(_ completion: QwenTTSCompletion) {
        guard completion.operation == "synthesize",
              let unitIndex = unitByWorkerRequestID[completion.requestID],
              units.indices.contains(unitIndex) else {
            return
        }

        guard units[unitIndex].generatedSamples > 0 else {
            failPlayback(PlaybackError.invalidAudio)
            return
        }

        units[unitIndex].generationComplete = true
        units[unitIndex].finalSamples = units[unitIndex].generatedSamples
        unitByWorkerRequestID[completion.requestID] = nil
        if activeGenerationID == completion.requestID {
            activeGenerationID = nil
        }

        guard let token = sessionToken else { return }
        startNextGeneration(for: token)
        finishIfPossible()
    }

    private func scheduledBufferDidPlay(for token: UUID) {
        guard sessionToken == token else { return }
        pendingScheduledBuffers = max(0, pendingScheduledBuffers - 1)
        updateBoundaryFromPlayer()
        startNextGeneration(for: token)
        finishIfPossible()
    }

    private func configureAudioEngine(sampleRate newSampleRate: Int) throws {
        guard newSampleRate > 0 else {
            throw PlaybackError.invalidAudio
        }
        if let sampleRate, sampleRate != newSampleRate {
            throw PlaybackError.invalidAudio
        }
        guard !engineIsConfigured else { return }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(newSampleRate),
            channels: 1
        ) else {
            throw PlaybackError.invalidAudio
        }

        sampleRate = newSampleRate
        audioEngine.connect(playerNode, to: timePitch, format: format)
        audioEngine.connect(timePitch, to: audioEngine.mainMixerNode, format: format)
        timePitch.rate = effectiveRate
        audioEngine.prepare()
        engineIsConfigured = true
    }

    private func startAudioEngineIfNeeded() throws {
        guard engineIsConfigured else { return }
        if !audioEngine.isRunning {
            try audioEngine.start()
        }
    }

    private func makePCMBuffer(
        from chunk: QwenPCMAudioChunk
    ) throws -> AVAudioPCMBuffer {
        guard chunk.channels == 1,
              chunk.format == .float32LittleEndian,
              chunk.data.count.isMultiple(of: MemoryLayout<Float>.size),
              let format = AVAudioFormat(
                  standardFormatWithSampleRate: Double(chunk.sampleRate),
                  channels: 1
              ) else {
            throw PlaybackError.invalidAudio
        }

        let frameCount = chunk.data.count / MemoryLayout<Float>.size
        guard frameCount > 0,
              frameCount <= Int(AVAudioFrameCount.max),
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let destination = buffer.floatChannelData?.pointee else {
            throw PlaybackError.invalidAudio
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        chunk.data.withUnsafeBytes { rawBuffer in
            guard let source = rawBuffer.baseAddress else { return }
            destination.update(
                from: source.assumingMemoryBound(to: Float.self),
                count: frameCount
            )
        }
        return buffer
    }

    private var effectiveRate: Float {
        min(max(settings.speechRate, 0.5), 2)
    }

    private func configureVoiceAndRate() {
        timePitch.rate = effectiveRate
        let voiceID = settings.voiceIdentifier
        sessionVoiceID = voiceID
        activeVoiceName = QwenTTSCatalog.voices.first {
            $0.id == voiceID
        }?.displayName ?? voiceID
        onVoiceChanged?(activeVoiceName)
    }

    private func runtimeStatusHandler() -> QwenRuntimeStatusHandler {
        { [weak self] status in
            DispatchQueue.main.async { [weak self] in
                self?.publishRuntimeStatus(status)
            }
        }
    }

    private func publishRuntimeStatus(_ status: QwenRuntimeStatus) {
        guard runtimeStatus != status else { return }
        runtimeStatus = status
        onRuntimeStatusChanged?(status)
    }

    private func startBoundaryUpdates(for token: UUID) {
        boundaryTask?.cancel()
        boundaryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard !Task.isCancelled,
                      let self,
                      sessionToken == token,
                      request != nil else {
                    return
                }
                updateBoundaryFromPlayer()
            }
        }
    }

    private func updateBoundaryFromPlayer() {
        guard let request,
              let samplePosition = renderedSamplePosition(),
              let unitIndex = unitIndex(atGlobalSample: samplePosition),
              units.indices.contains(unitIndex) else {
            return
        }

        let unit = units[unitIndex]
        guard let start = unit.audioStartSample else { return }
        let localSample = max(0, samplePosition - start)
        let estimatedSamples = unit.finalSamples
            ?? max(
                Self.estimatedSamples(
                    for: unit.text,
                    sampleRate: sampleRate ?? 24_000
                ),
                unit.generatedSamples + Int64((sampleRate ?? 24_000) / 3)
            )
        let ratio = min(
            max(Double(localSample) / Double(max(estimatedSamples, 1)), 0),
            1
        )
        let targetOffset = unit.utf16Offset
            + Int((Double(unit.utf16Length) * ratio).rounded(.down))

        let unitEnd = unit.utf16Offset + unit.utf16Length
        let unitWords = wordRanges.filter {
            $0.location >= unit.utf16Offset && $0.location < unitEnd
        }
        let boundary = unitWords.last {
            $0.location <= targetOffset
        } ?? unitWords.first ?? NSRange(
            location: min(targetOffset, max(unitEnd - 1, unit.utf16Offset)),
            length: unit.utf16Length > 0 ? 1 : 0
        )

        guard boundary != lastBoundaryRange else { return }
        lastBoundaryRange = boundary
        currentUTF16Offset = boundary.location
        onBoundary?(request.sessionID, boundary.location, boundary.length)
    }

    private func renderedSamplePosition() -> Int64? {
        if desiredPaused, let frozenSamplePosition {
            return frozenSamplePosition
        }
        return liveRenderedSamplePosition()
    }

    private func liveRenderedSamplePosition() -> Int64? {
        guard let renderTime = playerNode.lastRenderTime,
              let playerTime = playerNode.playerTime(forNodeTime: renderTime) else {
            return totalScheduledSamples > 0 ? 0 : nil
        }
        return max(0, playerTime.sampleTime)
    }

    private var canGenerateNextUnit: Bool {
        guard !desiredPaused else { return false }
        guard pendingScheduledBuffers > 0 else { return true }
        guard let sampleRate else { return true }
        let rendered = liveRenderedSamplePosition() ?? 0
        let bufferedSamples = max(0, totalScheduledSamples - rendered)
        let maximumBufferedSamples = Int64(sampleRate) * 45
        return bufferedSamples < maximumBufferedSamples
    }

    private func unitIndex(atGlobalSample sample: Int64) -> Int? {
        var candidate: Int?
        for index in units.indices {
            guard let start = units[index].audioStartSample,
                  start <= sample else {
                continue
            }
            candidate = index
            if let length = units[index].finalSamples,
               sample < start + length {
                return index
            }
        }
        return candidate
    }

    private func finishIfPossible() {
        guard request != nil,
              activeGenerationID == nil,
              nextUnitToGenerate >= units.count,
              units.allSatisfy(\.generationComplete),
              pendingScheduledBuffers == 0 else {
            return
        }
        finishNormally()
    }

    private func finishNormally() {
        guard let sessionID = request?.sessionID else { return }
        boundaryTask?.cancel()
        boundaryTask = nil
        cancelActiveGeneration()
        resetAudioPipeline()
        state = .idle
        clearSessionState()
        onEnded?(sessionID)
    }

    private func failPlayback(_ error: Error) {
        let sessionID = request?.sessionID
        stop(notify: false)
        onError?(sessionID, error)
    }

    private func stop(notify: Bool) {
        runtimeTask?.cancel()
        runtimeTask = nil
        boundaryTask?.cancel()
        boundaryTask = nil
        cancelActiveGeneration()
        resetAudioPipeline()
        clearSessionState()
        if notify || state != .idle {
            state = .idle
        }
    }

    private func cancelActiveGeneration() {
        guard let activeGenerationID else { return }
        try? worker?.cancel(requestID: activeGenerationID)
        self.activeGenerationID = nil
    }

    private func resetAudioPipeline() {
        playerNode.stop()
        audioEngine.stop()
        if engineIsConfigured {
            audioEngine.disconnectNodeOutput(playerNode)
            audioEngine.disconnectNodeOutput(timePitch)
        }
        engineIsConfigured = false
        sampleRate = nil
        totalScheduledSamples = 0
        pendingScheduledBuffers = 0
        frozenSamplePosition = nil
    }

    private func clearSessionState() {
        request = nil
        sessionLanguage = .automatic
        sessionVoiceID = SpeechSettingsStore.defaultVoiceIdentifier
        sessionToken = nil
        sentenceSegments = []
        wordRanges = []
        units = []
        nextUnitToGenerate = 0
        activeGenerationID = nil
        unitByWorkerRequestID.removeAll()
        desiredPaused = false
        frozenSamplePosition = nil
        lastBoundaryRange = nil
        currentUTF16Offset = 0
        activeVoiceName = nil
        onVoiceChanged?(nil)
    }

    private static func wordRanges(in text: String) -> [NSRange] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var ranges: [NSRange] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) {
            range,
            _ in
            ranges.append(NSRange(range, in: text))
            return true
        }
        return ranges
    }

    private static func speechUnits(
        in text: String,
        sentenceSegments: [SentenceSegment],
        startingAtUTF16Offset requestedOffset: Int
    ) -> [SpeechUnit] {
        let nsText = text as NSString
        let offset = min(max(requestedOffset, 0), nsText.length)
        guard offset < nsText.length else { return [] }

        let maximumUnitLength = 1_200
        var sourceRanges: [NSRange] = []
        var groupStart: Int?
        var groupEnd = offset

        func flushGroup() {
            guard let start = groupStart, groupEnd > start else { return }
            sourceRanges.append(
                NSRange(location: start, length: groupEnd - start)
            )
            groupStart = nil
        }

        for sentence in sentenceSegments {
            let sentenceEnd = sentence.utf16Offset + sentence.utf16Length
            guard sentenceEnd > offset else { continue }
            let start = max(sentence.utf16Offset, offset)

            if sentenceEnd - start > maximumUnitLength {
                flushGroup()
                sourceRanges.append(
                    contentsOf: splitRange(
                        NSRange(location: start, length: sentenceEnd - start),
                        in: nsText,
                        maximumLength: maximumUnitLength
                    )
                )
                continue
            }

            if let existingStart = groupStart,
               sentenceEnd - existingStart > maximumUnitLength {
                flushGroup()
            }
            if groupStart == nil {
                groupStart = start
            }
            groupEnd = sentenceEnd
        }
        flushGroup()

        if sourceRanges.isEmpty {
            sourceRanges = splitRange(
                NSRange(location: offset, length: nsText.length - offset),
                in: nsText,
                maximumLength: maximumUnitLength
            )
        }

        return sourceRanges.compactMap { range in
            let unitText = nsText.substring(with: range)
            guard !unitText.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                return nil
            }
            return SpeechUnit(
                text: unitText,
                utf16Offset: range.location,
                utf16Length: range.length
            )
        }
    }

    private static func splitRange(
        _ range: NSRange,
        in text: NSString,
        maximumLength: Int
    ) -> [NSRange] {
        var result: [NSRange] = []
        var cursor = range.location
        let rangeEnd = NSMaxRange(range)

        while rangeEnd - cursor > maximumLength {
            let proposedLength = min(maximumLength, rangeEnd - cursor)
            let searchRange = NSRange(
                location: cursor + maximumLength / 2,
                length: proposedLength - maximumLength / 2
            )
            let whitespace = text.rangeOfCharacter(
                from: .whitespacesAndNewlines,
                options: .backwards,
                range: searchRange
            )
            let end = whitespace.location != NSNotFound
                ? whitespace.location + whitespace.length
                : cursor + proposedLength
            result.append(
                NSRange(location: cursor, length: max(1, end - cursor))
            )
            cursor = max(cursor + 1, end)
        }
        if cursor < rangeEnd {
            result.append(
                NSRange(location: cursor, length: rangeEnd - cursor)
            )
        }
        return result
    }

    private static func estimatedSamples(
        for text: String,
        sampleRate: Int
    ) -> Int64 {
        let utf16Length = max(1, (text as NSString).length)
        let wordCount = max(1, wordRanges(in: text).count)
        let duration = max(
            Double(utf16Length) / 14.5,
            Double(wordCount) / 2.65
        )
        return Int64(max(duration, 0.35) * Double(sampleRate))
    }

    private static func styleInstruction(
        for language: QwenTTSLanguage
    ) -> String {
        if language == .russian {
            return """
            Читай как носитель русского языка: нейтральное нормативное произношение, \
            естественная русская интонация и ударения, без иностранного акцента и \
            без английской фонетики. Говори ясно, спокойно и выразительно.
            """
        }
        return """
        Read naturally and clearly as a native speaker of the requested language, \
        with no foreign accent and a calm professional cadence.
        """
    }
}

enum PlaybackError: LocalizedError {
    case emptyText
    case textTooLong
    case voiceUnavailable
    case invalidAudio
    case generationFailed(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .emptyText:
            "Не удалось найти выделенный текст."
        case .textTooLong:
            "Выделенный текст превышает 200 000 символов."
        case .voiceUnavailable:
            "Выбранный голос Qwen недоступен."
        case .invalidAudio:
            "Qwen вернул повреждённый аудиопоток."
        case let .generationFailed(details):
            "Не удалось создать речь Qwen: \(details)"
        case .cancelled:
            "Озвучивание было отменено."
        }
    }
}
