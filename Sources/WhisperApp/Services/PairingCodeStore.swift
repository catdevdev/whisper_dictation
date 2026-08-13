import CryptoKit
import Darwin
import Foundation

/// Owns the per-user secret used to authenticate the localhost Chrome bridge.
///
/// The environment override is intentionally ephemeral and exists for the
/// integration harness. Normal launches persist one random 256-bit secret.
final class PairingCodeStore {
    static let environmentKey = "WHISPER_CHROME_PAIRING_CODE"
    static let legacyEnvironmentKey = "OPTIONVOICE_PAIRING_CODE"

    let pairingCode: String
    let isEphemeral: Bool

    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        applicationSupportURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        if let environmentEntry = [Self.environmentKey, Self.legacyEnvironmentKey]
            .compactMap({ key in environment[key].map { (key, $0) } })
            .first {
            pairingCode = try PairingAuthentication.normalizeHex(
                environmentEntry.1,
                field: environmentEntry.0
            )
            isEphemeral = true
            return
        }

        let supportURL = applicationSupportURL
            ?? fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
        let directoryURL = supportURL.appendingPathComponent(
            "Whisper",
            isDirectory: true
        )
        let codeURL = directoryURL.appendingPathComponent(
            "chrome-pairing-code",
            isDirectory: false
        )
        let legacyCodeURL = supportURL
            .appendingPathComponent("OptionVoice", isDirectory: true)
            .appendingPathComponent("chrome-pairing-code", isDirectory: false)

        try Self.preparePrivateDirectory(directoryURL, fileManager: fileManager)
        if fileManager.fileExists(atPath: codeURL.path) {
            pairingCode = try Self.readCode(at: codeURL)
        } else {
            // Preserve an already paired Chrome extension when migrating from
            // the former standalone OptionVoice app.
            let generated: String
            if fileManager.fileExists(atPath: legacyCodeURL.path) {
                generated = try Self.readCode(at: legacyCodeURL)
            } else {
                generated = PairingAuthentication.randomHex()
            }
            do {
                try Self.createCodeFile(generated, at: codeURL)
                pairingCode = generated
            } catch let error as POSIXError where error.code == .EEXIST {
                // A concurrently launched copy won the first-run race.
                pairingCode = try Self.readCode(at: codeURL)
            }
        }
        isEphemeral = false
    }

    private static func preparePrivateDirectory(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )

        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw currentPOSIXError()
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw PairingCodeStoreError.unsafeDirectory
        }
        guard chmod(url.path, mode_t(0o700)) == 0 else {
            throw currentPOSIXError()
        }
    }

    private static func readCode(at url: URL) throws -> String {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw currentPOSIXError()
        }
        guard metadata.st_mode & S_IFMT == S_IFREG else {
            throw PairingCodeStoreError.unsafeCodeFile
        }
        guard metadata.st_size <= 1_024 else {
            throw PairingCodeStoreError.invalidCode
        }
        guard chmod(url.path, mode_t(0o600)) == 0 else {
            throw currentPOSIXError()
        }

        let data = try Data(contentsOf: url, options: [.uncached])
        guard let text = String(data: data, encoding: .utf8) else {
            throw PairingCodeStoreError.invalidCode
        }
        return try PairingAuthentication.normalizeHex(
            text,
            field: "stored pairing code"
        )
    }

    private static func createCodeFile(_ code: String, at url: URL) throws {
        let descriptor = open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw currentPOSIXError()
        }
        defer { close(descriptor) }

        let bytes = Array(code.utf8)
        var written = 0
        while written < bytes.count {
            let result = bytes.withUnsafeBytes { buffer -> Int in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
            }
            guard result > 0 else {
                throw currentPOSIXError()
            }
            written += result
        }
        guard fsync(descriptor) == 0 else {
            throw currentPOSIXError()
        }
        guard chmod(url.path, mode_t(0o600)) == 0 else {
            throw currentPOSIXError()
        }
    }

    private static func currentPOSIXError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

enum PairingAuthentication {
    // Protocol v1 keeps its original domain strings so an already installed
    // extension reconnects after the app is merged into Whisper.
    static let serverDomain = "OptionVoice/ws-auth/v1/server"
    static let clientDomain = "OptionVoice/ws-auth/v1/client"

    static func normalizeHex(_ value: String, field: String) throws -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let bytes = normalized.utf8
        guard bytes.count == 64, bytes.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else {
            throw PairingCodeStoreError.invalidHex(field)
        }
        return normalized
    }

    static func randomHex() -> String {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0).lowercaseHex }
    }

    static func canonical(
        domain: String,
        clientNonce: String,
        serverNonce: String
    ) -> String {
        "\(domain)\n\(clientNonce)\n\(serverNonce)"
    }

    static func proof(
        domain: String,
        clientNonce: String,
        serverNonce: String,
        pairingCode: String
    ) throws -> String {
        let key = try symmetricKey(pairingCode)
        let message = canonical(
            domain: domain,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: key
        )
        return Data(authenticationCode).lowercaseHex
    }

    static func verify(
        proof: String,
        domain: String,
        clientNonce: String,
        serverNonce: String,
        pairingCode: String
    ) -> Bool {
        guard let normalizedProof = try? normalizeHex(proof, field: "proof"),
              let proofData = Data(lowercaseHex: normalizedProof),
              let key = try? symmetricKey(pairingCode)
        else {
            return false
        }
        let message = canonical(
            domain: domain,
            clientNonce: clientNonce,
            serverNonce: serverNonce
        )
        return HMAC<SHA256>.isValidAuthenticationCode(
            proofData,
            authenticating: Data(message.utf8),
            using: key
        )
    }

    private static func symmetricKey(_ pairingCode: String) throws -> SymmetricKey {
        let normalized = try normalizeHex(pairingCode, field: "pairing code")
        guard let data = Data(lowercaseHex: normalized), data.count == 32 else {
            throw PairingCodeStoreError.invalidCode
        }
        return SymmetricKey(data: data)
    }
}

enum PairingCodeStoreError: LocalizedError {
    case invalidCode
    case invalidHex(String)
    case unsafeCodeFile
    case unsafeDirectory

    var errorDescription: String? {
        switch self {
        case .invalidCode:
            return "The stored Chrome pairing code is invalid."
        case let .invalidHex(field):
            return "\(field) must contain exactly 64 hexadecimal characters."
        case .unsafeCodeFile:
            return "The Chrome pairing code path is not a regular file."
        case .unsafeDirectory:
            return "The Whisper support path is not a private directory."
        }
    }
}

private extension Data {
    init?(lowercaseHex: String) {
        guard lowercaseHex.utf8.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        data.reserveCapacity(lowercaseHex.utf8.count / 2)
        var index = lowercaseHex.startIndex
        while index < lowercaseHex.endIndex {
            let next = lowercaseHex.index(index, offsetBy: 2)
            guard let byte = UInt8(lowercaseHex[index..<next], radix: 16) else {
                return nil
            }
            data.append(byte)
            index = next
        }
        self = data
    }

    var lowercaseHex: String {
        let alphabet = Array("0123456789abcdef".utf8)
        var output = [UInt8]()
        output.reserveCapacity(count * 2)
        for byte in self {
            output.append(alphabet[Int(byte >> 4)])
            output.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: output, as: UTF8.self)
    }
}
