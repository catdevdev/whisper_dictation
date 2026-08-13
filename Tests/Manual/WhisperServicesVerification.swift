import AppKit
import AVFoundation
import Darwin
import Foundation
import Security
import WhisperCore

/// Dependency-free regression coverage for the application services. The suite
/// never contacts OpenAI, starts audio capture, or asks for a privacy permission.
@main
private enum WhisperServicesVerification {
    @MainActor
    static func main() async {
        var verifier = Verifier()

        await verifier.verifyOpenAIClient()
        verifier.verifyTextInsertionPrimitives()
        verifier.verifyKeychainRoundTrip()
        verifier.verifyAudioRecorderFilePolicy()
        verifier.verifySingleInstanceGuard()

        if verifier.failureCount == 0 {
            print("Whisper services verification passed (\(verifier.checkCount) checks)")
        } else {
            fputs(
                "Whisper services verification failed: \(verifier.failureCount) of "
                    + "\(verifier.checkCount) checks failed\n",
                stderr
            )
            exit(EXIT_FAILURE)
        }
    }
}

@MainActor
private struct Verifier {
    private(set) var checkCount = 0
    private(set) var failureCount = 0

    mutating func verifyOpenAIClient() async {
        let fileManager = FileManager.default
        let directory = makeTemporaryDirectory(named: "network")
        defer { try? fileManager.removeItem(at: directory) }

        let audioURL = directory.appendingPathComponent("voice.m4a")
        do {
            try Data([0x00, 0x01, 0xFE, 0xFF]).write(to: audioURL, options: .atomic)
        } catch {
            recordFailure("OpenAI fixture creation: \(error)")
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let endpoint = URL(string: "https://unit.test/v1/audio/transcriptions")!
        let client = OpenAITranscriptionClient(endpoint: endpoint, session: session)

        StubURLProtocol.state.configure(
            .response(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"text":"  Hello, world!  "}"#.utf8)
            )
        )

        do {
            let transcription = try await client.transcribe(
                audioURL: audioURL,
                apiKey: "  sk-unit-test  ",
                language: "  uk  "
            )
            expectEqual(transcription, "Hello, world!", "success response is trimmed")
        } catch {
            recordFailure("successful OpenAI response: \(error)")
        }

        let requests = StubURLProtocol.state.recordedRequests()
        expectEqual(requests.count, 1, "one HTTP request is issued")
        if let request = requests.first {
            expectEqual(request.url, endpoint, "transcription endpoint")
            expectEqual(request.httpMethod, "POST", "transcription HTTP method")
            expectEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                "Bearer sk-unit-test",
                "trimmed API key in authorization header"
            )
            expectEqual(
                request.value(forHTTPHeaderField: "Accept"),
                "application/json",
                "JSON response requested"
            )

            let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            expect(
                contentType.hasPrefix("multipart/form-data; boundary="),
                "multipart content type"
            )

            let body = String(decoding: requestBody(from: request), as: UTF8.self)
            expect(
                body.contains("name=\"model\"\r\n\r\ngpt-4o-transcribe"),
                "model multipart field"
            )
            expect(
                body.contains("name=\"language\"\r\n\r\nuk"),
                "normalized language multipart field"
            )
            expect(
                body.contains("name=\"file\"; filename=\"voice.m4a\""),
                "audio multipart field"
            )
            expect(body.contains("Content-Type: audio/mp4"), "audio MIME type")
        }

        StubURLProtocol.state.configure(
            .response(statusCode: 401, headers: [:], body: apiError("bad key"))
        )
        do {
            _ = try await client.transcribe(audioURL: audioURL, apiKey: "sk-test")
            recordFailure("HTTP 401 should throw unauthorized")
        } catch let error as TranscriptionError {
            if case .unauthorized = error {
                recordSuccess()
            } else {
                recordFailure("HTTP 401 mapping: \(error)")
            }
        } catch {
            recordFailure("HTTP 401 unexpected error: \(error)")
        }

