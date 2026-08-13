# Whisper

Whisper 2.4.5 is a small native macOS menu-bar app for voice dictation and local
Qwen reading of selected text. The left Shift key records, transcribes, and
inserts speech. A right-Option tap followed by a second, held press reads the
current selection with Qwen3-TTS 1.7B.

The user-facing runtime remains one Whisper app. Its bundle contains the static
Manifest V3 Chrome extension and a small Qwen worker script. Whisper manages an
isolated Python 3.12 environment and model cache under
`~/Library/Application Support/Whisper/Qwen`; the internal worker exists only
while Whisper is running. There is no second app, Native Messaging host, or
LaunchAgent.

## Hotkeys

Enable Whisper under **Privacy & Security > Accessibility** before using either
global hotkey. Whisper creates a listen-only event tap and never suppresses or
rewrites physical key presses. A separate Input Monitoring grant is not
normally required. If macOS rejects the event tap on a particular installation,
Whisper exposes Input Monitoring as a clearly labelled recovery action; it is
never a normal readiness gate.

### Left Shift: dictate

1. Tap the left `Shift` key quickly.
2. Press the left `Shift` key again within 2 seconds and hold it for 1.5
   seconds, until recording starts.
3. Release the key and dictate normally.
4. Tap the left `Shift` key once to stop, transcribe, and insert the text.

The first tap must last no more than 350 ms. Normal key presses, other
modifiers, and shortcuts such as `Shift` + another key cancel a
pending gesture. The right Option key cannot stop an active recording.

### Right Option: read

1. Select text and tap the right `Option` key quickly.
2. Press the right `Option` key again within 2 seconds and hold it for 1.5
   seconds.
3. Release after the Qwen generation widget appears.

Whisper streams speech locally through Qwen3-TTS 1.7B and Apple MLX; the OpenAI
key and microphone are not used for playback. Choose one of nine Qwen voices
and set playback speed from 0.5× to 2× in Whisper Settings.

The menu-bar control center provides pause/resume, previous/next sentence,
stop, and a position slider. In native apps, Whisper first obtains the
selection through Accessibility. For apps that do not expose selected text,
it uses a targeted copy while preserving the existing clipboard whenever no
other process changes it concurrently. In Chrome, the bundled extension adds a
word-following highlight, automatic scrolling, and synchronized in-page
controls. Whisper detects the language from the selected text itself, so an
English website interface does not force Russian text through English
pronunciation.

A compact HUD appears in the lower-right corner for both modifier gestures.
During Qwen reading it expands into a small non-activating controller with
pause/resume, previous/next sentence, precise seeking, stop, and live playback
speed. It does not activate Whisper or take keyboard focus from the selected
app.

## Chrome extension

The unpacked extension is shipped inside every built app; it is not a second
macOS application.

1. Launch the same `Whisper.app` that handles dictation.
2. Open Whisper Settings. Under **Google Chrome**, choose **Show extension**.
3. Open `chrome://extensions`, enable **Developer mode**, choose **Load
   unpacked**, and select the revealed `ChromeExtension` folder.
4. Back in Whisper Settings, choose **Copy connection code**.
5. Open the extension popup, expand **Local connection**, paste the code, and
   choose **Connect**.
6. Wait for both Whisper and the popup to report that the extension is
   connected.

Now select text on a normal web page and use the right-Option tap-then-hold
gesture. Whisper asks the extension for the exact selection, reads it locally,
and sends UTF-16 speech boundaries back so Chrome can move the highlight. Both
Chrome controls provide pause/resume, stop, ±10-word navigation, and progress;
the popup adds absolute seeking. Voice and speed use the same settings as native
reading. If Chrome cannot reach an
authenticated extension, Whisper falls back to the Accessibility selection
after a short timeout, without in-page highlighting.

The bridge is fixed to `ws://127.0.0.1:17777`. A fresh mutual HMAC-SHA256
challenge authenticates every connection; the pairing secret itself never
crosses the socket. See [ChromeExtension/README.md](ChromeExtension/README.md)
for setup details and [ChromeExtension/PROTOCOL.md](ChromeExtension/PROTOCOL.md)
for the wire contract.

## First launch

Whisper needs two macOS permissions for the complete dictation and reading
workflow:

- Microphone, to record speech.
- Accessibility, to run the listen-only Shift/Option-key monitor, read native
  selections, and insert text into the active app.

The control center and Settings show a separate row and action for every
permission and link to the relevant System Settings page. Accessibility must be
enabled before Whisper starts its global modifier monitor.

The OpenAI key is entered explicitly in Settings and stored in macOS Keychain. Whisper never scans the working directory or imports secrets from `.env`, and the key is never included in the app bundle, source control, or logs.

