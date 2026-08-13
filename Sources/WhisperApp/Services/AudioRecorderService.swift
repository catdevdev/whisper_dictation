import AVFoundation
import Combine
import Foundation

/// A completed recording owned by ``AudioRecorderService``.
public struct AudioCapture: Equatable, Sendable {
    public let url: URL
    public let duration: TimeInterval

    public init(url: URL, duration: TimeInterval) {
        self.url = url
        self.duration = duration
    }
}

public enum AudioRecorderServiceError: LocalizedError, Sendable {
    case alreadyRecording
    case notRecording
    case unableToCreateTemporaryFile
    case unableToStartRecording
    case emptyRecording
    case cleanupFailed(fileCount: Int)

    public var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "Recording is already in progress."
        case .notRecording:
            "There is no active recording."
        case .unableToCreateTemporaryFile:
            "A secure temporary audio file could not be created."
        case .unableToStartRecording:
            "Audio recording could not be started."
        case .emptyRecording:
            "The recording did not contain any audio data."
        case let .cleanupFailed(fileCount):
            "Unable to remove \(fileCount) temporary audio file(s)."
        }
    }
}

/// Records short, transcription-ready mono AAC clips into protected temporary files.
@MainActor
public final class AudioRecorderService: NSObject, ObservableObject {
    /// Default dictation cap. The caller should finalize the capture when this elapses.
    nonisolated public static let defaultMaximumDuration: TimeInterval = 300
    /// Absolute service cap, even when a larger value is supplied by a caller.
    nonisolated public static let maximumAllowedDuration: TimeInterval = 600
    nonisolated public static let minimumUsefulDuration: TimeInterval = 0.3

    @Published public private(set) var isRecording = false
    @Published public private(set) var averagePower: Float = -160
    @Published public private(set) var peakPower: Float = -160
    @Published public private(set) var elapsedTime: TimeInterval = 0

    public let temporaryDirectory: URL
    public let maximumDuration: TimeInterval
    public var onUnexpectedStop: (() -> Void)?

    // `deinit` is nonisolated even on a MainActor type. These objects are otherwise
    // confined to the main actor and are touched during teardown only after the
    // service has lost its final owner.
    nonisolated(unsafe) private let fileManager: FileManager
    private var recorder: AVAudioRecorder?
    nonisolated(unsafe) private var meterTimer: Timer?
    private var activeURL: URL?
    private var isStoppingIntentionally = false

