# Whisper Dictation

A small personal macOS menu-bar dictation and local text-to-speech app.

I use it as a lightweight replacement for heavier dictation tools: tap Shift, then press Shift again to start recording, and tap Shift once more to stop and paste the transcript into the active app. Tap Option, then press Option again to read the currently selected text aloud locally. The default local reader uses MLX Chatterbox on Apple Silicon for higher-quality Russian and English speech, then falls back to Kokoro/Piper/Silero if needed. It also keeps a tiny monthly cost counter and shows a compact bottom-right voice indicator while recording, transcribing, generating speech, or speaking.

## What It Does

- Runs quietly from the macOS menu bar.
- Uses OpenAI `whisper-1` for speech-to-text.
- Starts recording with a two-press Shift gesture.
- Speaks selected Russian or English text locally with a two-press Option gesture.
- Copies the transcript to the clipboard and pastes it with Cmd+V.
- Temporarily uses Cmd+C to read selected text, then restores the text clipboard.
- Shows logs and estimated Whisper spend for the current month.
- Displays an animated bottom-right indicator while recording, processing, generating speech, and speaking.
- Keeps the speech indicator visible during local TTS playback with playback progress and 5-second seek controls.
- Lets you adjust local TTS speed in the logs/settings window.

## Requirements

- macOS
- Python 3.10+
- Microphone permission for the terminal/app launcher you use
- Accessibility permission for paste/copy automation
- An OpenAI API key

## Setup

```bash
cp .env.example .env
```

Edit `.env`:

```bash
OPENAI_API_KEY=your_openai_api_key_here
```

Run it:

```bash
./run.sh
```

`run.sh` creates `venv-tts` with Python 3.10-3.13. This is required because `kokoro-onnx` does not support Python 3.14 yet.

The first high-quality local TTS use downloads the MLX Chatterbox model from Hugging Face into the normal Hugging Face cache. The current default is:

```text
mlx-community/chatterbox-fp16
```

This model is about 2.6 GB and supports Russian and English. Speech is generated at natural pitch and then accelerated with Rubber Band when available.

The fallback English local TTS use downloads Kokoro ONNX model files into:

```text
~/.whisper_dictation_tts/models
```

Russian local TTS uses this order:

1. Silero `v4_ru.pt` from the PyTorch cache, if it is already available.
2. Piper `ru_RU-ruslan-medium` ONNX from:

```text
~/.whisper_dictation_tts/piper
```

3. The local macOS Russian voice `Milena` only if both neural engines fail.

Runtime logs are written to:

```text
~/.whisper_dictation/whisper_dictation.log
~/.whisper_dictation/run.log
```

TTS speed is stored in:

```text
~/.whisper_dictation_tts.json
```

## Controls

- Tap `Shift`, then press `Shift` again: start dictation; releasing `Shift` keeps recording.
- Tap `Shift` while recording: stop and transcribe.
- Press `Shift` while transcribing: cancel transcription.
- Tap `Option`, then press `Option` again: copy the current selection and speak it locally.
- Press `Option` while speaking: stop local TTS.
- While local TTS is speaking, use the bottom-right speech widget as a mini player: 5-second back/forward, pause/resume, close, or drag/click the progress bar to scrub. When playback ends, the widget stays visible until you close it.
- Any normal key press or combined modifier shortcut blocks new `Shift`/`Option` gestures for 2 seconds.
- Menu bar icon -> `View Logs & Cost`: view logs, Whisper cost, and change TTS speed.

Local TTS defaults:

- Primary engine: MLX Chatterbox `mlx-community/chatterbox-fp16`.
- Fallback English engine: Kokoro ONNX.
- Fallback Russian engine: Silero TTS, then Piper ONNX fallback.
- English voice: `am_adam`.
- Russian voices: Silero `xenia`, Piper `ruslan-medium`.
- Language: `en-us`.
- Speed: `2.00x`, adjustable from `0.65x` to `3.00x`.

You can override voice/language/model quality before launch:

```bash
LOCAL_TTS_MLX_MODEL=mlx-community/chatterbox-fp16 LOCAL_TTS_MLX_CFG_WEIGHT=0.45 LOCAL_TTS_MLX_EXAGGERATION=0.35 LOCAL_TTS_VOICE=am_michael LOCAL_TTS_PIPER_RU_VOICE=dmitri ./run.sh
```

## macOS Startup

The simplest startup setup is an Automator app:

1. Open Automator.
2. Create a new `Application`.
3. Add `Run Shell Script`.
4. Use this script, replacing the path with your local checkout:

```bash
#!/bin/bash
cd /path/to/whisper_dictation
./run.sh &
```

Save it as `StartWhisper.app`, then add it in `System Settings -> General -> Login Items`.

## Notes

The app stores monthly estimated transcription spend in `~/.openai_voice_costs.json`. The `.env` file is intentionally ignored and should not be committed.

The selected-text reader works through normal macOS copy behavior. If an app does not expose selected text through `Cmd+C`, there will be nothing to speak.