        StubURLProtocol.state.configure(
            .response(
                statusCode: 429,
                headers: ["Retry-After": "1.25"],
                body: apiError("slow down")
            )
        )
        do {
            _ = try await client.transcribe(audioURL: audioURL, apiKey: "sk-test")
            recordFailure("HTTP 429 should throw rateLimited")
        } catch let error as TranscriptionError {
            if case let .rateLimited(retryAfter) = error {
                expectEqual(retryAfter, 1.25, "HTTP 429 Retry-After mapping")
            } else {
                recordFailure("HTTP 429 mapping: \(error)")
            }
        } catch {
            recordFailure("HTTP 429 unexpected error: \(error)")
        }

        let retryDateFormatter = DateFormatter()
        retryDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        retryDateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        retryDateFormatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        let retryDate = Date().addingTimeInterval(30)
        StubURLProtocol.state.configure(
            .response(
                statusCode: 429,
                headers: ["Retry-After": retryDateFormatter.string(from: retryDate)],
                body: apiError("slow down")
            )
        )
        do {
            _ = try await client.transcribe(audioURL: audioURL, apiKey: "sk-test")
            recordFailure("HTTP-date Retry-After should throw rateLimited")
        } catch let error as TranscriptionError {
            if case let .rateLimited(retryAfter) = error, let retryAfter {
                expect(
                    (27...30).contains(retryAfter),
                    "HTTP-date Retry-After mapping"
                )
            } else {
                recordFailure("HTTP-date Retry-After mapping: \(error)")
            }
        } catch {
            recordFailure("HTTP-date Retry-After unexpected error: \(error)")
        }

        StubURLProtocol.state.configure(
            .response(statusCode: 503, headers: [:], body: apiError("maintenance"))
        )
        do {
            _ = try await client.transcribe(audioURL: audioURL, apiKey: "sk-test")
            recordFailure("HTTP 503 should throw server")
        } catch let error as TranscriptionError {
            if case let .server(statusCode, message) = error {
                expectEqual(statusCode, 503, "HTTP 503 status mapping")
                expectEqual(message, "maintenance", "HTTP 503 message mapping")
            } else {
                recordFailure("HTTP 503 mapping: \(error)")
            }
        } catch {
            recordFailure("HTTP 503 unexpected error: \(error)")
        }

        StubURLProtocol.state.configure(
            .response(statusCode: 422, headers: [:], body: apiError("bad audio"))
        )
        do {
            _ = try await client.transcribe(audioURL: audioURL, apiKey: "sk-test")
            recordFailure("HTTP 422 should throw requestRejected")
        } catch let error as TranscriptionError {
            if case let .requestRejected(statusCode, message) = error {
                expectEqual(statusCode, 422, "HTTP 422 status mapping")
                expectEqual(message, "bad audio", "HTTP 422 message mapping")
            } else {
                recordFailure("HTTP 422 mapping: \(error)")
            }
        } catch {
            recordFailure("HTTP 422 unexpected error: \(error)")
        }