    public init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        maximumDuration: TimeInterval = defaultMaximumDuration
    ) {
        self.fileManager = fileManager
        self.temporaryDirectory = temporaryDirectory
            ?? fileManager.temporaryDirectory.appendingPathComponent(
                "WhisperDictation",
                isDirectory: true
            )
        let requestedDuration = maximumDuration.isFinite
            ? maximumDuration
            : Self.defaultMaximumDuration
        self.maximumDuration = min(
            Self.maximumAllowedDuration,
            max(1, requestedDuration)
        )
        super.init()
    }

    deinit {
        meterTimer?.invalidate()
        recorder?.stop()
        if let activeURL {
            try? fileManager.removeItem(at: activeURL)
        }
    }

    /// Starts a new 16 kHz, 32 kbps mono AAC recording.
    public func startRecording() throws {
        guard recorder == nil else {
            throw AudioRecorderServiceError.alreadyRecording
        }

        try prepareTemporaryDirectory()
        let url = temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard fileManager.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw AudioRecorderServiceError.unableToCreateTemporaryFile
        }

        do {
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()

            guard recorder.record() else {
                throw AudioRecorderServiceError.unableToStartRecording
            }

            try enforcePrivatePermissions(on: url)
            self.recorder = recorder
            activeURL = url
            isRecording = true
            averagePower = -160
            peakPower = -160
            elapsedTime = 0
            startMetering()
        } catch {
            try? fileManager.removeItem(at: url)
            if let serviceError = error as? AudioRecorderServiceError {
                throw serviceError
            }
            throw error
        }
    }

    /// Stops the current recording and returns its secure temporary capture.
    public func stopRecording() throws -> AudioCapture {
        guard let recorder, let url = activeURL else {
            throw AudioRecorderServiceError.notRecording
        }

        recorder.updateMeters()
        let duration = max(recorder.currentTime, elapsedTime)
        isStoppingIntentionally = true
        recorder.stop()
        isStoppingIntentionally = false
        finishActiveRecordingState()

        do {
            try enforcePrivatePermissions(on: url)
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard duration >= Self.minimumUsefulDuration, byteCount > 0 else {
                throw AudioRecorderServiceError.emptyRecording
            }
            return AudioCapture(url: url, duration: duration)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
    }

    /// Stops and securely discards the current recording, if one exists.
    public func cancelRecording() {
        isStoppingIntentionally = true
        recorder?.stop()
        isStoppingIntentionally = false
        let url = activeURL
        finishActiveRecordingState()
        if let url {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Deletes a completed capture after it has been transcribed.
    public func cleanup(_ capture: AudioCapture) throws {
        guard isManagedCaptureURL(capture.url) else { return }
        guard fileManager.fileExists(atPath: capture.url.path) else { return }
        try fileManager.removeItem(at: capture.url)
    }

    /// Deletes every managed capture. Call only after the process-wide instance lock
    /// has been acquired, so no live Whisper process can own one of these files.
    public func cleanupAllTemporaryCaptures() throws {
        guard fileManager.fileExists(atPath: temporaryDirectory.path) else { return }
        var failureCount = 0
        for url in try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            do {
                guard isManagedCaptureURL(url),
                      try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    continue
                }
                try fileManager.removeItem(at: url)
            } catch {
                failureCount += 1
            }
        }
        if failureCount > 0 {
            throw AudioRecorderServiceError.cleanupFailed(fileCount: failureCount)
        }
    }

    /// Deletes only captures old enough that no valid recording can still own them.
    public func cleanupStaleTemporaryCaptures(
        olderThan maximumAge: TimeInterval = maximumAllowedDuration + 60
    ) throws {
        guard fileManager.fileExists(atPath: temporaryDirectory.path) else { return }
        let cutoff = Date().addingTimeInterval(-max(60, maximumAge))
        for url in try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .contentModificationDateKey]
            )
            guard isManagedCaptureURL(url),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate <= cutoff else {
                continue
            }
            try fileManager.removeItem(at: url)
        }
    }

    private func prepareTemporaryDirectory() throws {
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: temporaryDirectory.path
        )
    }

    private func enforcePrivatePermissions(on url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private func isManagedCaptureURL(_ url: URL) -> Bool {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        return parent == temporaryDirectory.standardizedFileURL
            && url.pathExtension.lowercased() == "m4a"
    }

    private func startMetering() {
        meterTimer?.invalidate()
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sampleMeters()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func sampleMeters() {
        guard let recorder else { return }
        guard recorder.isRecording else {
            discardUnexpectedlyStoppedRecording(
                matching: ObjectIdentifier(recorder)
            )
            return
        }
        recorder.updateMeters()
        averagePower = recorder.averagePower(forChannel: 0)
        peakPower = recorder.peakPower(forChannel: 0)
        elapsedTime = recorder.currentTime
    }

    private func finishActiveRecordingState() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder = nil
        activeURL = nil
        isRecording = false
        averagePower = -160
        peakPower = -160
        elapsedTime = 0
    }

    private func discardUnexpectedlyStoppedRecording(
        matching recorderIdentifier: ObjectIdentifier
    ) {
        guard let recorder,
              ObjectIdentifier(recorder) == recorderIdentifier,
              !isStoppingIntentionally else {
            return
        }

        let url = activeURL
        finishActiveRecordingState()
        if let url {
            try? fileManager.removeItem(at: url)
        }
        onUnexpectedStop?()
    }
}

extension AudioRecorderService: AVAudioRecorderDelegate {
    nonisolated public func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        let recorderIdentifier = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            self?.discardUnexpectedlyStoppedRecording(
                matching: recorderIdentifier
            )
        }
    }

    nonisolated public func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error: Error?
    ) {
        let recorderIdentifier = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            self?.discardUnexpectedlyStoppedRecording(
                matching: recorderIdentifier
            )
        }
    }
}
