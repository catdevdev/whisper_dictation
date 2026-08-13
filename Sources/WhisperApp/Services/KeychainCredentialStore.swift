import Foundation
import Security

public enum CredentialStoreError: LocalizedError, Sendable {
    case invalidAPIKey
    case invalidStoredValue
    case keychain(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey:
            "The API key cannot be empty."
        case .invalidStoredValue:
            "The API key stored in Keychain is not valid UTF-8."
        case let .keychain(status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                "Keychain operation failed: \(message)"
            } else {
                "Keychain operation failed (status \(status))."
            }
        }
    }
}

/// Persists the OpenAI API key in the current device's protected Keychain.
public struct KeychainCredentialStore: Sendable {
    public static let defaultService = "com.nekoneki.whisper.openai"
    public static let defaultAccount = "default"

    public let service: String
    public let account: String

    public init(
        service: String = defaultService,
        account: String = defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    /// Checks for an existing item without reading its protected value.
    ///
    /// This is suitable for background readiness checks because Keychain does
    /// not need to display an access-control prompt merely to match metadata.
    public func hasAPIKey() throws -> Bool {
        var query = baseQuery
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        switch SecItemCopyMatching(query as CFDictionary, nil) {
        case errSecSuccess:
            return true
        case errSecItemNotFound:
            return false
        case let status:
            throw CredentialStoreError.keychain(status: status)
        }
    }

    /// Loads the key. The value must never be written to logs or diagnostics.
    public func loadAPIKey() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8) else {
                throw CredentialStoreError.invalidStoredValue
            }
            return value
        case errSecItemNotFound:
            return nil
        default:
            throw CredentialStoreError.keychain(status: status)
        }
    }

    /// Saves or replaces the key using `WhenUnlockedThisDeviceOnly` accessibility.
    public func saveAPIKey(_ apiKey: String) throws {
        let value = try normalized(apiKey)
        let data = Data(value.utf8)

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)

        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let attributes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(
                baseQuery as CFDictionary,
                attributes as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw CredentialStoreError.keychain(status: updateStatus)
            }
        default:
            throw CredentialStoreError.keychain(status: addStatus)
        }
    }

    /// Deletes the stored key. Calling this when no key exists is harmless.
    public func deleteAPIKey() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func normalized(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("\r"),
              !trimmed.contains("\n") else {
            throw CredentialStoreError.invalidAPIKey
        }
        return trimmed
    }

}
