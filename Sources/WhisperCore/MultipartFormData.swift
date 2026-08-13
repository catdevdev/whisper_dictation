import Foundation

/// A small, dependency-free encoder for `multipart/form-data` request bodies.
///
/// Parts are retained as values and encoded on demand, so reading ``body`` is
/// idempotent and never appends a second closing boundary.
public struct MultipartFormData: Sendable {
    private enum Part: Sendable {
        case field(name: String, data: Data)
        case file(name: String, filename: String, mimeType: String, data: Data)
    }

    public let boundary: String
    private var parts: [Part] = []

    public init(boundary: String = MultipartFormData.makeBoundary()) {
        precondition(!boundary.isEmpty, "A multipart boundary cannot be empty")
        precondition(
            !boundary.contains("\r") && !boundary.contains("\n"),
            "A multipart boundary cannot contain a line break"
        )
        self.boundary = boundary
    }

    /// A fresh boundary suitable for the `Content-Type` header and body.
    public static func makeBoundary() -> String {
        "WhisperBoundary-\(UUID().uuidString)"
    }

    public var contentType: String {
        "multipart/form-data; boundary=\(boundary)"
    }

    public var isEmpty: Bool { parts.isEmpty }
    public var count: Int { parts.count }

    public mutating func appendField(name: String, value: String) {
        append(Data(value.utf8), name: name)
    }

    public mutating func appendFile(
        name: String,
        filename: String,
        mimeType: String,
        data: Data
    ) {
        parts.append(
            .file(
                name: name,
                filename: filename,
                mimeType: mimeType,
                data: data
            )
        )
    }

    /// Appends a non-file part. This is useful for values already represented
    /// as bytes while `appendField` is the convenient text equivalent.
    public mutating func append(_ data: Data, name: String) {
        parts.append(.field(name: name, data: data))
    }

    /// Appends a file part using the spelling commonly used by HTTP clients.
    public mutating func append(
        _ data: Data,
        name: String,
        fileName: String,
        mimeType: String
    ) {
        appendFile(name: name, filename: fileName, mimeType: mimeType, data: data)
    }

    public mutating func append(_ value: String, name: String) {
        appendField(name: name, value: value)
    }

    /// Compatibility overloads for call sites migrating from Alamofire-style
    /// multipart builders.
    public mutating func append(_ data: Data, withName name: String) {
        append(data, name: name)
    }

    public mutating func append(
        _ data: Data,
        withName name: String,
        fileName: String,
        mimeType: String
    ) {
        appendFile(name: name, filename: fileName, mimeType: mimeType, data: data)
    }

    /// The complete encoded body, including the single terminating delimiter.
    public var body: Data { encoded() }

    public func encode() -> Data { encoded() }

    public func encoded() -> Data {
        var result = Data()

        for part in parts {
            result.appendUTF8("--\(boundary)\r\n")

            switch part {
            case let .field(name, data):
                result.appendUTF8(
                    "Content-Disposition: form-data; name=\"\(Self.escapedParameter(name))\"\r\n"
                )
                result.appendUTF8("\r\n")
                result.append(data)

            case let .file(name, filename, mimeType, data):
                result.appendUTF8(
                    "Content-Disposition: form-data; name=\"\(Self.escapedParameter(name))\"; "
                        + "filename=\"\(Self.escapedParameter(filename))\"\r\n"
                )
                result.appendUTF8("Content-Type: \(Self.safeMIMEType(mimeType))\r\n")
                result.appendUTF8("\r\n")
                result.append(data)
            }

            result.appendUTF8("\r\n")
        }

        result.appendUTF8("--\(boundary)--\r\n")
        return result
    }

    private static func escapedParameter(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    private static func safeMIMEType(_ value: String) -> String {
        let singleLine = value
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return singleLine.isEmpty ? "application/octet-stream" : singleLine
    }
}

private extension Data {
    mutating func appendUTF8(_ value: String) {
        append(contentsOf: value.utf8)
    }
}
