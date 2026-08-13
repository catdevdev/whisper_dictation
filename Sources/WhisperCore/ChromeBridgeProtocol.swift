import Foundation

public enum BridgeProtocol {
    public static let version = 1
    public static let port: UInt16 = 17_777
    public static let maximumMessageBytes = 1_048_576
}

public struct BridgeInboundMessage: Decodable, Sendable {
    public let type: String
    public let protocolVersion: Int?
    public let role: String?
    public let version: String?
    public let requestId: String?
    public let sessionId: String?
    public let selectionId: String?
    public let text: String?
    public let language: String?
    public let voiceIdentifier: String?
    public let rate: Float?
    public let action: String?
    public let amount: Int?
    public let offset: Int?
    public let unit: String?
    public let timestamp: Int64?
    public let autoplay: Bool?
    public let clientNonce: String?
    public let serverNonce: String?
    public let proof: String?

    public init(
        type: String,
        protocolVersion: Int? = nil,
        role: String? = nil,
        version: String? = nil,
        requestId: String? = nil,
        sessionId: String? = nil,
        selectionId: String? = nil,
        text: String? = nil,
        language: String? = nil,
        voiceIdentifier: String? = nil,
        rate: Float? = nil,
        action: String? = nil,
        amount: Int? = nil,
        offset: Int? = nil,
        unit: String? = nil,
        timestamp: Int64? = nil,
        autoplay: Bool? = nil,
        clientNonce: String? = nil,
        serverNonce: String? = nil,
        proof: String? = nil
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.role = role
        self.version = version
        self.requestId = requestId
        self.sessionId = sessionId
        self.selectionId = selectionId
        self.text = text
        self.language = language
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
        self.action = action
        self.amount = amount
        self.offset = offset
        self.unit = unit
        self.timestamp = timestamp
        self.autoplay = autoplay
        self.clientNonce = clientNonce
        self.serverNonce = serverNonce
        self.proof = proof
    }

    enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case role
        case version
        case requestId
        case sessionId
        case selectionId
        case text
        case language
        case voiceIdentifier
        case rate
        case action
        case amount
        case offset
        case unit
        case timestamp
        case autoplay
        case clientNonce
        case serverNonce
        case proof
    }
}

public struct BridgeOutboundMessage: Encodable, Sendable {
    public let type: String
    public let protocolVersion: Int
    public let requestId: String?
    public let sessionId: String?
    public let autoplay: Bool?
    public let state: String?
    public let offset: Int?
    public let length: Int?
    public let timestamp: Int64?
    public let reason: String?
    public let code: String?
    public let message: String?
    public let recoverable: Bool?
    public let clientNonce: String?
    public let serverNonce: String?
    public let proof: String?

    public init(
        type: String,
        protocolVersion: Int = BridgeProtocol.version,
        requestId: String? = nil,
        sessionId: String? = nil,
        autoplay: Bool? = nil,
        state: String? = nil,
        offset: Int? = nil,
        length: Int? = nil,
        timestamp: Int64? = nil,
        reason: String? = nil,
        code: String? = nil,
        message: String? = nil,
        recoverable: Bool? = nil,
        clientNonce: String? = nil,
        serverNonce: String? = nil,
        proof: String? = nil
    ) {
        self.type = type
        self.protocolVersion = protocolVersion
        self.requestId = requestId
        self.sessionId = sessionId
        self.autoplay = autoplay
        self.state = state
        self.offset = offset
        self.length = length
        self.timestamp = timestamp
        self.reason = reason
        self.code = code
        self.message = message
        self.recoverable = recoverable
        self.clientNonce = clientNonce
        self.serverNonce = serverNonce
        self.proof = proof
    }

    enum CodingKeys: String, CodingKey {
        case type
        case protocolVersion = "protocol"
        case requestId
        case sessionId
        case autoplay
        case state
        case offset
        case length
        case timestamp
        case reason
        case code
        case message
        case recoverable
        case clientNonce
        case serverNonce
        case proof
    }
}