        StubURLProtocol.state.configure(
            .response(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"text":"   "}"#.utf8)
            )
        )
        do {
            _ = try await client.transcribe(audioURL: audioURL, apiKey: "sk-test")
            recordFailure("blank transcription should throw malformedResponse")
        } catch let error as TranscriptionError {
            if case .malformedResponse = error {
                recordSuccess()
            } else {
                recordFailure("blank response mapping: \(error)")
            }
        } catch {
            recordFailure("blank response unexpected error: \(error)")
        }

        StubURLProtocol.state.configure(.failure(URLError(.notConnectedToInternet)))
        do {
            _ = try await client.transcribe(audioURL: audioURL, apiKey: "sk-test")
            recordFailure("transport failure should throw transport")
        } catch let error as TranscriptionError {
            if case .transport = error {
                recordSuccess()
            } else {
                recordFailure("transport error mapping: \(error)")
            }
        } catch {
            recordFailure("transport unexpected error: \(error)")
        }

        StubURLProtocol.state.configure(
            .response(statusCode: 200, headers: [:], body: Data(#"{"text":"unused"}"#.utf8))
        )
        do {
            _ = try await client.transcribe(audioURL: audioURL, apiKey: "bad\nkey")
            recordFailure("line break in API key should be rejected")
        } catch let error as TranscriptionError {
            if case .invalidAPIKey = error {
                expectEqual(
                    StubURLProtocol.state.recordedRequests().count,
                    0,
                    "invalid key is rejected before networking"
                )
            } else {
                recordFailure("invalid API key mapping: \(error)")
            }
        } catch {
            recordFailure("invalid API key unexpected error: \(error)")
        }

        StubURLProtocol.state.configure(.pendingUntilCancelled)
        let cancellationTask = Task {
            try await client.transcribe(audioURL: audioURL, apiKey: "sk-test")
        }
        for _ in 0..<200 where StubURLProtocol.state.recordedRequests().isEmpty {
            try? await Task<Never, Never>.sleep(for: .milliseconds(5))
        }
        expect(
            !StubURLProtocol.state.recordedRequests().isEmpty,
            "cancellable request reaches URL loading system"
        )
        cancellationTask.cancel()
        do {
            _ = try await cancellationTask.value
            recordFailure("cancelled request should not return a transcription")
        } catch is CancellationError {
            recordSuccess()
        } catch {
            recordFailure("cancelled request should preserve CancellationError, got: \(error)")
        }

        for _ in 0..<100 where !StubURLProtocol.state.wasStopped() {
            try? await Task<Never, Never>.sleep(for: .milliseconds(2))
        }
        expect(StubURLProtocol.state.wasStopped(), "cancellation stops URL loading")
    }

    mutating func verifyKeychainRoundTrip() {
        let identifier = UUID().uuidString
        let store = KeychainCredentialStore(
            service: "com.nekoneki.whisper.tests.\(identifier)",
            account: "service-verification"
        )
        defer { try? store.deleteAPIKey() }

        do {
            try store.deleteAPIKey()
            let missingKeyIsConfigured = try store.hasAPIKey()
            expect(!missingKeyIsConfigured, "missing Keychain item is not configured")
            expectEqual(try store.loadAPIKey(), nil, "missing Keychain item loads as nil")

            try store.saveAPIKey("  sk-first-value  ")
            let savedKeyIsConfigured = try store.hasAPIKey()
            expect(savedKeyIsConfigured, "saved Keychain item is configured")
            expectEqual(try store.loadAPIKey(), "sk-first-value", "Keychain save and load")

            try store.saveAPIKey("sk-replacement")
            expectEqual(try store.loadAPIKey(), "sk-replacement", "Keychain update")

            try store.deleteAPIKey()
            expectEqual(try store.loadAPIKey(), nil, "Keychain delete is idempotent")
        } catch {
            recordFailure("Keychain round trip: \(error)")
        }

        do {
            try store.saveAPIKey("  \n  ")
            recordFailure("blank Keychain value should be rejected")
        } catch let error as CredentialStoreError {
            if case .invalidAPIKey = error {
                recordSuccess()
            } else {
                recordFailure("blank Keychain value mapping: \(error)")
            }
        } catch {
            recordFailure("blank Keychain value unexpected error: \(error)")
        }
    }

    mutating func verifyTextInsertionPrimitives() {
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name(
                "com.nekoneki.whisper.tests.\(UUID().uuidString)"
            )
        )
        let service = TextInsertionService(pasteboard: pasteboard)
        let transcript = "Привіт, мир 👋 — clipboard paste"

        do {
            let previousChangeCount = pasteboard.changeCount
            let writtenChangeCount = try service.writeTranscriptToClipboard(transcript)
            expect(
                writtenChangeCount > previousChangeCount,
                "clipboard write advances the pasteboard change count"
            )
            expectEqual(
                pasteboard.string(forType: .string),
                transcript,
                "clipboard retains the complete Unicode transcript"
            )

            let events = try service.makePasteShortcutEvents()
            expectEqual(
                events.commandDown.getIntegerValueField(.keyboardEventKeycode),
                Int64(55),
                "paste shortcut presses the physical Command key first"
            )
            expect(
                events.commandDown.flags.contains(.maskCommand),
                "Command key-down establishes modifier state"
            )
            expectEqual(
                events.keyDown.getIntegerValueField(.keyboardEventKeycode),
                Int64(9),
                "paste shortcut uses the physical V key"
            )
            expect(
                events.keyDown.flags.contains(.maskCommand),
                "paste key-down carries Command"
            )
            expect(
                !events.keyDown.flags.contains(.maskAlternate),
                "paste key-down clears residual Option"
            )
            expect(
                events.keyUp.flags.contains(.maskCommand),
                "paste key-up carries Command"
            )
            expectEqual(
                events.commandUp.getIntegerValueField(.keyboardEventKeycode),
                Int64(55),
                "paste shortcut releases the physical Command key last"
            )
            expect(
                !events.commandUp.flags.contains(.maskCommand),
                "Command key-up clears modifier state"
            )
            expect(
                TextInsertionService.isStandardPasteMenuItem(
                    commandCharacter: "V",
                    modifiers: 0,
                    title: "Paste"
                ),
                "ordinary Command-V menu item is selected"
            )
            expect(
                TextInsertionService.isStandardPasteMenuItem(
                    commandCharacter: nil,
                    modifiers: nil,
                    title: "Вставить"
                ),
                "localized Paste title is selected when command metadata is absent"
            )
            expect(
                !TextInsertionService.isStandardPasteMenuItem(
                    commandCharacter: "V",
                    modifiers: 1,
                    title: "Paste and Match Style"
                ),
                "modified Paste variant is not selected"
            )
        } catch {
            recordFailure("text insertion primitives: \(error)")
        }
    }

    mutating func verifyAudioRecorderFilePolicy() {
        expectEqual(
            AudioRecorderService.minimumUsefulDuration,
            0.3,
            "minimum useful recording duration"
        )
        expectEqual(
            AudioRecorderService.defaultMaximumDuration,
            300,
            "default recording duration cap"
        )
        expectEqual(
            AudioRecorderService.maximumAllowedDuration,
            600,
            "absolute recording duration cap"
        )

        let fileManager = FileManager.default
        let directory = makeTemporaryDirectory(named: "audio")
        defer { try? fileManager.removeItem(at: directory) }

        do {
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        } catch {
            recordFailure("audio fixture directory permissions: \(error)")
            return
        }

        let lowCap = AudioRecorderService(
            temporaryDirectory: directory,
            maximumDuration: -10
        )
        let ordinaryCap = AudioRecorderService(
            temporaryDirectory: directory,
            maximumDuration: 42
        )
        let highCap = AudioRecorderService(
            temporaryDirectory: directory,
            maximumDuration: 10_000
        )
        let nonFiniteCap = AudioRecorderService(
            temporaryDirectory: directory,
            maximumDuration: .infinity
        )
        expectEqual(lowCap.maximumDuration, 1, "recording cap lower bound")
        expectEqual(ordinaryCap.maximumDuration, 42, "recording cap preserves valid value")
        expectEqual(highCap.maximumDuration, 600, "recording cap upper bound")
        expectEqual(nonFiniteCap.maximumDuration, 300, "non-finite cap uses default")

        expectEqual(permissionBits(at: directory), 0o700, "temporary directory is private")

        let oldCapture = directory.appendingPathComponent("old.m4a")
        let recentCapture = directory.appendingPathComponent("recent.m4a")
        let wrongExtension = directory.appendingPathComponent("old.wav")
        let hiddenCapture = directory.appendingPathComponent(".old.m4a")
        let managedCapture = directory.appendingPathComponent("completed.m4a")
        let outsideCapture = directory
            .deletingLastPathComponent()
            .appendingPathComponent("outside-\(UUID().uuidString).m4a")
        defer { try? fileManager.removeItem(at: outsideCapture) }

        let fixtureURLs = [
            oldCapture,
            recentCapture,
            wrongExtension,
            hiddenCapture,
            managedCapture,
            outsideCapture,
        ]
        for url in fixtureURLs {
            let created = fileManager.createFile(
                atPath: url.path,
                contents: Data([0x01]),
                attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
            )
            expect(created, "create audio fixture \(url.lastPathComponent)")
        }

        do {
            let oldDate = Date().addingTimeInterval(-120)
            for url in [oldCapture, wrongExtension, hiddenCapture] {
                try fileManager.setAttributes(
                    [.modificationDate: oldDate],
                    ofItemAtPath: url.path
                )
            }

            expectEqual(permissionBits(at: oldCapture), 0o600, "audio capture is private")

            let service = AudioRecorderService(temporaryDirectory: directory)
            try service.cleanupStaleTemporaryCaptures(olderThan: 60)
            expect(!fileManager.fileExists(atPath: oldCapture.path), "old managed capture removed")
            expect(
                fileManager.fileExists(atPath: recentCapture.path),
                "recent managed capture retained"
            )
            expect(
                fileManager.fileExists(atPath: wrongExtension.path),
                "non-M4A file retained"
            )
            expect(fileManager.fileExists(atPath: hiddenCapture.path), "hidden file retained")

            try service.cleanup(AudioCapture(url: managedCapture, duration: 1))
            expect(!fileManager.fileExists(atPath: managedCapture.path), "completed capture removed")

            try service.cleanupAllTemporaryCaptures()
            expect(
                !fileManager.fileExists(atPath: recentCapture.path),
                "startup cleanup removes a recent orphan after instance lock"
            )

            try service.cleanup(AudioCapture(url: outsideCapture, duration: 1))
            expect(
                fileManager.fileExists(atPath: outsideCapture.path),
                "cleanup cannot remove a capture outside its managed directory"
            )
        } catch {
            recordFailure("audio temporary-file policy: \(error)")
        }

        let partialDirectory = makeTemporaryDirectory(named: "partial-cleanup")
        defer { try? fileManager.removeItem(at: partialDirectory) }
        let blockedCapture = partialDirectory.appendingPathComponent("blocked.m4a")
        let removableCapture = partialDirectory.appendingPathComponent("removable.m4a")
        _ = fileManager.createFile(atPath: blockedCapture.path, contents: Data([0x01]))
        _ = fileManager.createFile(atPath: removableCapture.path, contents: Data([0x02]))
        let selectiveFileManager = SelectiveFailureFileManager(blockedURL: blockedCapture)
        let partialCleanupService = AudioRecorderService(
            fileManager: selectiveFileManager,
            temporaryDirectory: partialDirectory
        )
        do {
            try partialCleanupService.cleanupAllTemporaryCaptures()
            recordFailure("partial cleanup should report its aggregate failure")
        } catch let error as AudioRecorderServiceError {
            if case let .cleanupFailed(fileCount) = error {
                expectEqual(fileCount, 1, "partial cleanup aggregate failure count")
            } else {
                recordFailure("partial cleanup error mapping: \(error)")
            }
        } catch {
            recordFailure("partial cleanup unexpected error: \(error)")
        }
        expect(
            fileManager.fileExists(atPath: blockedCapture.path),
            "failed capture remains available for a later cleanup attempt"
        )
        expect(
            !fileManager.fileExists(atPath: removableCapture.path),
            "one cleanup failure does not prevent deletion of later captures"
        )
    }

    mutating func verifySingleInstanceGuard() {
        let fileManager = FileManager.default
        let directory = makeTemporaryDirectory(named: "instance")
        defer { try? fileManager.removeItem(at: directory) }

        let cachesDirectory = directory.appendingPathComponent("Caches", isDirectory: true)
        let isolatedFileManager = IsolatedCachesFileManager(cachesDirectory: cachesDirectory)

        do {
            var first = try SingleInstanceGuard.acquire(fileManager: isolatedFileManager)
            expect(first != nil, "first process lock acquisition")

            let second = try SingleInstanceGuard.acquire(fileManager: isolatedFileManager)
            expect(second == nil, "second process lock is rejected")

            let lockDirectory = cachesDirectory.appendingPathComponent(
                "com.nekoneki.whisper-dictation",
                isDirectory: true
            )
            let lockFile = lockDirectory.appendingPathComponent("instance.lock")
            expectEqual(permissionBits(at: lockDirectory), 0o700, "instance directory is private")
            expectEqual(permissionBits(at: lockFile), 0o600, "instance lock file is private")

            first = nil
            var replacement = try SingleInstanceGuard.acquire(fileManager: isolatedFileManager)
            expect(replacement != nil, "lock can be reacquired after release")
            replacement = nil
        } catch {
            recordFailure("single-instance guard: \(error)")
        }
    }

    private mutating func expect(
        _ condition: @autoclosure () -> Bool,
        _ label: String
    ) {
        if condition() {
            recordSuccess()
        } else {
            recordFailure(label)
        }
    }

    private mutating func expectEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        _ label: String
    ) {
        if actual == expected {
            recordSuccess()
        } else {
            recordFailure("\(label): expected \(expected), got \(actual)")
        }
    }

    private mutating func recordSuccess() {
        checkCount += 1
    }

    private mutating func recordFailure(_ message: String) {
        checkCount += 1
        failureCount += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private enum StubPlan: Sendable {
    case response(statusCode: Int, headers: [String: String], body: Data)
    case failure(URLError)
    case pendingUntilCancelled
}

private final class StubURLProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var plan: StubPlan = .failure(URLError(.unknown))
    private var requests: [URLRequest] = []
    private var stopped = false

    func configure(_ plan: StubPlan) {
        lock.lock()
        self.plan = plan
        requests = []
        stopped = false
        lock.unlock()
    }

    func record(_ request: URLRequest) -> StubPlan {
        lock.lock()
        requests.append(request)
        let currentPlan = plan
        lock.unlock()
        return currentPlan
    }

    func recordedRequests() -> [URLRequest] {
        lock.lock()
        let snapshot = requests
        lock.unlock()
        return snapshot
    }

    func markStopped() {
        lock.lock()
        stopped = true
        lock.unlock()
    }

    func wasStopped() -> Bool {
        lock.lock()
        let snapshot = stopped
        lock.unlock()
        return snapshot
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = StubURLProtocolState()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "unit.test"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        switch Self.state.record(request) {
        case let .response(statusCode, headers, body):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: headers
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)

        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)

        case .pendingUntilCancelled:
            break
        }
    }

    override func stopLoading() {
        Self.state.markStopped()
    }
}

