import CryptoKit
import Foundation
import Network
import WhisperCore

/// Minimal RFC 6455 server intentionally bound to IPv4 loopback.
///
/// It supports the subset browsers use: masked text frames, fragmentation,
/// ping/pong, close, and messages up to 1 MiB. No selected or dictated text is
/// logged.
final class LocalWebSocketServer: @unchecked Sendable {
    typealias ClientID = UUID

    private let queue = DispatchQueue(label: "com.nekoneki.whisper.websocket")
    private var listener: NWListener?
    private var clients: [ClientID: WebSocketClient] = [:]

    var onTextMessage: ((ClientID, String) -> Void)?
    var onClientConnected: ((ClientID) -> Void)?
    var onClientDisconnected: ((ClientID) -> Void)?
    var onError: ((Error) -> Void)?

    var clientCount: Int {
        queue.sync { clients.count }
    }

    func start(port rawPort: UInt16 = BridgeProtocol.port) throws {
        let port = NWEndpoint.Port(rawValue: rawPort)!
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host("127.0.0.1"),
            port: port
        )

        let newListener = try NWListener(using: parameters)
        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case let .failed(error):
                self.report(error)
                self.stop()
            case let .waiting(error):
                self.report(error)
            default:
                break
            }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener = newListener
        newListener.start(queue: queue)
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.listener?.cancel()
            self.listener = nil
            let existing = Array(self.clients.values)
            self.clients.removeAll()
            existing.forEach { $0.cancel() }
        }
    }

    func send(_ message: BridgeOutboundMessage, to clientID: ClientID? = nil) {
        guard let data = try? JSONEncoder().encode(message),
              data.count <= BridgeProtocol.maximumMessageBytes,
              let text = String(data: data, encoding: .utf8)
        else { return }
        send(text: text, to: clientID)
    }

    func broadcast(_ message: BridgeOutboundMessage) {
        send(message)
    }

    private func send(text: String, to clientID: ClientID?) {
        queue.async { [weak self] in
            guard let self else { return }
            if let clientID {
                self.clients[clientID]?.sendText(text)
            } else {
                self.clients.values.forEach { $0.sendText(text) }
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let client = WebSocketClient(id: id, connection: connection, queue: queue)
        client.onHandshakeComplete = { [weak self] id in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onClientConnected?(id)
            }
        }
        client.onTextMessage = { [weak self] id, message in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onTextMessage?(id, message)
            }
        }
        client.onClosed = { [weak self] id in
            guard let self else { return }
            self.clients[id] = nil
            DispatchQueue.main.async {
                self.onClientDisconnected?(id)
            }
        }
        clients[id] = client
        client.start()
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            self?.onError?(error)
        }
    }
}

private final class WebSocketClient: @unchecked Sendable {
    let id: UUID

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var receiveBuffer = Data()
    private var handshakeComplete = false
    private var fragmentOpcode: UInt8?
    private var fragmentPayload = Data()
    private var closed = false

    var onHandshakeComplete: ((UUID) -> Void)?
    var onTextMessage: ((UUID, String) -> Void)?
    var onClosed: ((UUID) -> Void)?

    init(id: UUID, connection: NWConnection, queue: DispatchQueue) {
        self.id = id
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .failed, .cancelled:
                self?.closeTransport()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
        closeTransport()
    }

    func sendText(_ text: String) {
        guard handshakeComplete else { return }
        let payload = Data(text.utf8)
        guard payload.count <= BridgeProtocol.maximumMessageBytes else { return }
        sendFrame(opcode: 0x1, payload: payload)
    }

