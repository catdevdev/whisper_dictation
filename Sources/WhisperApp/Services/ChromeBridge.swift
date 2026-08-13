import Foundation
import WhisperCore

@MainActor
final class ChromeBridge {
    private struct PendingChallenge {
        let clientNonce: String
        let serverNonce: String
        let issuedAt: Date
    }

    private let server = LocalWebSocketServer()
    private let playback: SpeechPlaybackController
    private let pairingCode: String?
    private var readyClients = Set<LocalWebSocketServer.ClientID>()
    private var readyClientOrder: [LocalWebSocketServer.ClientID] = []
    private var playbackOwner: LocalWebSocketServer.ClientID?
    private var pendingChallenges: [
        LocalWebSocketServer.ClientID: PendingChallenge
    ] = [:]
    private var pendingSelectionFallbacks: [String: Task<Void, Never>] = [:]
    private var expiredSelectionRequests: [String: Date] = [:]

    var onConnectionChanged: ((Bool) -> Void)?
    var onPlaybackStateChanged: ((SpeechPlaybackController.State) -> Void)?
    var onPlaybackBoundary: ((_ offset: Int, _ length: Int, _ total: Int) -> Void)?
    var onPlaybackEnded: ((_ reason: String) -> Void)?
    var onError: ((Error) -> Void)?

    init(playback: SpeechPlaybackController, pairingCode: String?) {
        self.playback = playback
        self.pairingCode = pairingCode
        configureServer()
        configurePlaybackEvents()
    }

    var hasReadyClient: Bool { !readyClients.isEmpty }

    func start() {
        do {
            try server.start()
        } catch {
            onError?(error)
        }
    }

    func stop() {
        pendingSelectionFallbacks.values.forEach { $0.cancel() }
        pendingSelectionFallbacks.removeAll()
        expiredSelectionRequests.removeAll()
        playbackOwner = nil
        readyClientOrder.removeAll()
        readyClients.removeAll()
        server.stop()
    }

    func stopPlayback(reason: String) {
        if let owner = playbackOwner, let sessionID = playback.currentSessionID {
            server.send(
                BridgeOutboundMessage(
                    type: "ended",
                    sessionId: sessionID,
                    reason: reason
                ),
                to: owner
            )
        }
        playbackOwner = nil
        playback.stop()
    }

