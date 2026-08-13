import Foundation
import WhisperCore

public enum TranscriptionError: LocalizedError, Sendable {
    case invalidAPIKey
    case unreadableAudio
    case invalidResponse
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case server(statusCode: Int, message: String?)
    case requestRejected(statusCode: Int, message: String?)
    case malformedResponse
    case transport(description: String)

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "The OpenAI API key is missing or invalid."
        case .unreadableAudio:
            "The recorded audio could not be read."
        case .invalidResponse:
            "The transcription service returned an invalid response."
        case .unauthorized:
            "OpenAI rejected the API key."
        case let .rateLimited(retryAfter):
            if let retryAfter {
                "OpenAI rate limit reached. Try again in \(Int(retryAfter.rounded(.up))) seconds."
            } else {
                "OpenAI rate limit reached. Try again shortly."
            }
        case let .server(statusCode, message):
            message ?? "OpenAI is temporarily unavailable (HTTP \(statusCode))."
        case let .requestRejected(statusCode, message):
            message ?? "OpenAI rejected the transcription request (HTTP \(statusCode))."
        case .malformedResponse:
            "OpenAI returned a response without transcription text."
        case let .transport(description):
            "The transcription request failed: \(description)"
        }
    }
}

/// Sends audio directly to OpenAI's transcription endpoint without retaining request data.
public final class OpenAITranscriptionClient: @unchecked Sendable {
    public static let maximumAudioFileSize = 25 * 1_024 * 1_024
    public static let defaultEndpoint = URL(
        string: "https://api.openai.com/v1/audio/transcriptions"
    )!

    private let endpoint: URL
    private let session: URLSession

    /// Creates a client backed by an ephemeral URL session (no disk cache or cookies).
    public convenience init(endpoint: URL = defaultEndpoint) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 300
        self.init(endpoint: endpoint, session: URLSession(configuration: configuration))
    }

    /// Dependency-injection initializer intended for tests and controlled networking stacks.
    public init(endpoint: URL = defaultEndpoint, session: URLSession) {
        self.endpoint = endpoint
        self.session = session
    }

    /// Transcribes a local audio file with `gpt-4o-transcribe`.
    public func transcribe(
        audioURL: URL,
        apiKey: String,
        language: String? = nil
    ) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty,
              !key.contains("\r"),
              !key.contains("\n") else {
            throw TranscriptionError.invalidAPIKey
        }

        let expectedByteCount: Int
        do {
            let values = try audioURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            )
            guard values.isRegularFile == true, let fileSize = values.fileSize else {
                throw TranscriptionError.unreadableAudio
            }
            expectedByteCount = fileSize
        } catch let error as TranscriptionError {
            throw error
        } catch {
            throw TranscriptionError.unreadableAudio
        }
        guard expectedByteCount <= Self.maximumAudioFileSize else {
            throw audioFileTooLargeError()
        }

        let audioData: Data
        do {
            audioData = try Data(contentsOf: audioURL, options: [.mappedIfSafe])
        } catch {
            throw TranscriptionError.unreadableAudio
        }
        guard !audioData.isEmpty else {
            throw TranscriptionError.unreadableAudio
        }
        guard audioData.count <= Self.maximumAudioFileSize else {
            throw audioFileTooLargeError()
        }

        var form = MultipartFormData()
        form.appendField(name: "model", value: "gpt-4o-transcribe")
        if let language,
           let normalizedLanguage = normalizedLanguage(language) {
            form.appendField(name: "language", value: normalizedLanguage)
        }
        form.appendFile(
            name: "file",
            filename: sanitizedFilename(for: audioURL),
            mimeType: mimeType(for: audioURL),
            data: audioData
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form.encoded()

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TranscriptionError.transport(description: safeTransportDescription(error))
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }
        try validate(httpResponse, responseBody: data)

        guard let payload = try? JSONDecoder().decode(TranscriptionPayload.self, from: data) else {
            throw TranscriptionError.malformedResponse
        }
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.malformedResponse
        }
        return text
    }

    private func validate(_ response: HTTPURLResponse, responseBody data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
            switch response.statusCode {
            case 401:
                throw TranscriptionError.unauthorized
            case 429:
                throw TranscriptionError.rateLimited(
                    retryAfter: retryDelay(from: response.value(forHTTPHeaderField: "Retry-After"))
                )
            case 500...599:
                throw TranscriptionError.server(
                    statusCode: response.statusCode,
                    message: message
                )
            default:
                throw TranscriptionError.requestRejected(
                    statusCode: response.statusCode,
                    message: message
                )
            }
        }
    }

    private func retryDelay(from value: String?) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let retryDate = formatter.date(from: value) else { return nil }
        return max(0, retryDate.timeIntervalSinceNow)
    }

    private func normalizedLanguage(_ language: String) -> String? {
        let value = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.lowercased() != "auto" else { return nil }
        return value
    }

    private func sanitizedFilename(for url: URL) -> String {
        let proposed = url.lastPathComponent
        guard !proposed.isEmpty,
              !proposed.contains("\r"),
              !proposed.contains("\n"),
              !proposed.contains("\"") else {
            return "dictation.m4a"
        }
        return proposed
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav": "audio/wav"
        case "mp3": "audio/mpeg"
        case "webm": "audio/webm"
        default: "audio/mp4"
        }
    }

    private func safeTransportDescription(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.localizedDescription
        }
        return "A network error occurred."
    }

    private func audioFileTooLargeError() -> TranscriptionError {
        .requestRejected(
            statusCode: 413,
            message: "The audio file exceeds the 25 MB transcription limit."
        )
    }
}

private struct TranscriptionPayload: Decodable {
    let text: String
}

private struct ErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String?
    }

    let error: APIError
}