    private func receive() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1_024
        ) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                if self.handshakeComplete {
                    self.parseFrames()
                } else {
                    self.parseHandshake()
                }
            }

            if isComplete || error != nil {
                self.closeTransport()
            } else {
                self.receive()
            }
        }
    }

    private func parseHandshake() {
        guard receiveBuffer.count <= 16 * 1_024 else {
            sendHTTPError(status: "431 Request Header Fields Too Large")
            return
        }
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = receiveBuffer.range(of: separator) else { return }

        let headerData = receiveBuffer[..<headerRange.lowerBound]
        receiveBuffer.removeSubrange(..<headerRange.upperBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            sendHTTPError(status: "400 Bad Request")
            return
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard lines.first?.hasPrefix("GET ") == true else {
            sendHTTPError(status: "405 Method Not Allowed")
            return
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        let upgrade = headers["upgrade"]?.lowercased()
        let connectionHeader = headers["connection"]?.lowercased()
        let version = headers["sec-websocket-version"]
        let origin = headers["origin"]?.lowercased()
        guard upgrade == "websocket",
              connectionHeader?.contains("upgrade") == true,
              version == "13",
              let key = headers["sec-websocket-key"],
              Data(base64Encoded: key)?.count == 16,
              origin == nil || origin?.hasPrefix("chrome-extension://") == true
        else {
            sendHTTPError(status: "403 Forbidden")
            return
        }

        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        let accept = Data(digest).base64EncodedString()
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
            "\r\n"
        ].joined(separator: "\r\n")

        connection.send(content: Data(response.utf8), completion: .contentProcessed {
            [weak self] error in
            guard let self else { return }
            if error != nil {
                self.closeTransport()
                return
            }
            self.handshakeComplete = true
            self.onHandshakeComplete?(self.id)
            self.parseFrames()
        })
    }

    private func parseFrames() {
        while true {
            let bytes = [UInt8](receiveBuffer)
            guard bytes.count >= 2 else { return }

            let first = bytes[0]
            let second = bytes[1]
            let isFinal = first & 0x80 != 0
            let reservedBits = first & 0x70
            let opcode = first & 0x0F
            let isMasked = second & 0x80 != 0
            var payloadLength = UInt64(second & 0x7F)
            var cursor = 2

            guard reservedBits == 0, isMasked else {
                close(code: 1002, reason: "Invalid frame")
                return
            }

            if payloadLength == 126 {
                guard bytes.count >= cursor + 2 else { return }
                payloadLength = UInt64(bytes[cursor]) << 8 | UInt64(bytes[cursor + 1])
                cursor += 2
            } else if payloadLength == 127 {
                guard bytes.count >= cursor + 8 else { return }
                payloadLength = 0
                for byte in bytes[cursor..<(cursor + 8)] {
                    payloadLength = (payloadLength << 8) | UInt64(byte)
                }
                cursor += 8
            }

            let isControl = opcode & 0x08 != 0
            guard payloadLength <= BridgeProtocol.maximumMessageBytes,
                  !isControl || (isFinal && payloadLength <= 125)
            else {
                close(code: 1009, reason: "Message too large")
                return
            }

            guard bytes.count >= cursor + 4 else { return }
            let mask = Array(bytes[cursor..<(cursor + 4)])
            cursor += 4
            guard payloadLength <= UInt64(Int.max),
                  bytes.count >= cursor + Int(payloadLength)
            else { return }

            var payload = Data(count: Int(payloadLength))
            payload.withUnsafeMutableBytes { rawBuffer in
                guard let output = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
                for index in 0..<Int(payloadLength) {
                    output[index] = bytes[cursor + index] ^ mask[index % 4]
                }
            }
            receiveBuffer.removeFirst(cursor + Int(payloadLength))

            guard handleFrame(opcode: opcode, isFinal: isFinal, payload: payload) else {
                return
            }
        }
    }

    private func handleFrame(opcode: UInt8, isFinal: Bool, payload: Data) -> Bool {
        switch opcode {
        case 0x0:
            guard fragmentOpcode != nil else {
                close(code: 1002, reason: "Unexpected continuation")
                return false
            }
            fragmentPayload.append(payload)
            guard fragmentPayload.count <= BridgeProtocol.maximumMessageBytes else {
                close(code: 1009, reason: "Message too large")
                return false
            }
            if isFinal {
                let completeOpcode = fragmentOpcode!
                let completePayload = fragmentPayload
                fragmentOpcode = nil
                fragmentPayload = Data()
                return deliverDataFrame(opcode: completeOpcode, payload: completePayload)
            }
            return true

        case 0x1:
            guard fragmentOpcode == nil else {
                close(code: 1002, reason: "Nested fragment")
                return false
            }
            if isFinal {
                return deliverDataFrame(opcode: opcode, payload: payload)
            }
            fragmentOpcode = opcode
            fragmentPayload = payload
            return true

        case 0x2:
            close(code: 1003, reason: "Binary unsupported")
            return false

        case 0x8:
            sendFrame(opcode: 0x8, payload: payload) { [weak self] in
                self?.connection.cancel()
                self?.closeTransport()
            }
            return false

        case 0x9:
            sendFrame(opcode: 0xA, payload: payload)
            return true

        case 0xA:
            return true

        default:
            close(code: 1002, reason: "Unknown opcode")
            return false
        }
    }

    private func deliverDataFrame(opcode: UInt8, payload: Data) -> Bool {
        guard opcode == 0x1, let text = String(data: payload, encoding: .utf8) else {
            close(code: 1007, reason: "Invalid UTF-8")
            return false
        }
        onTextMessage?(id, text)
        return true
    }

    private func sendFrame(
        opcode: UInt8,
        payload: Data,
        completion: (@Sendable () -> Void)? = nil
    ) {
        var frame = Data()
        frame.append(0x80 | opcode)

        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            var length = UInt64(payload.count).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in
            completion?()
        })
    }

    private func close(code: UInt16, reason: String) {
        var bigEndianCode = code.bigEndian
        var payload = Data(bytes: &bigEndianCode, count: MemoryLayout<UInt16>.size)
        payload.append(Data(reason.utf8.prefix(123)))
        sendFrame(opcode: 0x8, payload: payload) { [weak self] in
            self?.connection.cancel()
            self?.closeTransport()
        }
    }

    private func sendHTTPError(status: String) {
        let response = "HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        connection.send(content: Data(response.utf8), completion: .contentProcessed {
            [weak self] _ in
            self?.connection.cancel()
            self?.closeTransport()
        })
    }

    private func closeTransport() {
        guard !closed else { return }
        closed = true
        onClosed?(id)
    }
}
