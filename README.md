# Whisper Dictation

A small personal macOS menu-bar dictation app built around OpenAI Whisper.

I use it as a lightweight replacement for heavier dictation tools: tap Shift, hold Shift to record, release/tap again to stop, and the transcribed text is pasted into the active app. It also keeps a tiny monthly cost counter and shows a fullscreen voice meter overlay while recording.

## What It Does

- Runs quietly from the macOS menu bar.
- Uses OpenAI `whisper-1` for speech-to-text.
- Starts recording with a tap-then-hold Shift gesture.
- Copies the transcript to the clipboard and pastes it with Cmd+V.
- Shows logs and estimated Whisper spend for the current month.
- Displays an animated voice-level overlay while recording.

## Requirements

- macOS
- Python 3.10+
- Microphone permission for the terminal/app launcher you use
- Accessibility permission for paste automation
- An OpenAI API key

## Setup

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
```

Edit `.env`:

```bash
OPENAI_API_KEY=your_openai_api_key_here
```

Run it:

```bash
python main.py
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
./venv/bin/python main.py &
```

Save it as `StartWhisper.app`, then add it in `System Settings -> General -> Login Items`.

## Notes

The app stores monthly estimated transcription spend in `~/.openai_voice_costs.json`. The `.env` file is intentionally ignored and should not be committed.