Transcription uses `gpt-4o-transcribe` through the bounded file-upload workflow documented in the [OpenAI speech-to-text guide](https://developers.openai.com/api/docs/guides/speech-to-text).

## Build

Requirements:

- macOS 14 or newer on Apple Silicon
- Swift 6 command-line tools
- Node.js/npm and Python 3 for bundled extension/worker validation
- `uv` available in `~/.local/bin`, `~/.cargo/bin`, Homebrew, or `PATH` for the
  first managed Qwen runtime setup

Create the stable local self-signed identity once with macOS Keychain Access:

1. Open **Certificate Assistant > Create a Certificate**.
2. Use the name `Whisper Local Code Signing`, identity type **Self Signed
   Root**, certificate type **Code Signing**, and enable **Override defaults**.
3. Choose 3650 days, RSA 4096, critical key usage **Signature + Certificate
   Signing**, critical extended usage **Code Signing only**, basic constraints
   **CA / path length 0**, no Subject Alternate Name, and the login keychain.
4. In the certificate's Trust panel, set only **Code Signing** to **Always
   Trust**. Leave the general trust setting at **System Defaults**.

The setup script never handles a private key or keychain password. It validates
that existing identity and writes only its public SHA-1 fingerprint to
`Config/LocalCodeSigningIdentity.sha1`:

```bash
./scripts/setup-local-signing.sh
./scripts/build-app.sh
```

The setup is idempotent and reuses the valid `Whisper Local Code Signing`
identity. Never commit
`Config/LocalCodeSigningIdentity.sha1`; it is machine-local (the adjacent
`.example` file documents its format).

The build fails closed when no identity is configured. To use another
certificate, pass its exact 40-character SHA-1 fingerprint as
`WHISPER_CODESIGN_IDENTITY`. Ad-hoc signing is available only as an explicit,
unstable development escape hatch:

```bash
WHISPER_ALLOW_ADHOC=1 WHISPER_CODESIGN_IDENTITY=- ./scripts/build-app.sh
```

An ad-hoc rebuild changes the app identity and is rejected by the installer.
Distribution additionally requires Developer ID signing and notarization.

The resulting bundle is written to:

```text
dist/Whisper.app
```

Open it directly for local development:

```bash
open dist/Whisper.app
```

Migrate an older ad-hoc installation exactly once with the explicit migration
flag. First choose **Quit Whisper** and confirm that `pgrep -x Whisper` prints
nothing; replacing the bundle while the old process is alive can recreate a TCC
decision for its obsolete code identity. Then run:

```bash
WHISPER_ALLOW_IDENTITY_MIGRATION=1 ./scripts/install-app.sh
```

Continue only if the installer exits successfully and prints `Installed
/Applications/Whisper.app`. Then reset only Whisper's obsolete Accessibility
decision:

```bash
/usr/bin/tccutil reset Accessibility com.nekoneki.whisper-dictation.app
```

Launch the new bundle only after that reset succeeds:

```bash
open /Applications/Whisper.app
```

The scoped `tccutil` command removes only Whisper's old Accessibility decision.
macOS then requires Accessibility to be enabled once for the newly stable
identity. Microphone access may likewise prompt once after this identity
migration. Keychain may ask once whether the
newly signed Whisper can use the already saved OpenAI key: choose **Always
Allow**. Do not delete or reset the stored key. The installer never changes TCC
permissions automatically. Do not use the migration flag for normal updates.

Install every later update only through the guarded installer:

```bash
./scripts/install-app.sh
```

It verifies signature integrity and a certificate-backed designated
requirement before copying. The one-time override accepts only an older ad-hoc
build with the same bundle identifier. A different certificate is always
refused, and the pinned fingerprint cannot rotate silently. Updates use an
atomic no-clobber rename, a per-destination lock, signature revalidation, and a
recoverable backup transaction. Launch at Login is managed by macOS
`SMAppService` from Whisper Settings, so no LaunchAgent or secondary helper is
required.

## Architecture

`WhisperCore` owns the deterministic left-Shift/right-Option routing, dictation
gesture state machine, sentence/token navigation, and multipart request
construction. `WhisperApp` is a single native process built with SwiftUI,
AppKit, AVFoundation, CoreGraphics, ApplicationServices, CryptoKit,
NaturalLanguage, Network, Security, and ServiceManagement.

The same app records dictation, streams local Qwen PCM through AVFoundation, and
hosts the loopback-only Chrome WebSocket server. A managed MLX worker performs
model inference while the app is open. Chrome's static extension
captures the page selection and renders the follow-along UI; it does not speak
text or launch a separate native host. During playback, the app sends
synchronized state and UTF-16 boundaries to the authenticated extension. The
first Qwen use installs the pinned `mlx-audio` runtime and downloads the
1.7B bfloat16 model; later reading is local and reuses that cache.

Audio is written to a private temporary file and removed after success, failure, or cancellation. Whisper does not persist transcripts or record their content in logs. After transcription, Whisper writes the complete text to the shared clipboard and invokes the destination application's standard Paste menu command through Accessibility, which is independent of the active keyboard layout. If that command is unavailable, Whisper inserts through the native editable Accessibility value or targeted Unicode text events. Neither fallback emits a physical V key or Command modifier, so Russian keyboard layouts and remappers such as Karabiner-Elements cannot translate the insertion into «м». The transcript remains in the clipboard after a successful insertion. If the destination changes or insertion cannot finish, the clipboard still contains the transcript and the latest text also remains in memory for an optional retry, but it never blocks the next dictation.

A per-user process lock and `LSMultipleInstancesProhibited` prevent duplicate global monitors, recordings, uploads, and insertions. Launch at Login is opt-in and is never enabled automatically.

Run the deterministic verification suite directly with:

```bash
./scripts/test-core.sh
./scripts/test-app-state.sh
./scripts/test-hud-layout.sh
./scripts/test-services.sh
cd ChromeExtension
npm test
npm run check
```

The service suite uses an in-process URL loader stub, an isolated Keychain item, and private temporary directories; it never contacts OpenAI or starts the microphone. The repository also includes XCTest coverage for environments with a complete Xcode toolchain.
