# Whisper Chrome WebSocket protocol

Protocol version `1` is newline-free JSON over one local WebSocket connection.
The Chrome extension is the client; the same native Whisper process that owns
dictation, hotkeys, and Qwen playback is the server. There is no separate
native host. The bundled pair uses the fixed endpoint
`ws://127.0.0.1:17777`.

All string offsets and lengths are UTF-16 code-unit indexes. This matches JavaScript string offsets and `NSRange` over `NSString`. The server must read and speak `text` exactly as sent; normalization would make page highlighting drift.

Chrome-rendered line breaks between blocks are preserved in `text` as unmapped gaps. Word boundaries on either side still map to their original DOM text nodes.

Limits:

- One encoded JSON message: 1 MiB.
- Selected text: 200,000 UTF-16 code units.
- Context URL, title, and language: 4,096, 512, and 64 code units.
- Only `ws://127.0.0.1:17777` is accepted by the bundled extension.
- Unknown session IDs and stale boundaries are ignored.

## Pairing

The app creates one random 32-byte pairing code on first launch. It stores the
64-character lowercase hexadecimal value at:

```text
~/Library/Application Support/Whisper/chrome-pairing-code
```

The directory is mode `0700` and the file is mode `0600`. The user chooses
**Copy connection code** in Whisper Settings and pastes it into the extension
popup. Chrome stores the code in `chrome.storage.local`; status and content
messages expose only `pairingConfigured`, never the code.

The pairing code is the raw 32-byte HMAC key after hexadecimal decoding. It is
never sent over the WebSocket.

For automated local integration, `WHISPER_CHROME_PAIRING_CODE` supplies an
ephemeral code and bypasses the persistent file. On migration from the former
standalone OptionVoice app, Whisper 2.2.0 imports the legacy pairing file only
when the Whisper file does not yet exist. The legacy
`OPTIONVOICE_PAIRING_CODE` environment name is likewise accepted only for
compatibility.

## Connection lifecycle

Every connection performs a fresh mutual challenge before it can carry any
selection, playback, status, or heartbeat messages. Nonces and proofs are
lowercase 64-character hexadecimal strings.

The extension first generates a random 32-byte nonce and sends:

```json
{
  "type": "hello",
  "protocol": 1,
  "role": "chrome-extension",
  "version": "2.4.0",
  "clientNonce": "4ef12a6eb315896e0990c8f8e0253c2efaf983bb09a53292736a1d71961f4c2a"
}
```

The app generates its own nonce and proves possession of the pairing key:

```json
{
  "type": "challenge",
  "protocol": 1,
  "clientNonce": "4ef12a6eb315896e0990c8f8e0253c2efaf983bb09a53292736a1d71961f4c2a",
  "serverNonce": "e71f66d9239f9edc600d71c2dd4c8953fbaa21d6daa3bd271fd96e2b060c90b7",
  "proof": "1d115d28f737f8883cfd5753096608dbae9b49fdef99c920cacda050122bd93e"
}
```

`proof` is HMAC-SHA256 over the UTF-8 bytes of this exact canonical string:

```text
OptionVoice/ws-auth/v1/server\n<clientNonce>\n<serverNonce>
```

`OptionVoice/ws-auth/v1/server` is an immutable protocol-v1 compatibility
domain, not the current app name or storage path. Whisper deliberately retains
it so an already paired extension can reconnect after the 2.2.0 integration.

After verifying the server proof with Web Crypto, the extension proves
possession of the same key:

```json
{
  "type": "authenticate",
  "protocol": 1,
  "clientNonce": "4ef12a6eb315896e0990c8f8e0253c2efaf983bb09a53292736a1d71961f4c2a",
  "serverNonce": "e71f66d9239f9edc600d71c2dd4c8953fbaa21d6daa3bd271fd96e2b060c90b7",
  "proof": "3a2f924db00c9e87377f4c5bfa54786154f92a592bcf023fd420e73ef733ea63"
}
```

Its canonical string uses the separate client domain:

```text
OptionVoice/ws-auth/v1/client\n<clientNonce>\n<serverNonce>
```

The client domain is retained for the same protocol-v1 compatibility reason.

The app verifies that proof against the outstanding challenge, consumes the
challenge so it cannot be replayed, and replies:

```json
{
  "type": "authenticated",
  "protocol": 1,
  "clientNonce": "4ef12a6eb315896e0990c8f8e0253c2efaf983bb09a53292736a1d71961f4c2a",
  "serverNonce": "e71f66d9239f9edc600d71c2dd4c8953fbaa21d6daa3bd271fd96e2b060c90b7"
}
```

The extension reports `connected` and enables sending only after this final
message matches the current connection. The app rejects every non-handshake
message before authentication. Challenges expire after 15 seconds; reconnects
always use new nonces, so captured proofs cannot authenticate a later socket.

Only after authentication does the extension send a heartbeat every 20
seconds:

```json
{ "type": "ping", "protocol": 1, "timestamp": 1785423600000 }
```

The app replies:

```json
{ "type": "pong", "protocol": 1, "timestamp": 1785423600000 }
```

The client reconnects with capped exponential backoff. Speech and control messages are never queued: if the app is offline, the user sees an error instead of stale text being spoken after a later reconnect.

## Start from the right Option key

Before this app-initiated flow is available, Whisper must be enabled under
macOS **Privacy & Security > Accessibility**. The same grant supports the
listen-only Core Graphics event tap, native selection access, and fallback.
No separate Input Monitoring permission is required; this local prerequisite
does not alter the pairing or WebSocket authentication contract.

When Whisper detects a clean press and release of the right Option key while
Chrome is active, it asks the authenticated extension for the active page
selection:

```json
{
  "type": "requestSelection",
  "protocol": 1,
  "requestId": "076a6c90-5eb0-4ab7-95ef-10d10276b206",
  "autoplay": true
}
```

The extension replies:

```json
{
  "type": "selection",
  "protocol": 1,
  "requestId": "076a6c90-5eb0-4ab7-95ef-10d10276b206",
  "selectionId": "64615c28-4a07-4c73-834c-d64d18f47a36",
  "text": "Exact selected text",
  "context": {
    "tabId": 42,
    "url": "https://example.com/article",
    "title": "Article",
    "language": "en"
  }
}
```

With `autoplay: true`, it immediately follows with a self-contained speech request:

```json
{
  "type": "speak",
  "protocol": 1,
  "requestId": "076a6c90-5eb0-4ab7-95ef-10d10276b206",
  "sessionId": "919e6a69-472b-4615-9814-e60941f0e11b",
  "selectionId": "64615c28-4a07-4c73-834c-d64d18f47a36",
  "text": "Exact selected text",
  "language": "en",
  "context": {
    "tabId": 42,
    "url": "https://example.com/article",
    "title": "Article",
    "language": "en"
  }
}
```

`autoplay: false` returns only `selection`. Starting from the popup or Chrome keyboard shortcut emits the same `selection` then `speak` sequence with an extension-generated `requestId`. Voice and playback speed always come from the single Whisper app settings store.

The app should stop any older session, begin speaking `text`, and echo `sessionId` on every event below.

## App events

State is authoritative:

```json
{
  "type": "state",
  "protocol": 1,
  "sessionId": "919e6a69-472b-4615-9814-e60941f0e11b",
  "state": "speaking"
}
```

Valid states are `buffering`, `speaking`, `paused`, and `idle`.

Send a boundary whenever the spoken token changes:

```json
{
  "type": "boundary",
  "protocol": 1,
  "sessionId": "919e6a69-472b-4615-9814-e60941f0e11b",
  "offset": 6,
  "length": 8
}
```

`offset` and `length` identify a range in the exact `speak.text`. A zero length is allowed; Chrome expands it to the token containing `offset`.

Successful completion:

```json
{
  "type": "ended",
  "protocol": 1,
  "sessionId": "919e6a69-472b-4615-9814-e60941f0e11b",
  "reason": "completed"
}
```

Failure:

```json
{
  "type": "error",
  "protocol": 1,
  "sessionId": "919e6a69-472b-4615-9814-e60941f0e11b",
  "code": "voice_unavailable",
  "message": "No suitable offline voice is installed.",
  "recoverable": true
}
```

For request-level errors, omit `sessionId` and include the related `requestId`.

## Transport controls

Chrome sends:

```json
{
  "type": "control",
  "protocol": 1,
  "sessionId": "919e6a69-472b-4615-9814-e60941f0e11b",
  "action": "pause"
}
```

`action` is `pause`, `resume`, or `stop`. Word-relative seek uses:

```json
{
  "type": "control",
  "protocol": 1,
  "sessionId": "919e6a69-472b-4615-9814-e60941f0e11b",
  "action": "skip",
  "amount": 10,
  "unit": "token"
}
```

`amount` is clamped from `-100` to `100`. The app should resolve the target with word-boundary tokenization, restart speech at that UTF-16 offset, then send a new `boundary` and `state`.

Absolute scrubbing uses:

```json
{
  "type": "control",
  "protocol": 1,
  "sessionId": "919e6a69-472b-4615-9814-e60941f0e11b",
  "action": "seek",
  "offset": 37,
  "unit": "utf16"
}
```

The extension clamps `offset` to the active `speak.text`. The app moves to the first speakable token at or after that UTF-16 offset, or finishes when the offset reaches the end.

## Navigation and cleanup

On stop, tab close, page navigation, or replacement by a new request, Chrome sends `control.stop` when possible and removes all reader-owned UI and highlights. Highlighting uses the CSS Custom Highlight API, so page text nodes are never split or rewritten. The fallback is a visual overlay in the extension-owned shadow root; it is removed in full.