private final class IsolatedCachesFileManager: FileManager, @unchecked Sendable {
    private let cachesDirectory: URL

    init(cachesDirectory: URL) {
        self.cachesDirectory = cachesDirectory
        super.init()
    }

    override func urls(
        for directory: FileManager.SearchPathDirectory,
        in domainMask: FileManager.SearchPathDomainMask
    ) -> [URL] {
        if directory == .cachesDirectory, domainMask.contains(.userDomainMask) {
            return [cachesDirectory]
        }
        return super.urls(for: directory, in: domainMask)
    }
}

private final class SelectiveFailureFileManager: FileManager, @unchecked Sendable {
    private let blockedURL: URL

    init(blockedURL: URL) {
        self.blockedURL = blockedURL.standardizedFileURL
        super.init()
    }

    override func removeItem(at URL: URL) throws {
        if URL.standardizedFileURL == blockedURL {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: URL)
    }
}

private func makeTemporaryDirectory(named name: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "WhisperServicesVerification-\(name)-\(UUID().uuidString)",
            isDirectory: true
        )
    do {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
    } catch {
        fputs("Unable to create test directory: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
    return url
}

private func permissionBits(at url: URL) -> Int? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let permissions = attributes[.posixPermissions] as? NSNumber else {
        return nil
    }
    return permissions.intValue & 0o777
}

private func apiError(_ message: String) -> Data {
    try! JSONSerialization.data(
        withJSONObject: ["error": ["message": message]],
        options: [.sortedKeys]
    )
}

private func requestBody(from request: URLRequest) -> Data {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return Data() }

    stream.open()
    defer { stream.close() }

    var body = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count > 0 else { break }
        body.append(buffer, count: count)
    }
    return body
}