    /// Returns true when Chrome was asked. The fallback runs unless Chrome
    /// starts the matching playback before the deadline. A `selection`
    /// message is only an intermediate response: Chrome may still disconnect
    /// before it sends `speak`.
    @discardableResult
    func requestSelection(
        timeout: TimeInterval = 0.45,
        fallback: @escaping () -> Void
    ) -> Bool {
        guard let clientID = readyClientOrder.last(where: {
            readyClients.contains($0)
        }) else {
            return false
        }
        let requestID = UUID().uuidString.lowercased()
        pruneExpiredSelectionRequests()
        let message = BridgeOutboundMessage(
            type: "requestSelection",
            requestId: requestID,
            autoplay: true
        )
        server.send(message, to: clientID)

        let fallbackTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(timeout, 0.05) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, let self else { return }
            pendingSelectionFallbacks[requestID] = nil
            expiredSelectionRequests[requestID] = Date()
                .addingTimeInterval(5)
            fallback()
        }
        pendingSelectionFallbacks[requestID] = fallbackTask
        return true
    }

    private func configureServer() {
        server.onClientDisconnected = { [weak self] clientID in
            guard let self else { return }
            self.pendingChallenges.removeValue(forKey: clientID)
            self.readyClients.remove(clientID)
            self.readyClientOrder.removeAll { $0 == clientID }
            if self.playbackOwner == clientID {
                self.playbackOwner = nil
                self.playback.stop()
            }
            self.onConnectionChanged?(!self.readyClients.isEmpty)
        }
        server.onTextMessage = { [weak self] clientID, text in
            self?.handle(text: text, from: clientID)
        }
        server.onError = { [weak self] error in
            self?.onError?(error)
        }
    }

    private func configurePlaybackEvents() {
        playback.onStateChanged = { [weak self] state, sessionID in
            guard let self else { return }
            self.onPlaybackStateChanged?(state)
            // Session teardown is reported through the richer ended/error
            // messages. Sending idle first would make Chrome discard that
            // terminal reason after clearing its session.
            guard state != .idle,
                  let sessionID,
                  let owner = self.playbackOwner
            else { return }
            self.server.send(
                BridgeOutboundMessage(
                    type: "state",
                    sessionId: sessionID,
                    state: state.rawValue
                ),
                to: owner
            )
        }
        playback.onBoundary = { [weak self] sessionID, offset, length in
            guard let self else { return }
            self.onPlaybackBoundary?(offset, length, self.playback.textUTF16Length)
            guard let owner = self.playbackOwner else { return }
            self.server.send(
                BridgeOutboundMessage(
                    type: "boundary",
                    sessionId: sessionID,
                    offset: offset,
                    length: length
                ),
                to: owner
            )
        }
        playback.onEnded = { [weak self] sessionID in
            guard let self else { return }
            if let owner = self.playbackOwner {
                self.server.send(
                    BridgeOutboundMessage(
                        type: "ended",
                        sessionId: sessionID,
                        reason: "completed"
                    ),
                    to: owner
                )
            }
            self.playbackOwner = nil
            self.onPlaybackEnded?("completed")
        }
        playback.onError = { [weak self] sessionID, error in
            guard let self else { return }
            if let owner = self.playbackOwner {
                self.sendError(
                    to: owner,
                    sessionID: sessionID,
                    code: Self.errorCode(for: error),
                    message: error.localizedDescription,
                    recoverable: true
                )
            }
            self.playbackOwner = nil
            self.onPlaybackEnded?("error")
            self.onError?(error)
        }
    }

    private func notifyOwnedSessionEnded(reason: String) {
        guard let owner = playbackOwner,
              let sessionID = playback.currentSessionID
        else {
            return
        }
        server.send(
            BridgeOutboundMessage(
                type: "ended",
                sessionId: sessionID,
                reason: reason
            ),
            to: owner
        )
    }

    private func handle(text: String, from clientID: LocalWebSocketServer.ClientID) {
        guard let data = text.data(using: .utf8),
              data.count <= BridgeProtocol.maximumMessageBytes
        else {
            sendError(
                to: clientID,
                code: "message_too_large",
                message: "The JSON message exceeds 1 MiB.",
                recoverable: true
            )
            return
        }

        let message: BridgeInboundMessage
        do {
            message = try JSONDecoder().decode(BridgeInboundMessage.self, from: data)
        } catch {
            sendError(
                to: clientID,
                code: "invalid_json",
                message: "The message does not match protocol v1.",
                recoverable: true
            )
            return
        }

        guard message.protocolVersion == BridgeProtocol.version else {
            sendError(
                to: clientID,
                requestID: message.requestId,
                code: "unsupported_protocol",
                message: "Only protocol version 1 is supported.",
                recoverable: false
            )
            return
        }

        if message.type == "hello" {
            handleHello(message, clientID: clientID)
            return
        }
        if message.type == "authenticate" {
            handleAuthenticate(message, clientID: clientID)
            return
        }
        guard readyClients.contains(clientID) else {
            sendError(
                to: clientID,
                requestID: message.requestId,
                code: "authentication_required",
                message: "Complete the Whisper pairing handshake first.",
                recoverable: false
            )
            return
        }

        switch message.type {
        case "ping":
            server.send(
                BridgeOutboundMessage(type: "pong", timestamp: message.timestamp),
                to: clientID
            )

        case "selection":
            // Keep the fallback alive until the matching `speak` request is
            // accepted. Otherwise a disconnect between these two messages
            // leaves the reading HUD indefinitely in its generating state.
            break

        case "speak":
            handleSpeak(message, clientID: clientID)

        case "control":
            handleControl(message, clientID: clientID)

        case "error":
            // Keep the short pending timeout so the AX/copy fallback runs.
            // Do not echo an extension-side error back as unknown_message.
            break

        default:
            sendError(
                to: clientID,
                requestID: message.requestId,
                code: "unknown_message",
                message: "Unknown message type.",
                recoverable: true
            )
        }
    }

    private func handleHello(
        _ message: BridgeInboundMessage,
        clientID: LocalWebSocketServer.ClientID
    ) {
        pendingChallenges.removeValue(forKey: clientID)
        if readyClients.remove(clientID) != nil {
            readyClientOrder.removeAll { $0 == clientID }
            if playbackOwner == clientID {
                playbackOwner = nil
                playback.stop()
            }
            onConnectionChanged?(!readyClients.isEmpty)
        }

        guard let pairingCode else {
            sendError(
                to: clientID,
                code: "pairing_unavailable",
                message: "The local pairing code could not be loaded.",
                recoverable: false
            )
            return
        }
        guard message.role == "chrome-extension" else {
            sendError(
                to: clientID,
                code: "invalid_role",
                message: "Only the Chrome extension role is accepted.",
                recoverable: false
            )
            return
        }
        guard let rawClientNonce = message.clientNonce,
              let clientNonce = try? PairingAuthentication.normalizeHex(
                  rawClientNonce,
                  field: "clientNonce"
              )
        else {
            sendError(
                to: clientID,
                code: "invalid_hello",
                message: "hello.clientNonce must be 64 hexadecimal characters.",
                recoverable: true
            )
            return
        }

        let serverNonce = PairingAuthentication.randomHex()
        guard let serverProof = try? PairingAuthentication.proof(
            domain: PairingAuthentication.serverDomain,
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            pairingCode: pairingCode
        ) else {
            sendError(
                to: clientID,
                code: "pairing_unavailable",
                message: "The local pairing key is unavailable.",
                recoverable: false
            )
            return
        }

        pendingChallenges[clientID] = PendingChallenge(
            clientNonce: clientNonce,
            serverNonce: serverNonce,
            issuedAt: Date()
        )
        server.send(
            BridgeOutboundMessage(
                type: "challenge",
                clientNonce: clientNonce,
                serverNonce: serverNonce,
                proof: serverProof
            ),
            to: clientID
        )
    }

    private func handleAuthenticate(
        _ message: BridgeInboundMessage,
        clientID: LocalWebSocketServer.ClientID
    ) {
        guard let pairingCode,
              let challenge = pendingChallenges.removeValue(forKey: clientID),
              Date().timeIntervalSince(challenge.issuedAt) <= 15,
              let rawClientNonce = message.clientNonce,
              let rawServerNonce = message.serverNonce,
              let proof = message.proof,
              let clientNonce = try? PairingAuthentication.normalizeHex(
                  rawClientNonce,
                  field: "clientNonce"
              ),
              let serverNonce = try? PairingAuthentication.normalizeHex(
                  rawServerNonce,
                  field: "serverNonce"
              ),
              clientNonce == challenge.clientNonce,
              serverNonce == challenge.serverNonce,
              PairingAuthentication.verify(
                  proof: proof,
                  domain: PairingAuthentication.clientDomain,
                  clientNonce: clientNonce,
                  serverNonce: serverNonce,
                  pairingCode: pairingCode
              )
        else {
            sendError(
                to: clientID,
                code: "pairing_failed",
                message: "Pairing proof is invalid or expired.",
                recoverable: true
            )
            return
        }

        readyClients.insert(clientID)
        readyClientOrder.removeAll { $0 == clientID }
        readyClientOrder.append(clientID)
        server.send(
            BridgeOutboundMessage(
                type: "authenticated",
                clientNonce: clientNonce,
                serverNonce: serverNonce
            ),
            to: clientID
        )
        onConnectionChanged?(true)
    }

    private func handleSpeak(
        _ message: BridgeInboundMessage,
        clientID: LocalWebSocketServer.ClientID
    ) {
        guard let sessionID = message.sessionId, !sessionID.isEmpty,
              let text = message.text, !text.isEmpty
        else {
            sendError(
                to: clientID,
                requestID: message.requestId,
                code: "invalid_speak",
                message: "speak requires sessionId and non-empty text.",
                recoverable: true
            )
            return
        }
        guard (text as NSString).length <= 200_000 else {
            sendError(
                to: clientID,
                sessionID: sessionID,
                requestID: message.requestId,
                code: "text_too_long",
                message: "Selected text exceeds 200,000 UTF-16 code units.",
                recoverable: true
            )
            return
        }

        pruneExpiredSelectionRequests()
        if let requestID = message.requestId,
           expiredSelectionRequests.removeValue(forKey: requestID) != nil {
            sendError(
                to: clientID,
                sessionID: sessionID,
                requestID: requestID,
                code: "selection_expired",
                message: "Whisper already started the native selection fallback.",
                recoverable: true
            )
            return
        }

        resolvePendingSelection(requestID: message.requestId)
        notifyOwnedSessionEnded(reason: "replaced")
        playbackOwner = clientID
        playback.speak(
            .init(
                sessionID: sessionID,
                requestID: message.requestId,
                text: text,
                language: message.language,
                rate: message.rate,
                voiceIdentifier: message.voiceIdentifier
            )
        )
    }

    private func handleControl(
        _ message: BridgeInboundMessage,
        clientID: LocalWebSocketServer.ClientID
    ) {
        guard let sessionID = message.sessionId,
              playbackOwner == clientID,
              sessionID == playback.currentSessionID,
              let action = message.action
        else { return }

        switch action {
        case "pause":
            playback.pause()
        case "resume":
            playback.resume()
        case "stop":
            playback.stop()
            playbackOwner = nil
        case "skip" where message.unit == "token":
            playback.skipTokens(message.amount ?? 0)
        case "seek" where message.unit == "utf16":
            playback.seek(toUTF16Offset: message.offset ?? 0)
        default:
            break
        }
    }

    private func resolvePendingSelection(requestID: String?) {
        guard let requestID,
              let fallbackTask = pendingSelectionFallbacks.removeValue(
                  forKey: requestID
              )
        else { return }
        fallbackTask.cancel()
    }

    private func pruneExpiredSelectionRequests() {
        let now = Date()
        expiredSelectionRequests = expiredSelectionRequests.filter {
            $0.value > now
        }
    }

    private func sendError(
        to clientID: LocalWebSocketServer.ClientID? = nil,
        sessionID: String? = nil,
        requestID: String? = nil,
        code: String,
        message: String,
        recoverable: Bool
    ) {
        let response = BridgeOutboundMessage(
            type: "error",
            requestId: requestID,
            sessionId: sessionID,
            code: code,
            message: message,
            recoverable: recoverable
        )
        if let clientID {
            server.send(response, to: clientID)
        } else if let playbackOwner {
            server.send(response, to: playbackOwner)
        }
    }

    private static func errorCode(for error: Error) -> String {
        switch error {
        case PlaybackError.voiceUnavailable:
            return "voice_unavailable"
        case PlaybackError.textTooLong:
            return "text_too_long"
        case PlaybackError.emptyText:
            return "empty_text"
        default:
            return "playback_failed"
        }
    }
}
