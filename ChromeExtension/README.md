# Whisper Chrome extension

This unpacked Manifest V3 extension is bundled with Whisper 2.4.0. It sends the
exact Chrome selection to the same native Whisper menu-bar app that handles
dictation, follows the app's UTF-16 speech-boundary events on the page, and
provides popup plus in-page transport controls. Speech synthesis stays local in
Whisper and uses Qwen3-TTS 1.7B through Apple MLX; there is no second app or
Native Messaging host.

## Install the bundled extension

1. Launch `Whisper.app` and open **Settings** from its menu-bar control center.
2. Under **Permissions**, enable both **Accessibility** and **Input
   Monitoring**. Accessibility permits native selection access; Input
   Monitoring is what lets Whisper distinguish the physical left and right
   Option keys.
3. Under **Google Chrome**, choose **Show extension**. Finder reveals
   `Whisper.app/Contents/Resources/ChromeExtension`.
4. Open `chrome://extensions`.
5. Enable **Developer mode**.
6. Choose **Load unpacked** and select the revealed `ChromeExtension` folder.
7. In Whisper Settings, choose **Copy connection code**.
8. Open the extension popup, expand **Local connection**, paste the code, and
   choose **Connect**. The popup reports connected only after both sides verify
   fresh HMAC-SHA256 challenges.

For a repository build, the same files are embedded at
`dist/Whisper.app/Contents/Resources/ChromeExtension`; extension development can
load the repository's `ChromeExtension` directory directly. After updating the
app, use **Reload** on `chrome://extensions` so an already loaded unpacked
extension picks up the bundled version.

## Use

Select text, tap the right Option key, then press it again and hold for 1.5
seconds. You can also choose **Read selection** in the popup or use
`Option+Shift+S`.

Chrome does not expose a bare left/right Option modifier as an extension shortcut. The macOS app owns that global gesture and sends `requestSelection`; the extension handles Chrome selection and follow-along highlighting.

The global right-Option path requires both macOS permissions above. Input
Monitoring authorizes Whisper's listen-only physical-key events and is the
permission that makes left/right Option routing possible; Accessibility is
used for selection fallback and native-app reading.

The in-page toolbar provides −10/+10 spoken-token navigation, pause/resume,
stop, and progress. The popup adds absolute seeking. Voice and playback speed
come from Whisper Settings for both browser and native selections. Whisper's
menu-bar control center provides pause/resume, previous/next sentence, stop,
and its own position slider. State and position remain synchronized through
the local bridge.

If the authenticated extension does not answer while Chrome is active, Whisper
falls back to the macOS Accessibility selection after a short timeout. The text
can still be spoken, but Chrome cannot show the word-following highlight.

Stop, replacement, tab close, and navigation remove the extension-owned shadow
root and CSS highlight without rewriting page text.

## Pairing and local bridge

The pairing secret is generated once by the app and stored in
`~/Library/Application Support/Whisper/chrome-pairing-code` with
user-only permissions. Chrome keeps its copy in `chrome.storage.local`. The
secret is not included in status pushes, content-script messages, or WebSocket
frames.

Whisper is the WebSocket server at the fixed loopback-only endpoint
`ws://127.0.0.1:17777`; the extension is the client. Each connection performs
fresh mutual HMAC-SHA256 challenges before selection or control messages are
accepted.

For automated local integration only, launching the app with a valid
64-character `WHISPER_CHROME_PAIRING_CODE` uses that value ephemerally and does
not read or write the persistent pairing file.

## Development

```sh
npm test
npm run check
```

There are no runtime or development dependencies.

See [PROTOCOL.md](./PROTOCOL.md) for the app bridge contract.

## Browser limitations

- Chrome blocks content scripts on `chrome://` pages, the Chrome Web Store, and its built-in PDF viewer.
- A file page works only after the user enables **Allow access to file URLs** for the extension.
- Text selected in an input or textarea can be spoken, but Chrome cannot apply a DOM Range highlight inside that native control.
- Selection inside a closed shadow root or a cross-origin iframe may not be visible to the top-page content script.
- Chrome multi-range selections use their first range.

If a page framework replaces any selected text node while reading, Whisper stops and removes its UI instead of guessing stale offsets.
