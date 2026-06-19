import array
import ctypes
import json
import logging
import math
import os
import random
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import wave
from dataclasses import dataclass
from datetime import datetime
from logging.handlers import RotatingFileHandler
from pathlib import Path

import objc
import pyaudio
import pyperclip
from AppKit import (
    NSApplication,
    NSEvent,
    NSEventModifierFlagCapsLock,
    NSEventModifierFlagCommand,
    NSEventModifierFlagControl,
    NSEventModifierFlagFunction,
    NSEventModifierFlagOption,
    NSEventModifierFlagShift,
    NSImage,
    NSPasteboard,
    NSPasteboardTypeString,
    NSScreenSaverWindowLevel,
    NSStatusBar,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowCollectionBehaviorIgnoresCycle,
    NSWindowCollectionBehaviorStationary,
)
from dotenv import load_dotenv
from Foundation import NSObject
from openai import OpenAI
from PyQt6.QtCore import QObject, QPointF, QRectF, Qt, QThread, QTimer, pyqtSignal
from PyQt6.QtGui import QBrush, QColor, QCursor, QFont, QIcon, QPainter, QPen, QPixmap, QPolygonF
from PyQt6.QtWidgets import QApplication, QHBoxLayout, QLabel, QMenu, QPlainTextEdit, QPushButton, QSlider, QSystemTrayIcon, QVBoxLayout, QWidget


load_dotenv()

APP_NAME = "Whisper Dictation"
API_KEY = os.getenv("OPENAI_API_KEY")
if not API_KEY:
    print("ERROR: OPENAI_API_KEY is missing. Create .env next to main.py and set OPENAI_API_KEY.")
    sys.exit(1)


@dataclass(frozen=True)
class AudioConfig:
    format: int = pyaudio.paInt16
    channels: int = 1
    rate: int = 44_100
    chunk: int = 1024
    max_record_seconds: float = 120.0
    min_chunks: int = 10
    whisper_price_per_minute: float = 0.006
    input_device: str = os.getenv("WHISPER_INPUT_DEVICE", "").strip()
    prefer_new_input_device: bool = os.getenv("WHISPER_PREFER_NEW_INPUT_DEVICE", "1").lower() not in ("0", "false", "no", "off")
    prefer_external_input_device: bool = os.getenv("WHISPER_PREFER_EXTERNAL_INPUT_DEVICE", "1").lower() not in (
        "0",
        "false",
        "no",
        "off",
    )


@dataclass(frozen=True)
class HotkeyConfig:
    hold_threshold: float = 1.0
    tap_max_duration: float = 0.8
    tap_arm_window: float = 8.0
    dirty_key_cooldown: float = 2.0


@dataclass(frozen=True)
class TextToSpeechConfig:
    engine: str = os.getenv("LOCAL_TTS_ENGINE", "mlx_chatterbox")
    quality: str = os.getenv("LOCAL_TTS_QUALITY", "int8")
    voice: str = os.getenv("LOCAL_TTS_VOICE", "am_adam")
    lang: str = os.getenv("LOCAL_TTS_LANG", "en-us")
    russian_speaker: str = os.getenv("LOCAL_TTS_RU_SPEAKER", "xenia")
    russian_sample_rate: int = int(os.getenv("LOCAL_TTS_RU_SAMPLE_RATE", "48000"))
    chunk_chars: int = int(os.getenv("LOCAL_TTS_CHUNK_CHARS", "420"))
    max_chars: int = int(os.getenv("LOCAL_TTS_MAX_CHARS", "200000"))
    mlx_model: str = os.getenv("LOCAL_TTS_MLX_MODEL", "mlx-community/chatterbox-fp16")
    mlx_exaggeration: float = float(os.getenv("LOCAL_TTS_MLX_EXAGGERATION", "0.35"))
    mlx_cfg_weight: float = float(os.getenv("LOCAL_TTS_MLX_CFG_WEIGHT", "0.45"))
    mlx_temperature: float = float(os.getenv("LOCAL_TTS_MLX_TEMPERATURE", "0.70"))
    mlx_max_tokens: int = int(os.getenv("LOCAL_TTS_MLX_MAX_TOKENS", "1400"))


AUDIO = AudioConfig()
HOTKEY = HotkeyConfig()
TTS = TextToSpeechConfig()
COST_FILE = os.path.expanduser("~/.openai_voice_costs.json")
TTS_SETTINGS_FILE = os.path.expanduser("~/.whisper_dictation_tts.json")
TTS_STOP_FILE = os.path.expanduser("~/.whisper_dictation_tts_stop")
DEFAULT_TTS_SPEED = 2.00
TTS_SPEED_STEP = 0.10
TTS_ACTIVITY_TIMEOUT_SECONDS = 180.0
TTS_DIAGNOSTIC_INTERVAL_SECONDS = 10.0
TTS_ACTIVE_STATES = ("generating", "speaking")
TTS_WIDGET_STATES = ("generating", "speaking", "tts_finished")
HOTKEY_IDLE_STATES = ("idle", "done", "tts_finished")
TTS_MODEL_DIR = Path(os.path.expanduser("~/.whisper_dictation_tts/models"))
PIPER_MODEL_DIR = Path(os.path.expanduser("~/.whisper_dictation_tts/piper"))
LOG_DIR = Path(os.path.expanduser("~/.whisper_dictation"))
LOG_FILE = LOG_DIR / "whisper_dictation.log"
SILERO_REPO_DIR = Path(os.path.expanduser("~/.cache/torch/hub/snakers4_silero-models_master"))
SILERO_RU_MODEL_FILE = SILERO_REPO_DIR / "src/silero/model/v4_ru.pt"
PIPER_RU_VOICE = os.getenv("LOCAL_TTS_PIPER_RU_VOICE", "ruslan")
PIPER_RU_QUALITY = os.getenv("LOCAL_TTS_PIPER_RU_QUALITY", "medium")
PIPER_RU_MODEL_FILE = PIPER_MODEL_DIR / f"ru_RU-{PIPER_RU_VOICE}-{PIPER_RU_QUALITY}.onnx"
PIPER_RU_CONFIG_FILE = PIPER_MODEL_DIR / f"ru_RU-{PIPER_RU_VOICE}-{PIPER_RU_QUALITY}.onnx.json"
PIPER_RU_MODEL_URL = (
    f"https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/ru/ru_RU/{PIPER_RU_VOICE}/{PIPER_RU_QUALITY}/"
    f"ru_RU-{PIPER_RU_VOICE}-{PIPER_RU_QUALITY}.onnx"
)
PIPER_RU_CONFIG_URL = (
    f"https://huggingface.co/rhasspy/piper-voices/resolve/v1.0.0/ru/ru_RU/{PIPER_RU_VOICE}/{PIPER_RU_QUALITY}/"
    f"ru_RU-{PIPER_RU_VOICE}-{PIPER_RU_QUALITY}.onnx.json"
)
LOCK_FILE = os.path.expanduser("~/.whisper_dictation.lock")
KEY_CODE_C = 8
KEY_CODE_V = 9
CG_EVENT_FLAG_MASK_COMMAND = 1 << 20
NSEVENT_MASK_FLAGS_CHANGED = 1 << 12
NSEVENT_MASK_KEY_DOWN = 1 << 10
HOTKEY_MODIFIER_MASK = (
    NSEventModifierFlagShift
    | NSEventModifierFlagOption
    | NSEventModifierFlagControl
    | NSEventModifierFlagCommand
    | NSEventModifierFlagCapsLock
    | NSEventModifierFlagFunction
)
KOKORO_MODEL_URLS = {
    "int8": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.int8.onnx",
    "fp16": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.fp16.onnx",
    "f32": "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx",
}
KOKORO_VOICES_URL = "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/voices-v1.0.bin"

logger = logging.getLogger("WhisperDictation")
logger.setLevel(logging.INFO)
client = OpenAI(api_key=API_KEY)


def configure_file_logging():
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    if any(isinstance(handler, RotatingFileHandler) and getattr(handler, "baseFilename", "") == str(LOG_FILE) for handler in logger.handlers):
        return
    file_handler = RotatingFileHandler(LOG_FILE, maxBytes=2_000_000, backupCount=5, encoding="utf-8")
    file_handler.setFormatter(
        logging.Formatter("%(asctime)s %(levelname)s [pid=%(process)d thread=%(threadName)s] %(message)s")
    )
    logger.addHandler(file_handler)


class SingleInstanceLock:
    def __init__(self, path):
        self.path = path
        self.handle = None

    def acquire(self):
        if sys.platform != "darwin":
            return True
        import fcntl

        self.handle = open(self.path, "w")
        try:
            fcntl.flock(self.handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return False
        self.handle.write(str(os.getpid()))
        self.handle.truncate()
        self.handle.flush()
        return True


class CostManager:
    def __init__(self):
        self.current_month = datetime.now().strftime("%Y-%m")
        self.total_cost = 0.0
        self._load()

    def _load(self):
        if not os.path.exists(COST_FILE):
            return
        try:
            with open(COST_FILE, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            if data.get("month") == self.current_month:
                self.total_cost = float(data.get("total_cost", 0.0))
        except Exception as exc:
            logger.warning("Could not read cost file: %s", exc)

    def _save(self):
        try:
            with open(COST_FILE, "w", encoding="utf-8") as fh:
                json.dump({"month": self.current_month, "total_cost": self.total_cost}, fh)
        except Exception as exc:
            logger.warning("Could not save cost file: %s", exc)

    def add_recording(self, duration_seconds):
        now_month = datetime.now().strftime("%Y-%m")
        if now_month != self.current_month:
            self.current_month = now_month
            self.total_cost = 0.0
        cost = (duration_seconds / 60.0) * AUDIO.whisper_price_per_minute
        self.total_cost += cost
        self._save()
        return cost, self.total_cost


cost_manager = CostManager()


class AudioInputDeviceSelector:
    BUILTIN_HINTS = (
        "built-in",
        "builtin",
        "macbook",
        "mac mini",
        "imac",
        "studio display",
    )
    VIRTUAL_HINTS = (
        "blackhole",
        "soundflower",
        "loopback",
        "background music",
        "vb-cable",
        "cable input",
        "cable output",
        "zoomaudio",
        "teams audio",
        "aggregate device",
        "multi-output",
    )
    EXTERNAL_HINTS = (
        "airpods",
        "anker",
        "at20",
        "audio-technica",
        "bluetooth",
        "blue",
        "bose",
        "comica",
        "dji",
        "elgato",
        "fifine",
        "focusrite",
        "headset",
        "hyperx",
        "jabra",
        "lark",
        "maono",
        "mv7",
        "nt-usb",
        "rode",
        "saramonic",
        "scarlett",
        "shure",
        "sony",
        "usb",
        "wave",
        "wireless",
        "yeti",
    )

    def __init__(self):
        self._known_input_keys = None
        self._lock = threading.Lock()

    def refresh_baseline(self):
        audio = pyaudio.PyAudio()
        try:
            devices = self._input_devices(audio)
            with self._lock:
                self._known_input_keys = {self._device_key(device) for device in devices}
            logger.info("Audio input baseline: %s", self._describe_devices(devices))
        except Exception as exc:
            logger.warning("Could not refresh audio input baseline: %s", exc)
        finally:
            audio.terminate()

    def resolve(self, audio):
        devices = self._input_devices(audio)
        if not devices:
            logger.warning("No enumerated audio input devices; using system default input")
            return self._selection(None, "system default input", AUDIO.rate, "no enumerated input devices")

        current_keys = {self._device_key(device) for device in devices}
        selected = None
        reason = ""

        configured = self._configured_device(devices)
        if configured is not None:
            selected = configured
            reason = "WHISPER_INPUT_DEVICE"

        if selected is None and AUDIO.prefer_new_input_device:
            with self._lock:
                known_keys = self._known_input_keys
            if known_keys is not None:
                new_devices = [device for device in devices if self._device_key(device) not in known_keys]
                if new_devices:
                    selected = self._best_device(new_devices, allow_virtual=False) or self._best_device(new_devices)
                    reason = "new input device"

        if selected is None:
            default_device = self._default_input_device(audio, devices)
            external_device = self._best_external_device(devices)
            if default_device is not None and (
                not AUDIO.prefer_external_input_device
                or (not self._is_builtin(default_device) and not self._is_virtual(default_device))
                or external_device is None
            ):
                selected = default_device
                reason = "system default input"
            elif external_device is not None:
                selected = external_device
                reason = "external input device"
            else:
                selected = default_device or self._best_device(devices)
                reason = "available input device"

        with self._lock:
            self._known_input_keys = current_keys

        if selected is None:
            logger.warning("Could not choose an input device; using system default input")
            return self._selection(None, "system default input", AUDIO.rate, "device selection fallback")

        logger.info(
            "Selected audio input: index=%s name=%r rate=%s reason=%s devices=%s",
            selected["index"],
            selected["name"],
            selected["rate"],
            reason,
            self._describe_devices(devices),
        )
        return self._selection(selected["index"], selected["name"], selected["rate"], reason)

    def _input_devices(self, audio):
        devices = []
        for index in range(audio.get_device_count()):
            try:
                info = audio.get_device_info_by_index(index)
            except Exception as exc:
                logger.warning("Could not read audio device %s: %s", index, exc)
                continue
            channels = int(info.get("maxInputChannels") or 0)
            if channels <= 0:
                continue
            devices.append(
                {
                    "index": int(info.get("index", index)),
                    "name": str(info.get("name") or f"Input {index}"),
                    "channels": channels,
                    "rate": self._normalized_rate(info.get("defaultSampleRate")),
                    "host_api": int(info.get("hostApi", -1)),
                }
            )
        return devices

    def _configured_device(self, devices):
        wanted = AUDIO.input_device
        if not wanted:
            return None
        if wanted.isdigit():
            wanted_index = int(wanted)
            for device in devices:
                if device["index"] == wanted_index:
                    return device
        wanted_lower = wanted.lower()
        for device in devices:
            if wanted_lower in device["name"].lower():
                return device
        logger.warning("WHISPER_INPUT_DEVICE=%r did not match any input device", wanted)
        return None

    def _default_input_device(self, audio, devices):
        try:
            default_info = audio.get_default_input_device_info()
        except Exception as exc:
            logger.warning("Could not read default input device: %s", exc)
            return None
        default_index = int(default_info.get("index", -1))
        for device in devices:
            if device["index"] == default_index:
                return device
        return {
            "index": default_index,
            "name": str(default_info.get("name") or "system default input"),
            "channels": int(default_info.get("maxInputChannels") or AUDIO.channels),
            "rate": self._normalized_rate(default_info.get("defaultSampleRate")),
            "host_api": int(default_info.get("hostApi", -1)),
        }

    def _best_external_device(self, devices):
        external_devices = [
            device for device in devices if not self._is_builtin(device) and not self._is_virtual(device)
        ]
        if not external_devices:
            return None
        return self._best_device(external_devices, allow_virtual=False)

    def _best_device(self, devices, allow_virtual=True):
        candidates = [device for device in devices if allow_virtual or not self._is_virtual(device)]
        if not candidates:
            return None
        return max(candidates, key=lambda device: (self._score_device(device), device["index"]))

    def _score_device(self, device):
        name = device["name"].lower()
        score = min(device["channels"], 8)
        if "microphone" in name or "mic" in name:
            score += 18
        if any(hint in name for hint in self.EXTERNAL_HINTS):
            score += 35
        if self._is_builtin(device):
            score -= 60
        if self._is_virtual(device):
            score -= 80
        return score

    def _is_builtin(self, device):
        name = device["name"].lower()
        return any(hint in name for hint in self.BUILTIN_HINTS)

    def _is_virtual(self, device):
        name = device["name"].lower()
        return any(hint in name for hint in self.VIRTUAL_HINTS)

    def _normalized_rate(self, value):
        try:
            rate = int(round(float(value)))
        except (TypeError, ValueError):
            return AUDIO.rate
        if 8_000 <= rate <= 192_000:
            return rate
        return AUDIO.rate

    def _device_key(self, device):
        return (device["index"], device["host_api"], device["name"], device["channels"])

    def _selection(self, index, name, rate, reason):
        return {
            "index": index,
            "name": name,
            "rate": self._normalized_rate(rate),
            "reason": reason,
        }

    def _describe_devices(self, devices):
        if not devices:
            return "none"
        return ", ".join(
            f'{device["index"]}:{device["name"]} ch={device["channels"]} rate={device["rate"]}'
            for device in devices
        )


input_device_selector = AudioInputDeviceSelector()


class TextToSpeechSettings:
    def __init__(self):
        self.speed = DEFAULT_TTS_SPEED
        self._load()

    def _load(self):
        if not os.path.exists(TTS_SETTINGS_FILE):
            return
        try:
            with open(TTS_SETTINGS_FILE, "r", encoding="utf-8") as fh:
                data = json.load(fh)
            self.speed = self._clamp_speed(data.get("speed", self.speed))
        except Exception as exc:
            logger.warning("Could not read TTS settings file: %s", exc)

    def save(self):
        try:
            with open(TTS_SETTINGS_FILE, "w", encoding="utf-8") as fh:
                json.dump({"speed": self.speed}, fh)
        except Exception as exc:
            logger.warning("Could not save TTS settings file: %s", exc)

    def reload(self):
        self._load()

    def set_speed(self, speed):
        self.speed = self._clamp_speed(speed)
        self.save()

    def _clamp_speed(self, speed):
        try:
            speed = float(speed)
        except (TypeError, ValueError):
            speed = DEFAULT_TTS_SPEED
        return max(0.65, min(3.0, speed))


tts_settings = TextToSpeechSettings()


def detect_tts_language(text):
    cyrillic_count = len(re.findall(r"[А-Яа-яЁё]", text))
    latin_count = len(re.findall(r"[A-Za-z]", text))
    if cyrillic_count >= max(3, latin_count):
        return "ru"
    return "en"


def split_text_chunks(text, chunk_chars):
    normalized = re.sub(r"\s+", " ", text).strip()
    if not normalized:
        return []
    pieces = re.split(r"(?<=[.!?;:])\s+", normalized)
    chunks = []
    current = ""
    for piece in pieces:
        if len(piece) > chunk_chars:
            if current:
                chunks.append(current)
                current = ""
            chunks.extend(hard_wrap_text(piece, chunk_chars))
            continue
        candidate = f"{current} {piece}".strip()
        if len(candidate) <= chunk_chars:
            current = candidate
        else:
            if current:
                chunks.append(current)
            current = piece
    if current:
        chunks.append(current)
    return chunks


def hard_wrap_text(text, chunk_chars):
    chunks = []
    current = ""
    for word in text.split(" "):
        candidate = f"{current} {word}".strip()
        if len(candidate) <= chunk_chars:
            current = candidate
        else:
            if current:
                chunks.append(current)
            current = word
    if current:
        chunks.append(current)
    return chunks


class QtLogHandler(logging.Handler, QObject):
    log_signal = pyqtSignal(str)

    def __init__(self):
        logging.Handler.__init__(self)
        QObject.__init__(self)

    def emit(self, record):
        self.log_signal.emit(self.format(record))


class LogWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.controller = None
        self.setWindowTitle("Whisper Logs & Costs")
        self.resize(560, 360)

        layout = QVBoxLayout()
        self.cost_label = QLabel()
        self.cost_label.setStyleSheet("font-size: 16px; font-weight: 700; color: #4CAF50; padding: 10px;")
        layout.addWidget(self.cost_label)

        speed_row = QHBoxLayout()
        speed_title = QLabel("TTS speed")
        speed_title.setStyleSheet("font-size: 13px; font-weight: 700; padding-left: 10px;")
        self.tts_speed_slider = QSlider(Qt.Orientation.Horizontal)
        self.tts_speed_slider.setRange(65, 300)
        self.tts_speed_slider.setSingleStep(5)
        self.tts_speed_slider.setPageStep(10)
        self.tts_speed_slider.setValue(int(round(tts_settings.speed * 100)))
        self.tts_speed_label = QLabel()
        self.tts_speed_label.setMinimumWidth(56)
        self.tts_speed_label.setStyleSheet("font-size: 13px; font-weight: 700; padding-right: 10px;")
        self.tts_speed_slider.valueChanged.connect(self._on_tts_speed_changed)
        speed_row.addWidget(speed_title)
        speed_row.addWidget(self.tts_speed_slider)
        speed_row.addWidget(self.tts_speed_label)
        layout.addLayout(speed_row)

        actions_row = QHBoxLayout()
        actions_row.setContentsMargins(10, 0, 10, 0)
        self.reset_speed_button = QPushButton("Reset Speed")
        self.reset_speed_button.clicked.connect(self._reset_speed)
        self.stop_tts_button = QPushButton("Stop TTS")
        self.stop_tts_button.clicked.connect(self._stop_tts)
        self.quit_button = QPushButton("Quit")
        self.quit_button.clicked.connect(self._quit_app)
        actions_row.addWidget(self.reset_speed_button)
        actions_row.addWidget(self.stop_tts_button)
        actions_row.addStretch(1)
        actions_row.addWidget(self.quit_button)
        layout.addLayout(actions_row)

        self.text_edit = QPlainTextEdit()
        self.text_edit.setReadOnly(True)
        self.text_edit.setFont(QFont("Menlo", 12))
        self.text_edit.setStyleSheet("background-color: #101317; color: #7CFFB2;")
        layout.addWidget(self.text_edit)
        self.setLayout(layout)
        self.update_cost_display()
        self._sync_tts_speed_label()

    def bind_controller(self, controller):
        self.controller = controller

    def append_log(self, text):
        self.text_edit.appendPlainText(text)
        self.text_edit.verticalScrollBar().setValue(self.text_edit.verticalScrollBar().maximum())

    def update_cost_display(self):
        self.cost_label.setText(f"Total Whisper spend ({cost_manager.current_month}): ${cost_manager.total_cost:.5f}")

    def sync_settings_display(self):
        value = int(round(tts_settings.speed * 100))
        if self.tts_speed_slider.value() != value:
            self.tts_speed_slider.blockSignals(True)
            self.tts_speed_slider.setValue(value)
            self.tts_speed_slider.blockSignals(False)
        self._sync_tts_speed_label()

    def _on_tts_speed_changed(self, value):
        tts_settings.set_speed(value / 100.0)
        self._sync_tts_speed_label()

    def _sync_tts_speed_label(self):
        self.tts_speed_label.setText(f"{tts_settings.speed:.2f}x")

    def _reset_speed(self):
        if self.controller is not None:
            self.controller.set_tts_speed(DEFAULT_TTS_SPEED)

    def _stop_tts(self):
        if self.controller is not None:
            self.controller.stop_tts()

    def _quit_app(self):
        if self.controller is not None:
            self.controller.app.quit()


class VoiceMeterOverlay(QWidget):
    tick_ms = 33
    max_particles = 118

    def __init__(self):
        flags = Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool
        super().__init__(None, flags)
        self.setWindowFlag(Qt.WindowType.WindowDoesNotAcceptFocus, True)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

        self.level = 0.0
        self.display_level = 0.0
        self.mode = "idle"
        self.frame = 0
        self.spawn_budget = 0.0
        self.fading_out = False
        self.particles = []

        self.timer = QTimer(self)
        self.timer.timeout.connect(self._animate)
        self.timer.start(self.tick_ms)
        self.hide()

    def show_meter(self):
        self.fading_out = False
        self._cover_current_screen()
        self.show()
        self._apply_macos_window_level()
        self.update()

    def hide_meter(self):
        self.level = 0.0
        self.spawn_budget = 0.0
        self.fading_out = True
        if not self.particles:
            self.fading_out = False
            self.hide()

    def set_mode(self, mode):
        self.mode = mode
        if mode in ("recording", "processing"):
            self.fading_out = False
            self.show_meter()
        else:
            self.hide_meter()

    def set_level(self, level):
        if self.mode != "recording":
            return
        self.level = max(0.0, min(1.0, float(level)))

    def _cover_current_screen(self):
        screen = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
        if screen:
            self.setGeometry(screen.geometry())

    def _animate(self):
        if not self.isVisible() and not self.particles:
            return

        self.frame += 1
        if self.fading_out:
            target_level = 0.0
            smoothing = 0.18
        elif self.mode == "processing":
            target_level = 0.12 + math.sin(self.frame * 0.055) * 0.025
            smoothing = 0.075
        else:
            target_level = self.level
            smoothing = 0.88 if target_level > self.display_level else 0.28

        self.display_level = self.display_level * (1.0 - smoothing) + target_level * smoothing
        self._update_particles()
        if self.isVisible():
            self.update()

    def _update_particles(self):
        level = self.display_level
        if self.fading_out or level < 0.006:
            self.spawn_budget = 0.0
        elif self.mode == "processing":
            self.spawn_budget += 0.34 + level * 2.6
        else:
            burst = 1.0 + max(0.0, level - 0.16) * 3.4
            self.spawn_budget += 0.24 + level * level * 5.9 * burst

        spawn_cap = 5 if self.mode == "processing" else 10
        spawn_count = min(int(self.spawn_budget), spawn_cap, self.max_particles - len(self.particles))
        self.spawn_budget -= spawn_count
        for _ in range(max(0, spawn_count)):
            self._spawn_particle(level)

        next_particles = []
        for particle in self.particles:
            age = 1.0 - (particle["life"] / particle["max_life"])
            jitter = (0.025 + level * 0.28) * particle["chaos"]
            curl_x = math.sin((self.frame * particle["curl_speed"]) + particle["phase"]) * particle["curl"]
            curl_y = math.cos((self.frame * particle["curl_speed"] * 1.37) + particle["phase"]) * particle["curl"]
            if random.random() < particle["snap_chance"] + level * 0.025:
                particle["vx"] -= random.uniform(0.10, 0.44) * (0.55 + level)
                particle["vy"] += random.uniform(-0.28, 0.28) * (0.45 + level)

            particle["life"] -= 4 if self.fading_out else 1
            particle["vx"] += random.uniform(-jitter, jitter) + curl_x * 0.04 + particle["pull"]
            particle["vy"] += random.uniform(-jitter, jitter) + curl_y * 0.05
            particle["x"] += particle["vx"] + curl_x
            particle["y"] += particle["vy"] + curl_y
            particle["vx"] *= 0.976 + particle["glide"] * 0.012
            particle["vy"] *= 0.962 + particle["glide"] * 0.018
            particle["vy"] += math.sin(age * math.tau + particle["phase"]) * 0.025
            particle["spark"] = (particle["spark"] + 1) % particle["spark_mod"]
            particle["size"] *= 0.998 if age < 0.72 else 0.985

            if particle["life"] > 0 and -60 < particle["x"] < self.width() + 80 and particle["size"] > 0.35:
                next_particles.append(particle)

        self.particles = next_particles[-self.max_particles :]
        if self.fading_out and not self.particles:
            self.fading_out = False
            self.hide()

    def _spawn_particle(self, level):
        w = max(1, self.width())
        h = max(1, self.height())

        emitter_x = w - random.uniform(3.0, 18.0)
        if self.mode == "processing":
            line_top = h * 0.70
            line_bottom = h * 0.88
        else:
            line_top = h * 0.60
            line_bottom = h * 0.84
        source_y = random.uniform(line_top, line_bottom)
        source_y += random.uniform(-18.0, 18.0) * (0.4 + level)

        if self.mode == "processing":
            speed = random.uniform(0.035, 0.16) + level * random.uniform(0.05, 0.24)
            angle = math.pi + random.gauss(0.0, 0.12)
        else:
            speed = random.uniform(0.38, 1.05) + level * random.uniform(0.95, 2.55)
            angle = math.pi + random.gauss(0.0, 0.24)
            if random.random() < 0.16 + level * 0.10:
                angle += random.choice((-1.0, 1.0)) * random.uniform(0.18, 0.54)

        hue_roll = random.random()
        if self.mode == "processing":
            palette = (
                (255, 77, 77),
                (255, 110, 92),
                (255, 156, 125),
                (255, 205, 180),
            )
        else:
            palette = (
                (119, 244, 255),
                (168, 255, 219),
                (255, 244, 170),
                (255, 160, 230),
                (216, 236, 255),
            )
        color = palette[min(len(palette) - 1, int(hue_roll * len(palette)))]
        life = random.randint(62, 126) + int(level * 34)

        curl = random.uniform(0.01, 0.11) + level * 0.22
        chaos = random.uniform(0.025, 0.09) + level * random.uniform(0.04, 0.16)
        pull = -random.uniform(0.010, 0.038) - level * random.uniform(0.02, 0.07)
        trail = random.uniform(18.0, 34.0) + level * 28.0
        snap_chance = random.uniform(0.004, 0.014)
        if self.mode == "processing":
            curl *= 0.22
            chaos *= 0.20
            pull *= 0.12
            trail = random.uniform(20.0, 42.0)
            snap_chance = random.uniform(0.001, 0.003)

        self.particles.append(
            {
                "x": emitter_x,
                "y": source_y,
                "vx": math.cos(angle) * speed,
                "vy": math.sin(angle) * speed * 0.72,
                "size": random.choice((2.0, 2.0, 3.0, 3.0, 4.0)) + level * random.choice((0.0, 1.0, 2.0)),
                "life": life,
                "max_life": life,
                "color": color,
                "alpha": random.randint(205, 255),
                "phase": random.uniform(0.0, math.tau),
                "curl": curl,
                "curl_speed": random.uniform(0.055, 0.18) + level * 0.045,
                "chaos": chaos,
                "glide": random.random(),
                "pull": pull,
                "snap_chance": snap_chance,
                "trail": trail,
                "trail_steps": random.randint(5, 9),
                "spark": random.randint(0, 8),
                "spark_mod": random.randint(2, 8),
            }
        )

    def _apply_macos_window_level(self):
        if sys.platform != "darwin":
            return
        if os.environ.get("QT_QPA_PLATFORM") == "offscreen":
            return
        try:
            native_view = objc.objc_object(c_void_p=ctypes.c_void_p(int(self.winId())))
            native_window = native_view.window()
            if native_window is None:
                return
            behavior = (
                NSWindowCollectionBehaviorCanJoinAllSpaces
                | NSWindowCollectionBehaviorFullScreenAuxiliary
                | NSWindowCollectionBehaviorStationary
                | NSWindowCollectionBehaviorIgnoresCycle
            )
            native_window.setLevel_(NSScreenSaverWindowLevel)
            native_window.setCollectionBehavior_(behavior)
            native_window.setIgnoresMouseEvents_(True)
            native_window.orderFrontRegardless()
        except Exception as exc:
            logger.warning("Voice meter native window setup failed: %s", exc)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, False)
        painter.setPen(Qt.PenStyle.NoPen)

        for particle in self.particles:
            life_ratio = max(0.0, min(1.0, particle["life"] / particle["max_life"]))
            fade = math.sin(life_ratio * math.pi) if life_ratio < 0.98 else 1.0
            twinkle = 1.0 if particle["spark"] else 1.55
            alpha = int(particle["alpha"] * fade * min(1.0, twinkle))
            if alpha <= 0:
                continue

            r, g, b = particle["color"]
            size = particle["size"]
            x = particle["x"]
            y = particle["y"]
            trail_len = particle["trail"] * (0.70 + self.display_level * 0.95)
            steps = particle["trail_steps"]
            step_size = max(1.0, min(3.0, size - 0.5))
            for step in range(1, steps + 1):
                step_ratio = step / steps
                tail_x = x - particle["vx"] * trail_len * step_ratio
                tail_y = y - particle["vy"] * trail_len * step_ratio
                tail_alpha = int(alpha * 0.58 * (1.0 - step_ratio))
                if tail_alpha <= 3:
                    continue
                painter.setBrush(QBrush(QColor(r, g, b, tail_alpha)))
                painter.drawRect(QRectF(round(tail_x), round(tail_y), step_size, step_size))

            painter.setBrush(QBrush(QColor(r, g, b, alpha)))
            painter.drawRect(QRectF(x - size * 0.5, y - size * 0.5, size, size))

            if particle["spark"] == 0 and alpha > 80:
                painter.setBrush(QBrush(QColor(255, 255, 245, int(alpha * 0.62))))
                painter.drawRect(QRectF(x - 1.0, y - size - 1.0, 2.0, max(1.0, size * 0.55)))
                painter.drawRect(QRectF(x - size - 1.0, y - 1.0, max(1.0, size * 0.55), 2.0))

            if particle["spark"] == 1 and self.display_level > 0.18:
                painter.setBrush(QBrush(QColor(r, g, b, int(alpha * 0.34))))
                painter.drawRect(QRectF(round(x + math.sin(particle["phase"]) * 4.0), round(y + math.cos(particle["phase"]) * 4.0), 1.0, 1.0))

        painter.end()


class SimpleVoiceMeterOverlay(QWidget):
    tick_ms = 33
    max_particles = 46

    def __init__(self):
        flags = Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool
        super().__init__(None, flags)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

        self.mode = "idle"
        self.frame = 0
        self.level = 0.0
        self.display_level = 0.0
        self.processing_level = 0.28
        self.spawn_level = 0.0
        self.spawn_budget = 0.0
        self.particles = []

        self.timer = QTimer(self)
        self.timer.timeout.connect(self._animate)
        self.timer.start(self.tick_ms)
        self.hide()

    def show_meter(self):
        self._cover_current_screen()
        self.show()
        self._apply_macos_window_level()
        self.raise_()
        self.update()

    def hide_meter(self):
        self.mode = "fade"
        self.level = 0.0
        self.spawn_budget = 0.0

    def set_mode(self, mode):
        self.mode = mode
        if mode == "recording":
            self.show_meter()
        elif mode == "processing":
            self.show_meter()
        else:
            self.hide_meter()

    def set_level(self, level):
        if self.mode != "recording":
            return
        raw_level = max(0.0, min(1.0, float(level)))
        silence_floor = 0.08
        if raw_level < silence_floor:
            self.level = 0.0
        else:
            normalized = (raw_level - silence_floor) / (1.0 - silence_floor)
            self.level = min(1.0, math.pow(normalized, 0.82))
        self.processing_level = max(0.16, min(0.52, self.level * 0.55 + self.processing_level * 0.45))

    def _cover_current_screen(self):
        screen = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
        if screen:
            self.setGeometry(screen.geometry())

    def _animate(self):
        self.frame += 1
        if self.mode in ("recording", "processing"):
            if not self.isVisible():
                self.show_meter()
            elif self.frame % 20 == 0:
                self._cover_current_screen()
                self._apply_macos_window_level()

        if not self.isVisible() and not self.particles:
            return

        if self.mode == "recording":
            target = self.level
            smoothing = 0.42 if target > self.display_level else 0.18
        elif self.mode == "processing":
            target = self.processing_level
            smoothing = 0.12
        else:
            target = 0.0
            smoothing = 0.14

        self.display_level = self.display_level * (1.0 - smoothing) + target * smoothing
        self._update_particles()
        if self.isVisible():
            self.update()

    def _update_particles(self):
        target_spawn_level = 0.0 if self.mode == "fade" else self.display_level
        spawn_smoothing = 0.22 if target_spawn_level > self.spawn_level else 0.11
        self.spawn_level = self.spawn_level * (1.0 - spawn_smoothing) + target_spawn_level * spawn_smoothing
        spawn_level = self.spawn_level

        if self.mode == "processing":
            self.spawn_budget += 0.04 + spawn_level * spawn_level * 2.4
        elif spawn_level > 0.05:
            active_level = (spawn_level - 0.05) / 0.95
            self.spawn_budget += active_level * active_level * 3.1

        spawn_count = min(int(self.spawn_budget), 4, self.max_particles - len(self.particles))
        self.spawn_budget -= spawn_count
        for _ in range(max(0, spawn_count)):
            self._spawn_particle(spawn_level)

        next_particles = []
        for particle in self.particles:
            particle["life"] -= 1
            particle["history"].append((particle["x"], particle["y"]))
            if len(particle["history"]) > particle["history_limit"]:
                particle["history"].pop(0)
            particle["vx"] += particle["drift_x"] + random.uniform(-particle["jitter"], particle["jitter"])
            particle["vy"] += particle["drift_y"] + random.uniform(-particle["jitter"], particle["jitter"])
            particle["x"] += particle["vx"]
            particle["y"] += particle["vy"]
            particle["vx"] *= 0.965
            particle["vy"] *= 0.958
            if particle["life"] > 0 and -80 < particle["x"] < self.width() + 40:
                next_particles.append(particle)

        self.particles = next_particles
        if self.mode == "fade" and not self.particles:
            self.hide()

    def _spawn_particle(self, level):
        w = max(1, self.width())
        h = max(1, self.height())
        emitter_x = w - random.uniform(4.0, 16.0)
        source_y = random.uniform(h * 0.68, h * 0.78)

        speed = (random.uniform(0.55, 1.35) + level * random.uniform(1.1, 3.4)) * 1.5
        angle = math.pi + random.gauss(0.0, 0.72)
        if random.random() < 0.34 + level * 0.20:
            angle += random.choice((-1.0, 1.0)) * random.uniform(0.45, 1.55)
        vx = math.cos(angle) * speed
        vy = math.sin(angle) * speed * 0.55

        if self.mode == "processing":
            color = random.choice(((255, 66, 66), (255, 100, 76), (255, 150, 96)))
        else:
            color = random.choice(((85, 245, 255), (126, 255, 205), (255, 235, 120), (255, 162, 230), (235, 248, 255)))

        life = random.randint(58, 96)
        size = random.choice((2.0, 2.3, 2.6, 3.0, 3.4))
        self.particles.append(
            {
                "x": emitter_x,
                "y": source_y,
                "vx": vx,
                "vy": vy,
                "drift_x": random.uniform(-0.035, 0.035),
                "drift_y": random.uniform(-0.045, 0.045),
                "jitter": random.uniform(0.035, 0.16) + level * 0.18,
                "life": life,
                "max_life": life,
                "size": size,
                "color": color,
                "alpha": random.randint(220, 255),
                "trail": random.uniform(12.0, 26.0) + level * 15.0,
                "history": [],
                "history_limit": random.randint(30, 48),
            }
        )

    def _apply_macos_window_level(self):
        if sys.platform != "darwin":
            return
        try:
            native_view = objc.objc_object(c_void_p=ctypes.c_void_p(int(self.winId())))
            native_window = native_view.window()
            if native_window is None:
                return
            behavior = (
                NSWindowCollectionBehaviorCanJoinAllSpaces
                | NSWindowCollectionBehaviorFullScreenAuxiliary
                | NSWindowCollectionBehaviorStationary
                | NSWindowCollectionBehaviorIgnoresCycle
            )
            native_window.setLevel_(NSScreenSaverWindowLevel)
            native_window.setCollectionBehavior_(behavior)
            native_window.setIgnoresMouseEvents_(True)
            native_window.setCanHide_(False)
            native_window.setHidesOnDeactivate_(False)
            native_window.orderFrontRegardless()
        except Exception as exc:
            logger.warning("Simple overlay native window setup failed: %s", exc)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, False)
        painter.setPen(Qt.PenStyle.NoPen)

        for particle in self.particles:
            life_ratio = max(0.0, min(1.0, particle["life"] / particle["max_life"]))
            r, g, b = particle["color"]
            alpha = int(particle["alpha"] * min(1.0, life_ratio * 1.5))
            if alpha <= 0:
                continue

            x = particle["x"]
            y = particle["y"]
            size = particle["size"]
            history = particle["history"]
            if len(history) >= 2:
                for idx in range(1, len(history)):
                    age = idx / len(history)
                    x1, y1 = history[idx - 1]
                    x2, y2 = history[idx]
                    line_alpha = int(alpha * 0.72 * age)
                    line_width = max(1.2, size * 0.62 * age)
                    painter.setPen(QPen(QColor(r, g, b, line_alpha), line_width, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
                    painter.drawLine(QPointF(x1, y1), QPointF(x2, y2))
                painter.setPen(Qt.PenStyle.NoPen)

            painter.setBrush(QBrush(QColor(r, g, b, alpha)))
            painter.drawEllipse(QRectF(x - size * 0.5, y - size * 0.5, size, size))

        painter.end()


class CompactVoiceIndicator(QWidget):
    tick_ms = 33

    def __init__(self):
        flags = (
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowDoesNotAcceptFocus
        )
        super().__init__(None, flags)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, True)
        self.setFixedSize(272, 96)

        self.controller = None
        self.mode = "idle"
        self.level = 0.0
        self.display_level = 0.0
        self.progress = 0
        self.playback_elapsed = 0.0
        self.playback_duration = 0.0
        self.playback_paused = False
        self.is_scrubbing = False
        self.breath = 0.0
        self.frame = 0

        self.timer = QTimer(self)
        self.timer.timeout.connect(self._animate)
        self.timer.start(self.tick_ms)
        self.hide()

    def bind_controller(self, controller):
        self.controller = controller

    def set_mode(self, mode):
        previous_mode = self.mode
        self.mode = mode
        interactive = mode in ("speaking", "tts_finished")
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents, not interactive)
        if mode != "speaking":
            self.is_scrubbing = False
        if mode in ("recording", "processing", "done") or mode in TTS_WIDGET_STATES:
            self._move_to_bottom_right()
            self.show()
            self._apply_macos_window_level()
            self.update()
        else:
            self.display_level = 0.0
            self.level = 0.0
            self.hide()
        logger.info(
            "Compact indicator mode: %s -> %s visible=%s interactive=%s progress=%s elapsed=%.2fs duration=%.2fs paused=%s",
            previous_mode,
            mode,
            self.isVisible(),
            interactive,
            self.progress,
            self.playback_elapsed,
            self.playback_duration,
            self.playback_paused,
        )

    def set_level(self, level):
        if self.mode != "recording":
            return
        raw_level = max(0.0, min(1.0, float(level)))
        silence_floor = 0.06
        if raw_level <= silence_floor:
            self.level = 0.0
            return
        normalized = (raw_level - silence_floor) / (1.0 - silence_floor)
        self.level = min(1.0, math.pow(normalized, 0.72))

    def set_progress(self, progress):
        self.progress = max(0, min(100, int(progress)))
        if self.mode in TTS_WIDGET_STATES:
            self.update()

    def set_playback_position(self, progress, elapsed, duration, paused=None):
        self.progress = max(0, min(100, int(progress)))
        self.playback_elapsed = max(0.0, float(elapsed or 0.0))
        self.playback_duration = max(0.0, float(duration or 0.0))
        if paused is not None:
            self.playback_paused = bool(paused)
        if self.mode in ("speaking", "tts_finished"):
            self.update()

    def _button_rects(self):
        return {
            "back": QRectF(112, 14, 32, 26),
            "pause": QRectF(150, 14, 32, 26),
            "forward": QRectF(188, 14, 32, 26),
            "close": QRectF(232, 15, 24, 24),
        }

    def _progress_rect(self):
        return QRectF(58, 68, self.width() - 78, 8)

    def _seek_to_x(self, x):
        if self.controller is None:
            return
        rect = self._progress_rect()
        if rect.width() <= 0:
            return
        fraction = max(0.0, min(1.0, (float(x) - rect.x()) / rect.width()))
        logger.info("Compact indicator scrub: x=%.1f fraction=%.3f", x, fraction)
        self.controller.seek_tts_fraction(fraction)

    def _move_to_bottom_right(self):
        screen = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
        if screen is None:
            return
        area = screen.availableGeometry()
        margin = 22
        x = area.x() + area.width() - self.width() - margin
        y = area.y() + area.height() - self.height() - margin
        self.move(x, y)

    def _animate(self):
        self.frame += 1
        if not self.isVisible():
            return

        if self.mode == "recording":
            target = self.level
            smoothing = 0.30 if target > self.display_level else 0.12
        elif self.mode == "processing":
            target = 0.36 + math.sin(self.frame * 0.11) * 0.08
            smoothing = 0.14
        elif self.mode == "generating":
            target = 0.28 + math.sin(self.frame * 0.13) * 0.07
            smoothing = 0.14
        elif self.mode == "speaking":
            target = 0.30 + math.sin(self.frame * 0.18) * 0.16
            smoothing = 0.18
        elif self.mode in ("done", "tts_finished"):
            target = 0.18
            smoothing = 0.16
        else:
            target = 0.0
            smoothing = 0.12

        self.display_level = self.display_level * (1.0 - smoothing) + target * smoothing
        self.breath = 0.5 + 0.5 * math.sin(self.frame * 0.085)
        if self.frame % 45 == 0:
            self._move_to_bottom_right()
        self.update()

    def _apply_macos_window_level(self):
        if sys.platform != "darwin":
            return
        try:
            native_view = objc.objc_object(c_void_p=ctypes.c_void_p(int(self.winId())))
            native_window = native_view.window()
            if native_window is None:
                return
            behavior = (
                NSWindowCollectionBehaviorCanJoinAllSpaces
                | NSWindowCollectionBehaviorFullScreenAuxiliary
                | NSWindowCollectionBehaviorStationary
                | NSWindowCollectionBehaviorIgnoresCycle
            )
            native_window.setLevel_(NSScreenSaverWindowLevel)
            native_window.setCollectionBehavior_(behavior)
            native_window.setIgnoresMouseEvents_(self.mode not in ("speaking", "tts_finished"))
            native_window.setCanHide_(False)
            native_window.setHidesOnDeactivate_(False)
            logger.info(
                "Compact indicator native window: mode=%s ignores_mouse=%s",
                self.mode,
                self.mode not in ("speaking", "tts_finished"),
            )
        except Exception as exc:
            logger.warning("Compact indicator native window setup failed: %s", exc)

    def mousePressEvent(self, event):
        if self.mode not in ("speaking", "tts_finished") or self.controller is None:
            return
        pos = event.position()
        x = pos.x()
        y = pos.y()
        buttons = self._button_rects()
        if buttons["close"].contains(pos):
            logger.info("Compact indicator button: close TTS widget")
            self.controller.close_tts_widget()
        elif self.mode == "tts_finished":
            logger.info("Compact indicator click ignored: finished TTS widget")
        elif buttons["back"].contains(pos):
            logger.info("Compact indicator button: back 5s")
            self.controller.seek_tts(-5.0)
        elif buttons["pause"].contains(pos):
            logger.info("Compact indicator button: toggle pause")
            self.controller.toggle_tts_pause()
        elif buttons["forward"].contains(pos):
            logger.info("Compact indicator button: forward 5s")
            self.controller.seek_tts(5.0)
        elif self._progress_rect().adjusted(-4, -8, 4, 8).contains(pos):
            logger.info("Compact indicator progress press: x=%.1f y=%.1f", x, y)
            self.is_scrubbing = True
            self._seek_to_x(x)
        event.accept()

    def mouseMoveEvent(self, event):
        if self.mode == "speaking" and self.is_scrubbing:
            self._seek_to_x(event.position().x())
            event.accept()

    def mouseReleaseEvent(self, event):
        if self.is_scrubbing:
            logger.info("Compact indicator progress release")
        self.is_scrubbing = False
        event.accept()

    def _format_time(self, seconds):
        seconds = max(0, int(seconds or 0))
        return f"{seconds // 60}:{seconds % 60:02d}"

    def _draw_transport_button(self, painter, name, rect, accent, enabled=True):
        fill_alpha = 44 if enabled else 18
        border_alpha = 132 if enabled else 52
        icon_alpha = 232 if enabled else 96
        if name == "close":
            fill_alpha = 26
            border_alpha = 92 if enabled else 58
            icon_alpha = 220 if enabled else 140

        painter.setBrush(QBrush(QColor(accent.red(), accent.green(), accent.blue(), fill_alpha)))
        painter.setPen(QPen(QColor(accent.red(), accent.green(), accent.blue(), border_alpha), 1.0))
        painter.drawRoundedRect(rect, 7, 7)

        painter.setPen(QPen(QColor(238, 242, 244, icon_alpha), 1.7, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
        painter.setBrush(QBrush(QColor(238, 242, 244, icon_alpha)))
        cx = rect.center().x()
        cy = rect.center().y()

        if name == "pause":
            if self.playback_paused:
                painter.drawPolygon(
                    QPolygonF(
                        [
                            QPointF(cx - 4.0, cy - 6.0),
                            QPointF(cx - 4.0, cy + 6.0),
                            QPointF(cx + 6.0, cy),
                        ]
                    )
                )
            else:
                painter.drawRoundedRect(QRectF(cx - 5.0, cy - 6.0, 3.0, 12.0), 1.0, 1.0)
                painter.drawRoundedRect(QRectF(cx + 2.0, cy - 6.0, 3.0, 12.0), 1.0, 1.0)
        elif name == "back":
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawLine(QPointF(cx - 7.0, cy), QPointF(cx + 5.0, cy))
            painter.drawLine(QPointF(cx - 7.0, cy), QPointF(cx - 2.0, cy - 5.0))
            painter.drawLine(QPointF(cx - 7.0, cy), QPointF(cx - 2.0, cy + 5.0))
            painter.setFont(QFont("Menlo", 6, QFont.Weight.DemiBold))
            painter.drawText(QRectF(cx + 3.0, cy - 7.0, 10.0, 12.0), Qt.AlignmentFlag.AlignCenter, "5")
        elif name == "forward":
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawLine(QPointF(cx - 5.0, cy), QPointF(cx + 7.0, cy))
            painter.drawLine(QPointF(cx + 7.0, cy), QPointF(cx + 2.0, cy - 5.0))
            painter.drawLine(QPointF(cx + 7.0, cy), QPointF(cx + 2.0, cy + 5.0))
            painter.setFont(QFont("Menlo", 6, QFont.Weight.DemiBold))
            painter.drawText(QRectF(cx - 13.0, cy - 7.0, 10.0, 12.0), Qt.AlignmentFlag.AlignCenter, "5")
        elif name == "close":
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawLine(QPointF(cx - 4.5, cy - 4.5), QPointF(cx + 4.5, cy + 4.5))
            painter.drawLine(QPointF(cx + 4.5, cy - 4.5), QPointF(cx - 4.5, cy + 4.5))

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        painter.setPen(Qt.PenStyle.NoPen)

        if self.mode == "processing":
            accent = QColor(245, 181, 97)
            status = "TXT"
        elif self.mode == "generating":
            accent = QColor(255, 196, 87)
            status = "GEN"
        elif self.mode == "speaking":
            accent = QColor(104, 218, 173)
            status = "PLAY"
        elif self.mode == "tts_finished":
            accent = QColor(117, 224, 167)
            status = "DONE"
        elif self.mode == "done":
            accent = QColor(117, 224, 167)
            status = "OK"
        else:
            accent = QColor(116, 218, 232)
            status = "REC"

        level = max(0.02, min(1.0, self.display_level))

        painter.setBrush(QBrush(QColor(0, 0, 0, 52)))
        painter.drawRoundedRect(QRectF(4, 6, self.width() - 8, self.height() - 8), 14, 14)
        painter.setBrush(QBrush(QColor(18, 21, 25, 238)))
        painter.drawRoundedRect(QRectF(1, 1, self.width() - 2, self.height() - 4), 13, 13)
        painter.setBrush(QBrush(QColor(255, 255, 255, 10)))
        painter.drawRoundedRect(QRectF(3, 3, self.width() - 6, 22), 11, 11)
        painter.setPen(QPen(QColor(accent.red(), accent.green(), accent.blue(), 46 + int(level * 38)), 1.0))
        painter.drawRoundedRect(QRectF(1.5, 1.5, self.width() - 3, self.height() - 5), 13, 13)
        painter.setPen(Qt.PenStyle.NoPen)

        cx = 28
        cy = 36
        glow = 13 + level * 5 + self.breath * 1.5
        painter.setBrush(QBrush(QColor(accent.red(), accent.green(), accent.blue(), int(20 + level * 34))))
        painter.drawEllipse(QRectF(cx - glow, cy - glow, glow * 2, glow * 2))

        wave_alpha = int(28 + level * 76)
        painter.setPen(QPen(QColor(accent.red(), accent.green(), accent.blue(), wave_alpha), 1.2, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
        wave_height = 13 + level * 8
        wave_offset = level * 2.6 + self.breath * 1.2
        painter.drawArc(QRectF(cx - 22 - wave_offset, cy - wave_height / 2, 10, wave_height), -58 * 16, 116 * 16)
        painter.drawArc(QRectF(cx + 12 + wave_offset, cy - wave_height / 2, 10, wave_height), 122 * 16, 116 * 16)

        painter.setPen(QPen(QColor(235, 241, 244, 225), 1.45, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
        painter.setBrush(QBrush(QColor(accent.red(), accent.green(), accent.blue(), 154 + int(level * 44))))
        painter.drawRoundedRect(QRectF(cx - 6, cy - 15, 12, 20), 6, 6)
        painter.setPen(QPen(QColor(13, 15, 18, 108), 1.0, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
        painter.drawLine(QPointF(cx - 3.2, cy - 8), QPointF(cx + 3.2, cy - 8))
        painter.drawLine(QPointF(cx - 3.2, cy - 3), QPointF(cx + 3.2, cy - 3))

        painter.setBrush(Qt.BrushStyle.NoBrush)
        painter.setPen(QPen(QColor(235, 241, 244, 220), 1.55, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
        painter.drawArc(QRectF(cx - 11, cy - 6, 22, 20), 205 * 16, 130 * 16)
        painter.drawLine(QPointF(cx, cy + 14), QPointF(cx, cy + 18))
        painter.drawLine(QPointF(cx - 7, cy + 18), QPointF(cx + 7, cy + 18))

        text_x = 58
        painter.setFont(QFont("Menlo", 9, QFont.Weight.DemiBold))
        painter.setPen(QPen(QColor(238, 242, 244, 224)))
        painter.drawText(QRectF(text_x, 15, 46, 14), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, status)

        status_x = self.width() - 30
        status_y = 20
        if self.mode in ("processing", "generating"):
            if self.mode == "generating":
                painter.setFont(QFont("Menlo", 8, QFont.Weight.DemiBold))
                painter.setPen(QPen(QColor(accent.red(), accent.green(), accent.blue(), 230)))
                painter.drawText(
                    QRectF(status_x - 18, status_y - 7, 36, 14),
                    Qt.AlignmentFlag.AlignCenter,
                    f"{self.progress}%",
                )
            else:
                spinner_alpha = 92 + int(self.breath * 42)
                spinner_rect = QRectF(status_x - 5.5, status_y - 5.5, 11, 11)
                spin_start = int((self.frame * 7.5) % 360) * 16
                painter.setBrush(Qt.BrushStyle.NoBrush)
                painter.setPen(QPen(QColor(accent.red(), accent.green(), accent.blue(), 44), 1.5, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
                painter.drawArc(spinner_rect, 0, 360 * 16)
                painter.setPen(QPen(QColor(accent.red(), accent.green(), accent.blue(), spinner_alpha), 1.7, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
                painter.drawArc(spinner_rect, spin_start, 112 * 16)
                painter.setPen(QPen(QColor(255, 245, 225, int(spinner_alpha * 0.58)), 1.3, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
                painter.drawArc(spinner_rect.adjusted(2.2, 2.2, -2.2, -2.2), spin_start - 42 * 16, 48 * 16)
        elif self.mode in ("speaking", "tts_finished"):
            buttons = self._button_rects()
            for name, rect in buttons.items():
                self._draw_transport_button(painter, name, rect, accent, enabled=self.mode == "speaking" or name == "close")
            if self.playback_duration > 0:
                painter.setFont(QFont("Menlo", 7, QFont.Weight.DemiBold))
                painter.setPen(QPen(QColor(238, 242, 244, 170)))
                time_text = f"{self._format_time(self.playback_elapsed)}/{self._format_time(self.playback_duration)}"
                if self.mode == "tts_finished":
                    state_text = f"DONE {self._format_time(self.playback_duration)}"
                else:
                    state_text = "PAUSED" if self.playback_paused else time_text
                painter.drawText(QRectF(text_x, 40, 150, 14), Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter, state_text)
        else:
            dot_alpha = 100 + int(self.breath * 70) + int(level * 70)
            painter.setBrush(QBrush(QColor(accent.red(), accent.green(), accent.blue(), min(230, dot_alpha))))
            painter.setPen(Qt.PenStyle.NoPen)
            painter.drawEllipse(QRectF(status_x - 2.5, status_y - 2.5, 5, 5))

        if self.mode in ("speaking", "tts_finished"):
            progress_rect = self._progress_rect()
            bar_x = progress_rect.x()
            bar_y = progress_rect.y()
            bar_w = progress_rect.width()
            bar_h = progress_rect.height()
        else:
            bar_x = text_x
            bar_y = 58
            bar_w = self.width() - bar_x - 18
            bar_h = 6
        if self.mode in TTS_WIDGET_STATES:
            fill_w = bar_w * (self.progress / 100.0)
        else:
            fill_w = max(5, bar_w * min(1.0, 0.08 + level * 0.92))
        painter.setBrush(QBrush(QColor(255, 255, 255, 24)))
        painter.drawRoundedRect(QRectF(bar_x, bar_y, bar_w, bar_h), 2.5, 2.5)
        painter.setBrush(QBrush(QColor(accent.red(), accent.green(), accent.blue(), 188)))
        if fill_w > 0:
            painter.drawRoundedRect(QRectF(bar_x, bar_y, fill_w, bar_h), 2.5, 2.5)
        if self.mode in ("speaking", "tts_finished"):
            knob_x = bar_x + fill_w
            knob_alpha = 225 if self.mode == "speaking" else 156
            painter.setBrush(QBrush(QColor(238, 242, 244, knob_alpha)))
            painter.setPen(QPen(QColor(accent.red(), accent.green(), accent.blue(), 150), 1.0))
            painter.drawEllipse(QRectF(knob_x - 4, bar_y - 3, 8, 14))
        painter.end()


@dataclass(frozen=True)
class FocusTarget:
    bundle_id: str
    name: str


class FocusController:
    ignored_bundle_ids = {"com.nekoneki.whisper-dictation.app"}

    @classmethod
    def capture(cls):
        if sys.platform != "darwin":
            return None
        script = """
        tell application "System Events"
            set targetProcess to first application process whose frontmost is true
            set targetBundleId to ""
            try
                set targetBundleId to bundle identifier of targetProcess
            end try
            set targetName to name of targetProcess
            return targetBundleId & linefeed & targetName
        end tell
        """
        try:
            result = subprocess.run(["osascript", "-e", script], check=True, text=True, capture_output=True)
            parts = result.stdout.rstrip("\n").split("\n", 1)
            bundle_id = parts[0].strip() if parts else ""
            name = parts[1].strip() if len(parts) > 1 else ""
            if not bundle_id and not name:
                return None
            if bundle_id in cls.ignored_bundle_ids:
                return None
            return FocusTarget(bundle_id=bundle_id, name=name)
        except Exception as exc:
            logger.warning("Could not capture frontmost app: %s", exc)
            return None

    @classmethod
    def restore(cls, target):
        if sys.platform != "darwin" or target is None:
            return
        if target.bundle_id:
            script = f'tell application id {json.dumps(target.bundle_id)} to activate'
        elif target.name:
            script = f'tell application {json.dumps(target.name)} to activate'
        else:
            return
        try:
            subprocess.run(["osascript", "-e", script], check=False, text=True, capture_output=True)
        except Exception as exc:
            logger.warning("Could not restore frontmost app: %s", exc)


def send_cmd_key(key_code):
    app_services = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
    core_foundation = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

    app_services.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
    app_services.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
    app_services.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
    app_services.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
    core_foundation.CFRelease.argtypes = [ctypes.c_void_p]

    key_down = app_services.CGEventCreateKeyboardEvent(None, key_code, True)
    key_up = app_services.CGEventCreateKeyboardEvent(None, key_code, False)
    if not key_down or not key_up:
        raise RuntimeError("Could not create keyboard event")
    try:
        app_services.CGEventSetFlags(key_down, CG_EVENT_FLAG_MASK_COMMAND)
        app_services.CGEventSetFlags(key_up, CG_EVENT_FLAG_MASK_COMMAND)
        app_services.CGEventPost(0, key_down)
        time.sleep(0.03)
        app_services.CGEventPost(0, key_up)
    finally:
        core_foundation.CFRelease(key_down)
        core_foundation.CFRelease(key_up)


class SelectionReader:
    def read_selected_text(self, focus_target=None):
        original_clipboard = self._read_clipboard()
        sentinel = f"__WHISPER_DICTATION_NO_SELECTION_{os.getpid()}_{time.time_ns()}__"
        self._write_clipboard(sentinel)
        FocusController.restore(focus_target)
        time.sleep(0.12)
        send_cmd_key(KEY_CODE_C)
        time.sleep(0.16)
        selected_text = self._read_clipboard()
        self._restore_clipboard(original_clipboard)
        if selected_text == sentinel:
            return ""
        return selected_text.strip()

    def _read_clipboard(self):
        try:
            result = subprocess.run(
                ["/usr/bin/pbpaste"],
                text=True,
                check=True,
                capture_output=True,
            )
            return result.stdout
        except Exception as exc:
            logger.warning("Could not read clipboard: %s", exc)
            return ""

    def _restore_clipboard(self, text):
        self._write_clipboard(text)

    def _write_clipboard(self, text):
        try:
            subprocess.run(
                ["/usr/bin/pbcopy"],
                input=text,
                text=True,
                check=True,
                capture_output=True,
            )
        except Exception as exc:
            logger.warning("Could not write clipboard text: %s", exc)


class AudioWorker(QThread):
    finished_signal = pyqtSignal(object)
    cost_update_signal = pyqtSignal()
    limit_reached_signal = pyqtSignal()
    level_signal = pyqtSignal(float)

    def __init__(self):
        super().__init__()
        self.is_recording = False
        self.is_cancelled = False

    def start_recording(self):
        if self.isRunning():
            return
        self.is_recording = True
        self.is_cancelled = False
        self.start()

    def stop_recording(self):
        self.is_recording = False

    def cancel(self):
        self.is_cancelled = True
        self.is_recording = False

    def run(self):
        frames = []
        start_time = time.time()
        audio = pyaudio.PyAudio()
        stream = None
        recording_rate = AUDIO.rate
        try:
            selection = input_device_selector.resolve(audio)
            stream, recording_rate = self._open_recording_stream(audio, selection)
            logger.info(
                "Start recording: device=%r index=%s rate=%s reason=%s",
                selection["name"],
                selection["index"],
                recording_rate,
                selection["reason"],
            )

            while self.is_recording and not self.is_cancelled:
                data = stream.read(AUDIO.chunk, exception_on_overflow=False)
                frames.append(data)
                self.level_signal.emit(self._audio_level(data))
                if time.time() - start_time >= AUDIO.max_record_seconds:
                    logger.info("Recording limit reached; auto-stopping")
                    self.is_recording = False
                    self.limit_reached_signal.emit()
                    break

            duration_sec = time.time() - start_time
            if self.is_cancelled:
                self.finished_signal.emit(None)
                return
            if len(frames) < AUDIO.min_chunks:
                logger.warning("Recording too short; cancelled")
                self.finished_signal.emit(None)
                return

            logger.info("Recording finished %.2fs; transcribing", duration_sec)
            sample_width = audio.get_sample_size(AUDIO.format)
            self._transcribe(frames, duration_sec, sample_width, recording_rate)
        except Exception as exc:
            if not self.is_cancelled:
                logger.exception("Audio error: %s", exc)
                self.finished_signal.emit(None)
        finally:
            if stream is not None:
                try:
                    stream.stop_stream()
                    stream.close()
                except Exception:
                    pass
            audio.terminate()
            self.level_signal.emit(0.0)

    def _open_recording_stream(self, audio, selection):
        attempts = []
        if selection and selection.get("index") is not None:
            for rate in self._candidate_rates(selection.get("rate")):
                attempts.append((selection["index"], selection["name"], rate, selection["reason"]))

        default_rate = self._default_input_rate(audio)
        for rate in self._candidate_rates(default_rate):
            attempts.append((None, "system default input", rate, "default input fallback"))

        last_error = None
        seen = set()
        for index, name, rate, reason in attempts:
            attempt_key = (index, rate)
            if attempt_key in seen:
                continue
            seen.add(attempt_key)

            kwargs = {
                "format": AUDIO.format,
                "channels": AUDIO.channels,
                "rate": rate,
                "input": True,
                "frames_per_buffer": AUDIO.chunk,
            }
            if index is not None:
                kwargs["input_device_index"] = index

            try:
                logger.info("Opening input stream: device=%r index=%s rate=%s reason=%s", name, index, rate, reason)
                return audio.open(**kwargs), rate
            except Exception as exc:
                last_error = exc
                logger.warning("Could not open input stream: device=%r index=%s rate=%s error=%s", name, index, rate, exc)

        if last_error is not None:
            raise last_error
        raise RuntimeError("No audio input stream attempts were available")

    def _candidate_rates(self, preferred_rate):
        rates = []
        for value in (preferred_rate, AUDIO.rate, 48_000, 44_100):
            try:
                rate = int(round(float(value)))
            except (TypeError, ValueError):
                continue
            if 8_000 <= rate <= 192_000 and rate not in rates:
                rates.append(rate)
        return rates

    def _default_input_rate(self, audio):
        try:
            info = audio.get_default_input_device_info()
        except Exception:
            return AUDIO.rate
        return info.get("defaultSampleRate", AUDIO.rate)

    def _audio_level(self, data):
        samples = array.array("h")
        samples.frombytes(data)
        if sys.byteorder == "big":
            samples.byteswap()
        if not samples:
            return 0.0
        rms = math.sqrt(sum(sample * sample for sample in samples) / len(samples))
        peak = max(abs(sample) for sample in samples)
        raw_level = (rms / 32768.0) * 34.0 + (peak / 32768.0) * 1.4
        if raw_level < 0.0012:
            return 0.0
        return min(1.0, math.pow(raw_level, 0.55) * 1.25)

    def _transcribe(self, frames, duration_sec, sample_width, sample_rate):
        temp_path = ""
        try:
            cost, _total = cost_manager.add_recording(duration_sec)
            self.cost_update_signal.emit()
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temp_file:
                temp_path = temp_file.name
            with wave.open(temp_path, "wb") as wav_file:
                wav_file.setnchannels(AUDIO.channels)
                wav_file.setsampwidth(sample_width)
                wav_file.setframerate(sample_rate)
                wav_file.writeframes(b"".join(frames))

            logger.info("Sending audio to Whisper; estimated cost $%.5f", cost)
            with open(temp_path, "rb") as audio_file:
                transcript = client.audio.transcriptions.create(model="whisper-1", file=audio_file, timeout=30.0)

            if self.is_cancelled:
                logger.info("Transcription result discarded after cancellation")
                self.finished_signal.emit(None)
                return

            text = (transcript.text or "").strip()
            if not text:
                logger.info("Whisper returned empty text")
                self.finished_signal.emit(None)
                return

            text = text[0].lower() + text[1:]
            logger.info("Transcribed: %r", text)
            self.finished_signal.emit(text)
        except Exception as exc:
            if not self.is_cancelled:
                logger.exception("Whisper API error: %s", exc)
                self.finished_signal.emit(None)
        finally:
            if temp_path and os.path.exists(temp_path):
                logger.info("Removing temporary Whisper audio file: %s", temp_path)
                os.remove(temp_path)


class LocalAudioOutput:
    def __init__(self):
        self.process = None
        self.lock = threading.Lock()
        self.stop_requested = False
        self.position_frame = 0
        self.total_frames = 0
        self.sample_rate = 0
        self.channels = 1
        self.is_playing = False
        self.is_paused = False

    def play(self, samples, sample_rate, stop_checker, progress_callback=None):
        logger.info("TTS playback requested: backend=pyaudio sample_rate=%s", sample_rate)
        audio, channels = self._to_int16_audio(samples)
        frame_count = len(audio) if channels == 1 else audio.shape[0]
        if frame_count <= 0:
            logger.info("TTS playback skipped: empty audio")
            return

        with self.lock:
            self.stop_requested = False
            self.position_frame = 0
            self.total_frames = frame_count
            self.sample_rate = int(sample_rate)
            self.channels = channels
            self.is_playing = True
            self.is_paused = False
            logger.info("TTS playback state armed: %s", self._playback_snapshot_locked())

        audio_bytes = audio.tobytes()
        bytes_per_frame = channels * 2
        chunk_frames = 2048
        last_progress_at = 0.0
        player = pyaudio.PyAudio()
        stream = None
        try:
            logger.info(
                "TTS playback opening PyAudio stream: rate=%s channels=%s chunk_frames=%s bytes=%s",
                int(sample_rate),
                channels,
                chunk_frames,
                len(audio_bytes),
            )
            stream = player.open(
                format=pyaudio.paInt16,
                channels=channels,
                rate=int(sample_rate),
                output=True,
                frames_per_buffer=chunk_frames,
            )
            duration = frame_count / float(sample_rate)
            logger.info("TTS playback starting: frames=%d channels=%d duration=%.2fs", frame_count, channels, duration)
            while not stop_checker():
                with self.lock:
                    if self.stop_requested or self.position_frame >= self.total_frames:
                        break
                    paused = self.is_paused
                    start_frame = self.position_frame
                    if paused:
                        end_frame = start_frame
                    else:
                        end_frame = min(self.total_frames, start_frame + chunk_frames)
                        self.position_frame = end_frame

                if paused:
                    now = time.time()
                    if progress_callback and now - last_progress_at >= 0.50:
                        last_progress_at = now
                        progress_callback(self._playback_snapshot())
                    time.sleep(0.05)
                    continue

                start_byte = start_frame * bytes_per_frame
                end_byte = end_frame * bytes_per_frame
                stream.write(audio_bytes[start_byte:end_byte])

                now = time.time()
                if progress_callback and now - last_progress_at >= 0.10:
                    last_progress_at = now
                    progress_callback(self._playback_snapshot())

            stopped = bool(stop_checker() or self.stop_requested)
            if stop_checker():
                self.stop()
            elif progress_callback:
                progress_callback(self._playback_snapshot(force_complete=True))
            logger.info("TTS playback finished: stopped=%s snapshot=%s", stopped, self.snapshot())
        finally:
            if stream is not None:
                try:
                    stream.stop_stream()
                    stream.close()
                    logger.info("TTS playback stream closed")
                except Exception:
                    pass
            player.terminate()
            with self.lock:
                self.is_playing = False
                self.stop_requested = False
                self.is_paused = False
                logger.info("TTS playback state cleared: %s", self._playback_snapshot_locked())

    def stop(self):
        logger.info("TTS playback stop requested: snapshot=%s", self.snapshot())
        try:
            import sounddevice as sd

            sd.stop()
        except Exception:
            pass
        with self.lock:
            self.stop_requested = True
            self.is_paused = False
        process = self.process
        if process and process.poll() is None:
            process.terminate()
        self.process = None

    def snapshot(self):
        with self.lock:
            data = self._playback_snapshot_locked()
            data.update(
                {
                    "is_playing": self.is_playing,
                    "is_paused": self.is_paused,
                    "stop_requested": self.stop_requested,
                    "sample_rate": self.sample_rate,
                    "channels": self.channels,
                    "position_frame": self.position_frame,
                    "total_frames": self.total_frames,
                }
            )
            return data

    def set_paused(self, paused):
        with self.lock:
            if not self.is_playing:
                logger.info("TTS pause ignored: no active playback snapshot=%s", self._playback_snapshot_locked())
                return None
            self.is_paused = bool(paused)
            snapshot = self._playback_snapshot_locked()
        logger.info("TTS playback paused=%s snapshot=%s", bool(paused), snapshot)
        return snapshot

    def toggle_paused(self):
        with self.lock:
            if not self.is_playing:
                logger.info("TTS pause toggle ignored: no active playback snapshot=%s", self._playback_snapshot_locked())
                return None
            self.is_paused = not self.is_paused
            snapshot = self._playback_snapshot_locked()
            paused = self.is_paused
        logger.info("TTS playback pause toggled: paused=%s snapshot=%s", paused, snapshot)
        return snapshot

    def seek_fraction(self, fraction):
        with self.lock:
            if not self.is_playing or self.total_frames <= 0:
                logger.info("TTS scrub ignored: no active seekable playback snapshot=%s", self._playback_snapshot_locked())
                return None
            old_position = self.position_frame
            fraction = max(0.0, min(1.0, float(fraction)))
            self.position_frame = int(round(self.total_frames * fraction))
            snapshot = self._playback_snapshot_locked()
        logger.info(
            "TTS scrub: fraction=%.3f old_progress=%s new_progress=%s elapsed=%.2fs duration=%.2fs",
            fraction,
            int(round((old_position / self.total_frames) * 100)) if self.total_frames else 0,
            snapshot["progress"],
            snapshot["elapsed"],
            snapshot["duration"],
        )
        return snapshot

    def seek_relative(self, seconds):
        with self.lock:
            if not self.is_playing or self.sample_rate <= 0 or self.total_frames <= 0:
                logger.info("TTS seek ignored: no active seekable playback snapshot=%s", self._playback_snapshot_locked())
                return None
            old_position = self.position_frame
            sample_rate = self.sample_rate
            delta_frames = int(seconds * self.sample_rate)
            self.position_frame = max(0, min(self.total_frames, self.position_frame + delta_frames))
            snapshot = self._playback_snapshot_locked()
        logger.info(
            "TTS seek: delta=%.1fs old=%.2fs new=%.2fs duration=%.2fs",
            seconds,
            old_position / float(sample_rate),
            snapshot["elapsed"],
            snapshot["duration"],
        )
        return snapshot

    def _playback_snapshot(self, force_complete=False):
        with self.lock:
            if force_complete:
                self.position_frame = self.total_frames
            return self._playback_snapshot_locked()

    def _playback_snapshot_locked(self):
        duration = self.total_frames / float(self.sample_rate) if self.sample_rate > 0 else 0.0
        elapsed = self.position_frame / float(self.sample_rate) if self.sample_rate > 0 else 0.0
        progress = int(round((elapsed / duration) * 100)) if duration > 0 else 0
        return {
            "progress": max(0, min(100, progress)),
            "elapsed": max(0.0, min(duration, elapsed)),
            "duration": duration,
            "paused": self.is_paused,
        }

    def _to_int16_audio(self, samples):
        import numpy as np

        audio = np.asarray(samples)
        if audio.ndim == 1:
            channels = 1
        elif audio.ndim == 2:
            channels = audio.shape[1]
        else:
            audio = audio.reshape(-1)
            channels = 1

        if audio.dtype.kind == "f":
            audio = np.clip(audio, -1.0, 1.0)
            audio = (audio * 32767.0).astype(np.int16)
        elif audio.dtype != np.int16:
            audio = np.clip(audio, -32768, 32767).astype(np.int16)
        return audio, channels

    def _play_with_afplay(self, samples, sample_rate, stop_checker):
        temp_path = ""
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temp_file:
                temp_path = temp_file.name
            self._write_wav(temp_path, samples, sample_rate)
            logger.info("TTS playback starting with afplay: wav=%s", temp_path)
            process = subprocess.Popen(["/usr/bin/afplay", temp_path])
            self.process = process
            while process.poll() is None:
                if stop_checker():
                    self.stop()
                    return
                time.sleep(0.05)
            if process.returncode not in (0, None) and not stop_checker():
                raise RuntimeError(f"afplay failed with exit code {process.returncode}")
            logger.info("TTS playback finished with afplay: returncode=%s", process.returncode)
        finally:
            if self.process is locals().get("process"):
                self.process = None
            if temp_path and os.path.exists(temp_path):
                try:
                    logger.info("Removing temporary afplay wav file: %s", temp_path)
                    os.remove(temp_path)
                except OSError:
                    pass

    def _write_wav(self, path, samples, sample_rate):
        audio, channels = self._to_int16_audio(samples)

        with wave.open(path, "wb") as wav_file:
            wav_file.setnchannels(channels)
            wav_file.setsampwidth(2)
            wav_file.setframerate(int(sample_rate))
            wav_file.writeframes(audio.tobytes())


audio_output = LocalAudioOutput()


class AudioTimeStretcher:
    def __init__(self):
        self.rubberband_path = shutil.which("rubberband") or "/opt/homebrew/bin/rubberband"

    def apply(self, samples, sample_rate, tempo):
        if abs(tempo - 1.0) < 0.02:
            return samples, sample_rate
        if not self.rubberband_path or not os.path.exists(self.rubberband_path):
            logger.warning("Rubber Band is unavailable; TTS speed %.2fx will not be applied", tempo)
            return samples, sample_rate

        input_path = ""
        output_path = ""
        started_at = time.time()
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as input_file:
                input_path = input_file.name
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as output_file:
                output_path = output_file.name

            audio_output._write_wav(input_path, samples, sample_rate)
            cmd = [self.rubberband_path, "-3", "-q", f"-T{tempo:.4f}", input_path, output_path]
            logger.info("Rubber Band tempo processing start: tempo=%.2f input=%s output=%s", tempo, input_path, output_path)
            completed = subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=180)
            if completed.returncode != 0:
                logger.warning(
                    "Rubber Band tempo processing failed: returncode=%s stderr=%s",
                    completed.returncode,
                    (completed.stderr or "").strip(),
                )
                return samples, sample_rate

            processed, processed_rate = self._read_wav(output_path)
            logger.info(
                "Rubber Band tempo processing complete: tempo=%.2f sample_rate=%s samples=%d duration=%.2fs",
                tempo,
                processed_rate,
                len(processed),
                time.time() - started_at,
            )
            return processed, processed_rate
        except Exception as exc:
            logger.exception("Rubber Band tempo processing error: %s", exc)
            return samples, sample_rate
        finally:
            for path in (input_path, output_path):
                if path and os.path.exists(path):
                    try:
                        logger.info("Removing temporary Rubber Band file: %s", path)
                        os.remove(path)
                    except OSError:
                        pass

    def _read_wav(self, path):
        import numpy as np

        with wave.open(path, "rb") as wav_file:
            channels = wav_file.getnchannels()
            sample_width = wav_file.getsampwidth()
            sample_rate = wav_file.getframerate()
            frames = wav_file.readframes(wav_file.getnframes())

        if sample_width == 2:
            audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
        elif sample_width == 4:
            audio = np.frombuffer(frames, dtype=np.int32).astype(np.float32) / 2147483648.0
        else:
            raise RuntimeError(f"Unsupported WAV sample width from Rubber Band: {sample_width}")

        if channels > 1:
            audio = audio.reshape(-1, channels).mean(axis=1)
        return audio, sample_rate


time_stretcher = AudioTimeStretcher()


class MlxChatterboxSpeechEngine:
    def __init__(self):
        self.model = None
        self.loaded_model_id = None

    def speak(self, text, speed, stop_checker, stage_callback=None, progress_callback=None):
        started_at = time.time()
        if stage_callback:
            stage_callback("generating")
        if progress_callback:
            progress_callback(8)

        chunks = split_text_chunks(text, TTS.chunk_chars)
        if not chunks:
            logger.info("MLX Chatterbox TTS skipped: no chunks")
            return

        logger.info(
            "MLX Chatterbox TTS prepare: chars=%d chunks=%d model=%s speed=%.2f exaggeration=%.2f cfg_weight=%.2f temperature=%.2f max_tokens=%d",
            len(text),
            len(chunks),
            TTS.mlx_model,
            speed,
            TTS.mlx_exaggeration,
            TTS.mlx_cfg_weight,
            TTS.mlx_temperature,
            TTS.mlx_max_tokens,
        )
        if progress_callback:
            progress_callback(12)
        model = self._load_model()
        if progress_callback:
            progress_callback(20)

        import numpy as np

        audios = []
        sample_rate = getattr(model, "sample_rate", None) or getattr(model, "sr", 24000)
        for index, chunk in enumerate(chunks, start=1):
            if stop_checker():
                logger.info("MLX Chatterbox TTS cancelled before chunk %d/%d", index, len(chunks))
                return

            chunk_started_at = time.time()
            language = detect_tts_language(chunk)
            chunk_audios = []
            for result in model.generate(
                text=chunk,
                lang_code=language,
                max_tokens=TTS.mlx_max_tokens,
                exaggeration=TTS.mlx_exaggeration,
                cfg_weight=TTS.mlx_cfg_weight,
                temperature=TTS.mlx_temperature,
                verbose=False,
            ):
                chunk_audios.append(np.asarray(result.audio, dtype=np.float32))
                sample_rate = result.sample_rate
                logger.info(
                    "MLX Chatterbox TTS result chunk %d/%d: lang=%s token_count=%s audio_duration=%s rtf=%s memory=%.2fGB",
                    index,
                    len(chunks),
                    language,
                    getattr(result, "token_count", None),
                    getattr(result, "audio_duration", None),
                    getattr(result, "real_time_factor", None),
                    getattr(result, "peak_memory_usage", 0.0),
                )

            if not chunk_audios:
                logger.warning("MLX Chatterbox TTS returned no audio for chunk %d/%d", index, len(chunks))
                continue
            chunk_audio = np.concatenate(chunk_audios)
            audios.append(chunk_audio)
            logger.info(
                "MLX Chatterbox TTS generated chunk %d/%d: chars=%d lang=%s samples=%d sample_rate=%s duration=%.2fs",
                index,
                len(chunks),
                len(chunk),
                language,
                len(chunk_audio),
                sample_rate,
                time.time() - chunk_started_at,
            )
            if progress_callback:
                progress_callback(20 + round(index * 70 / len(chunks)))

        if stop_checker():
            return
        if not audios or sample_rate is None:
            raise RuntimeError("MLX Chatterbox TTS produced no audio")

        audio = np.concatenate(audios)
        if progress_callback:
            progress_callback(94)
        audio, sample_rate = time_stretcher.apply(audio, sample_rate, speed)
        if progress_callback:
            progress_callback(100)

        logger.info(
            "MLX Chatterbox TTS generation complete: chunks=%d samples=%d sample_rate=%s total_duration=%.2fs",
            len(chunks),
            len(audio),
            sample_rate,
            time.time() - started_at,
        )
        if stage_callback:
            stage_callback("speaking")
        audio_output.play(audio, sample_rate, stop_checker, progress_callback)

    def stop(self):
        audio_output.stop()

    def _load_model(self):
        if self.model is not None and self.loaded_model_id == TTS.mlx_model:
            logger.info("MLX Chatterbox model reused: model=%s", TTS.mlx_model)
            return self.model

        from mlx_audio.tts.utils import load_model

        started_at = time.time()
        logger.info("MLX Chatterbox model loading: model=%s", TTS.mlx_model)
        self.model = load_model(TTS.mlx_model)
        self.loaded_model_id = TTS.mlx_model
        logger.info(
            "MLX Chatterbox model loaded: model=%s sample_rate=%s duration=%.2fs",
            TTS.mlx_model,
            getattr(self.model, "sample_rate", None) or getattr(self.model, "sr", None),
            time.time() - started_at,
        )
        return self.model


class KokoroSpeechEngine:
    def __init__(self):
        self.kokoro = None
        self.loaded_quality = None

    def speak(self, text, speed, stop_checker, stage_callback=None, progress_callback=None):
        started_at = time.time()
        if stage_callback:
            stage_callback("generating")
        if progress_callback:
            progress_callback(8)

        chunks = split_text_chunks(text, TTS.chunk_chars)
        if not chunks:
            logger.info("Kokoro TTS skipped: no chunks")
            return
        logger.info(
            "Kokoro TTS prepare: chars=%d chunks=%d voice=%s lang=%s quality=%s speed=%.2f model_dir=%s",
            len(text),
            len(chunks),
            TTS.voice,
            TTS.lang,
            TTS.quality,
            speed,
            TTS_MODEL_DIR,
        )
        if progress_callback:
            progress_callback(12)
        kokoro = self._load_model()
        if progress_callback:
            progress_callback(20)

        audios = []
        sample_rate = None
        for index, chunk in enumerate(chunks, start=1):
            if stop_checker():
                logger.info("Kokoro TTS cancelled before chunk %d/%d", index, len(chunks))
                return
            chunk_started_at = time.time()
            samples, chunk_sample_rate = kokoro.create(chunk, voice=TTS.voice, speed=speed, lang=TTS.lang)
            logger.info(
                "Kokoro TTS generated chunk %d/%d: chars=%d sample_rate=%s duration=%.2fs",
                index,
                len(chunks),
                len(chunk),
                chunk_sample_rate,
                time.time() - chunk_started_at,
            )
            sample_rate = chunk_sample_rate
            audios.append(samples)
            if progress_callback:
                progress_callback(20 + round(index * 80 / len(chunks)))

        if stop_checker():
            return
        import numpy as np

        audio = np.concatenate(audios)
        logger.info(
            "Kokoro TTS generation complete: chunks=%d samples=%d sample_rate=%s total_duration=%.2fs",
            len(chunks),
            len(audio),
            sample_rate,
            time.time() - started_at,
        )
        if stage_callback:
            stage_callback("speaking")
        audio_output.play(audio, sample_rate, stop_checker, progress_callback)

    def stop(self):
        audio_output.stop()

    def _load_model(self):
        quality = TTS.quality if TTS.quality in KOKORO_MODEL_URLS else "int8"
        if self.kokoro is not None and self.loaded_quality == quality:
            logger.info("Kokoro model reused: quality=%s", quality)
            return self.kokoro

        from kokoro_onnx import Kokoro

        TTS_MODEL_DIR.mkdir(parents=True, exist_ok=True)
        model_url = KOKORO_MODEL_URLS[quality]
        model_path = TTS_MODEL_DIR / Path(model_url).name
        voices_path = TTS_MODEL_DIR / "voices-v1.0.bin"
        logger.info("Kokoro model loading: quality=%s model=%s voices=%s", quality, model_path, voices_path)
        self._download_if_missing(model_path, model_url)
        self._download_if_missing(voices_path, KOKORO_VOICES_URL)
        self.kokoro = Kokoro(str(model_path), str(voices_path))
        self.loaded_quality = quality
        logger.info("Kokoro model loaded: quality=%s", quality)
        return self.kokoro

    def _download_if_missing(self, path, url):
        if path.exists():
            logger.info("TTS model file exists: %s size=%d", path, path.stat().st_size)
            return
        tmp_path = path.with_suffix(path.suffix + ".tmp")
        logger.info("Downloading local TTS model file: path=%s url=%s", path, url)
        with urllib.request.urlopen(url, timeout=25) as response, tmp_path.open("wb") as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
        tmp_path.replace(path)
        logger.info("Downloaded local TTS model file: %s size=%d", path, path.stat().st_size)


class PiperRussianSpeechEngine:
    def __init__(self):
        self.voice = None

    def speak(self, chunks, speed, stop_checker, stage_callback=None, progress_callback=None):
        started_at = time.time()
        if stage_callback:
            stage_callback("generating")
        if progress_callback:
            progress_callback(18)
        if not chunks:
            logger.info("Piper Russian TTS skipped: no chunks")
            return

        voice = self._load_voice()
        if progress_callback:
            progress_callback(22)

        from piper import SynthesisConfig
        import numpy as np

        length_scale = max(0.60, min(1.45, 1.0 / max(0.70, min(1.70, speed))))
        syn_config = SynthesisConfig(length_scale=length_scale, normalize_audio=True, volume=1.0)
        audios = []
        sample_rate = None
        logger.info(
            "Piper Russian TTS prepare: voice=%s-%s chunks=%d speed=%.2f length_scale=%.3f model=%s",
            PIPER_RU_VOICE,
            PIPER_RU_QUALITY,
            len(chunks),
            speed,
            length_scale,
            PIPER_RU_MODEL_FILE,
        )

        for index, chunk in enumerate(chunks, start=1):
            if stop_checker():
                logger.info("Piper Russian TTS cancelled before chunk %d/%d", index, len(chunks))
                return
            chunk_started_at = time.time()
            chunk_samples = []
            for audio_chunk in voice.synthesize(chunk, syn_config=syn_config):
                chunk_samples.append(audio_chunk.audio_float_array)
                sample_rate = audio_chunk.sample_rate
            if not chunk_samples:
                logger.warning("Piper Russian TTS returned no audio for chunk %d/%d", index, len(chunks))
                continue
            samples = np.concatenate(chunk_samples)
            audios.append(samples)
            logger.info(
                "Piper Russian TTS generated chunk %d/%d: chars=%d samples=%d sample_rate=%s duration=%.2fs",
                index,
                len(chunks),
                len(chunk),
                len(samples),
                sample_rate,
                time.time() - chunk_started_at,
            )
            if progress_callback:
                progress_callback(22 + round(index * 78 / len(chunks)))

        if stop_checker():
            return
        if not audios or sample_rate is None:
            raise RuntimeError("Piper Russian TTS produced no audio")

        audio = np.concatenate(audios)
        logger.info(
            "Piper Russian TTS generation complete: chunks=%d samples=%d sample_rate=%s total_duration=%.2fs",
            len(chunks),
            len(audio),
            sample_rate,
            time.time() - started_at,
        )
        if stage_callback:
            stage_callback("speaking")
        audio_output.play(audio, sample_rate, stop_checker, progress_callback)

    def _load_voice(self):
        if self.voice is not None:
            logger.info("Piper Russian voice reused: model=%s", PIPER_RU_MODEL_FILE)
            return self.voice

        from piper import PiperVoice

        PIPER_MODEL_DIR.mkdir(parents=True, exist_ok=True)
        self._download_if_missing(PIPER_RU_CONFIG_FILE, PIPER_RU_CONFIG_URL)
        self._download_if_missing(PIPER_RU_MODEL_FILE, PIPER_RU_MODEL_URL)
        logger.info("Piper Russian voice loading: model=%s config=%s", PIPER_RU_MODEL_FILE, PIPER_RU_CONFIG_FILE)
        self.voice = PiperVoice.load(PIPER_RU_MODEL_FILE, PIPER_RU_CONFIG_FILE)
        logger.info(
            "Piper Russian voice loaded: voice=%s-%s sample_rate=%s",
            PIPER_RU_VOICE,
            PIPER_RU_QUALITY,
            self.voice.config.sample_rate,
        )
        return self.voice

    def _download_if_missing(self, path, url):
        if path.exists():
            logger.info("Piper Russian model file exists: %s size=%d", path, path.stat().st_size)
            return
        tmp_path = path.with_suffix(path.suffix + ".tmp")
        logger.info("Downloading Piper Russian model file: path=%s url=%s", path, url)
        with urllib.request.urlopen(url, timeout=30) as response, tmp_path.open("wb") as output:
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
        tmp_path.replace(path)
        logger.info("Downloaded Piper Russian model file: %s size=%d", path, path.stat().st_size)


class SileroRussianSpeechEngine:
    def __init__(self):
        self.model = None
        self.device = None
        self.say_process = None
        self.piper = PiperRussianSpeechEngine()

    def speak(self, text, speed, stop_checker, stage_callback=None, progress_callback=None):
        started_at = time.time()
        if stage_callback:
            stage_callback("generating")
        if progress_callback:
            progress_callback(8)
        chunks = split_text_chunks(text, TTS.chunk_chars)
        if not chunks:
            logger.info("Silero TTS skipped: no chunks")
            return
        logger.info(
            "Silero TTS prepare: chars=%d chunks=%d speaker=%s sample_rate=%s speed=%.2f repo=%s model_file=%s",
            len(text),
            len(chunks),
            TTS.russian_speaker,
            TTS.russian_sample_rate,
            speed,
            SILERO_REPO_DIR,
            SILERO_RU_MODEL_FILE,
        )
        if progress_callback:
            progress_callback(12)

        try:
            model = self._load_model()
        except Exception as exc:
            logger.warning(
                "Silero Russian TTS unavailable; falling back to Piper Russian voice=%s-%s reason=%s",
                PIPER_RU_VOICE,
                PIPER_RU_QUALITY,
                exc,
            )
            try:
                self.piper.speak(chunks, speed, stop_checker, stage_callback, progress_callback)
            except Exception as piper_exc:
                logger.exception("Piper Russian TTS unavailable; falling back to macOS say voice=Milena: %s", piper_exc)
                self._speak_with_macos_say(chunks, speed, stop_checker, stage_callback, progress_callback)
            return
        if progress_callback:
            progress_callback(20)

        audios = []
        for index, chunk in enumerate(chunks, start=1):
            if stop_checker():
                logger.info("Silero TTS cancelled before chunk %d/%d", index, len(chunks))
                return
            chunk_started_at = time.time()
            audio = model.apply_tts(
                text=chunk,
                speaker=TTS.russian_speaker,
                sample_rate=TTS.russian_sample_rate,
                put_accent=True,
                put_yo=True,
            )
            if hasattr(audio, "detach"):
                audio = audio.detach().cpu().numpy()
            audios.append(audio)
            logger.info(
                "Silero TTS generated chunk %d/%d: chars=%d samples=%d duration=%.2fs",
                index,
                len(chunks),
                len(chunk),
                len(audio),
                time.time() - chunk_started_at,
            )
            if progress_callback:
                progress_callback(20 + round(index * 80 / len(chunks)))

        if stop_checker():
            return
        import numpy as np

        audio = np.concatenate(audios)
        playback_rate = int(TTS.russian_sample_rate * max(0.75, min(1.65, speed)))
        logger.info(
            "Silero TTS generation complete: chunks=%d samples=%d playback_rate=%s total_duration=%.2fs",
            len(chunks),
            len(audio),
            playback_rate,
            time.time() - started_at,
        )
        if stage_callback:
            stage_callback("speaking")
        audio_output.play(audio, playback_rate, stop_checker, progress_callback)

    def stop(self):
        audio_output.stop()
        process = self.say_process
        if process and process.poll() is None:
            process.terminate()
        self.say_process = None

    def _speak_with_macos_say(self, chunks, speed, stop_checker, stage_callback=None, progress_callback=None):
        if stage_callback:
            stage_callback("generating")
        if progress_callback:
            progress_callback(20)
        rate = str(int(190 * max(0.75, min(1.65, speed))))
        logger.warning(
            "macOS say fallback active: voice=Milena rate=%s chunks=%d reason=neural_russian_model_unavailable",
            rate,
            len(chunks),
        )
        if progress_callback:
            progress_callback(100)
        for index, chunk in enumerate(chunks, start=1):
            if stop_checker():
                logger.info("macOS say fallback cancelled before chunk %d/%d", index, len(chunks))
                return
            if stage_callback:
                stage_callback("speaking")
            logger.info("macOS say fallback speaking chunk %d/%d: chars=%d", index, len(chunks), len(chunk))
            self.say_process = subprocess.Popen(["/usr/bin/say", "-v", "Milena", "-r", rate, chunk])
            while self.say_process.poll() is None:
                if stop_checker():
                    self.stop()
                    return
                time.sleep(0.05)
        self.say_process = None

    def _load_model(self):
        if self.model is not None:
            logger.info("Silero model reused: speaker=%s", TTS.russian_speaker)
            return self.model
        if not SILERO_REPO_DIR.exists():
            raise RuntimeError(f"Silero repo cache is missing: {SILERO_REPO_DIR}")
        if not SILERO_RU_MODEL_FILE.exists():
            raise RuntimeError(f"Silero Russian model file is missing: {SILERO_RU_MODEL_FILE}")
        import torch

        torch.set_num_threads(max(1, min(4, os.cpu_count() or 1)))
        self.device = torch.device("cpu")
        logger.info("Silero model loading from local cache: repo=%s model_file=%s", SILERO_REPO_DIR, SILERO_RU_MODEL_FILE)
        self.model, _example_text = torch.hub.load(
            repo_or_dir=str(SILERO_REPO_DIR),
            source="local",
            model="silero_tts",
            language="ru",
            speaker="v4_ru",
            trust_repo=True,
        )
        self.model.to(self.device)
        logger.info("Silero model loaded: speaker=%s device=%s", TTS.russian_speaker, self.device)
        return self.model


class LocalSpeechEngine:
    def __init__(self):
        self.premium = MlxChatterboxSpeechEngine()
        self.english = KokoroSpeechEngine()
        self.russian = SileroRussianSpeechEngine()

    def speak(self, text, speed, stop_checker, stage_callback=None, progress_callback=None):
        if stage_callback:
            stage_callback("generating")
        if progress_callback:
            progress_callback(5)
        language = detect_tts_language(text)
        logger.info(
            "Local TTS route: detected_language=%s chars=%d speed=%.2f cyrillic=%d latin=%d",
            language,
            len(text),
            speed,
            len(re.findall(r"[А-Яа-яЁё]", text)),
            len(re.findall(r"[A-Za-z]", text)),
        )
        if TTS.engine == "mlx_chatterbox":
            try:
                self.premium.speak(text, speed, stop_checker, stage_callback, progress_callback)
                return
            except Exception as exc:
                logger.exception("MLX Chatterbox TTS failed; falling back to legacy route: %s", exc)
                if progress_callback:
                    progress_callback(8)

        if language == "ru":
            self.russian.speak(text, speed, stop_checker, stage_callback, progress_callback)
        else:
            self.english.speak(text, speed, stop_checker, stage_callback, progress_callback)

    def stop(self):
        self.premium.stop()
        self.english.stop()
        self.russian.stop()


speech_engine = LocalSpeechEngine()


class TextToSpeechWorker(QThread):
    finished_signal = pyqtSignal(object)
    stage_signal = pyqtSignal(str)
    progress_signal = pyqtSignal(object)

    def __init__(self):
        super().__init__()
        self.is_cancelled = False
        self.focus_target = None
        self.selection_reader = SelectionReader()

    def speak_selection(self, focus_target):
        if self.isRunning():
            return
        self.is_cancelled = False
        self.focus_target = focus_target
        self.start()

    def cancel(self):
        self.is_cancelled = True
        speech_engine.stop()

    def run(self):
        result = None
        try:
            logger.info("Reading selected text for local TTS")
            self.stage_signal.emit("generating")
            self.progress_signal.emit(1)
            text = self.selection_reader.read_selected_text(self.focus_target)
            if self.is_cancelled:
                return
            if not text:
                logger.warning("No selected text found for local TTS")
                return

            text = text[: TTS.max_chars]
            tts_settings.reload()
            self.progress_signal.emit(3)
            logger.info("Speaking selected text locally: %d chars at %.2fx", len(text), tts_settings.speed)
            speech_engine.speak(
                text,
                tts_settings.speed,
                lambda: self.is_cancelled,
                self.stage_signal.emit,
                self.progress_signal.emit,
            )
            result = None if self.is_cancelled else True
        except Exception as exc:
            if not self.is_cancelled:
                logger.exception("Local TTS error: %s", exc)
        finally:
            logger.info("Local TTS worker finished: cancelled=%s ok=%s", self.is_cancelled, bool(result))
            self.finished_signal.emit(result)


class PasteController:
    edit_menu_names = ("Edit", "Правка", "Редактирование", "Редагування")
    paste_item_names = ("Paste", "Вставить", "Вставити")

    def paste(self, text, focus_target=None):
        self._copy_to_clipboard(text)
        logger.info("Text copied to clipboard")
        FocusController.restore(focus_target)
        time.sleep(0.18)
        if not self._paste_via_menu():
            self._send_cmd_v()
        logger.info("Paste command sent")

    def _copy_to_clipboard(self, text):
        pyperclip.copy(text)
        pasteboard = NSPasteboard.generalPasteboard()
        pasteboard.clearContents()
        if not pasteboard.setString_forType_(text, NSPasteboardTypeString):
            raise RuntimeError("NSPasteboard rejected text")
        self._copy_with_pbcopy(text)
        self._verify_clipboard(text)

    def _copy_with_pbcopy(self, text):
        subprocess.run(
            ["/usr/bin/pbcopy"],
            input=text,
            text=True,
            check=True,
            capture_output=True,
        )

    def _verify_clipboard(self, expected_text):
        result = subprocess.run(
            ["/usr/bin/pbpaste"],
            text=True,
            check=True,
            capture_output=True,
        )
        if result.stdout != expected_text:
            raise RuntimeError("Clipboard verification failed after copy")

    def _paste_via_menu(self):
        edit_menu_names = ", ".join(json.dumps(name, ensure_ascii=False) for name in self.edit_menu_names)
        paste_item_names = ", ".join(json.dumps(name, ensure_ascii=False) for name in self.paste_item_names)
        script = f"""
        tell application "System Events"
            set targetProcess to first application process whose frontmost is true
            set editMenuNames to {{{edit_menu_names}}}
            set pasteItemNames to {{{paste_item_names}}}
            tell targetProcess
                repeat with editMenuName in editMenuNames
                    if exists menu editMenuName of menu bar 1 then
                        repeat with pasteItemName in pasteItemNames
                            if exists menu item pasteItemName of menu editMenuName of menu bar 1 then
                                click menu item pasteItemName of menu editMenuName of menu bar 1
                                return "ok"
                            end if
                        end repeat
                    end if
                end repeat
            end tell
        end tell
        error "Paste menu item not found"
        """
        try:
            subprocess.run(["osascript", "-e", script], check=True, capture_output=True)
            return True
        except subprocess.CalledProcessError as exc:
            logger.warning("Menu paste failed; falling back to Cmd+V: %s", exc)
            return False

    def _send_cmd_v(self):
        send_cmd_key(KEY_CODE_V)


class NativeStatusMenuTarget(NSObject):
    def initWithController_(self, controller):
        self = objc.super(NativeStatusMenuTarget, self).init()
        if self is None:
            return None
        self.controller = controller
        return self

    def toggleMiniApp_(self, sender):
        self.controller.toggle_mini_app()


class NativeStatusItem:
    visible_length = 28.0

    def __init__(self, controller):
        self.item = None
        self.button = None
        self.menu_target = None
        try:
            self.item = NSStatusBar.systemStatusBar().statusItemWithLength_(self.visible_length)
            self.button = self.item.button()
            self._configure_button()
            self._setup_action(controller)
            self.set_state("idle")
            logger.info("Native macOS status item installed: length=%.1f title=%s", self.visible_length, self.button.title())
        except Exception as exc:
            logger.warning("Could not install native macOS status item: %s", exc)

    def _configure_button(self):
        if self.button is None:
            return
        try:
            image = NSImage.imageWithSystemSymbolName_accessibilityDescription_("mic.fill", "Whisper Dictation")
            if image is not None:
                image.setTemplate_(True)
                self.button.setImage_(image)
                self.button.setTitle_("")
                return
        except Exception as exc:
            logger.warning("Could not configure native status symbol: %s", exc)
        self.button.setTitle_("W")

    def _setup_action(self, controller):
        self.menu_target = NativeStatusMenuTarget.alloc().initWithController_(controller)
        self.button.setTarget_(self.menu_target)
        self.button.setAction_("toggleMiniApp:")
        logger.info("Native macOS status button action installed")

    def is_available(self):
        return self.item is not None and self.button is not None

    def update_settings_items(self):
        if self.button is not None:
            self.button.setToolTip_(f"Whisper Dictation - ${cost_manager.total_cost:.5f}, {tts_settings.speed:.2f}x")

    def set_state(self, state):
        if self.button is None:
            return
        titles = {
            "idle": "W",
            "recording": "R",
            "processing": "...",
            "generating": "T",
            "speaking": "S",
            "tts_finished": "OK",
            "done": "OK",
        }
        tooltips = {
            "idle": "Whisper Dictation: idle",
            "recording": "Whisper Dictation: recording",
            "processing": "Whisper Dictation: transcribing",
            "generating": "Whisper Dictation: generating local speech",
            "speaking": "Whisper Dictation: speaking selected text",
            "tts_finished": "Whisper Dictation: local speech finished",
            "done": "Whisper Dictation: done",
        }
        if self.button.image() is None:
            self.button.setTitle_(titles.get(state, "W"))
            self.button.setToolTip_(tooltips.get(state, "Whisper Dictation"))


class NoopStatusItem:
    def is_available(self):
        return True

    def update_settings_items(self):
        pass

    def set_state(self, state):
        pass


class StatusBarApp(QSystemTrayIcon):
    def __init__(self, app):
        super().__init__()
        self.app = app
        self.state = "idle"
        self.frame = 0
        self.last_shift = False
        self.last_option = False
        self.shift_press_time = 0.0
        self.option_press_time = 0.0
        self.shift_tap_armed = False
        self.option_tap_armed = False
        self.shift_tap_armed_until = 0.0
        self.option_tap_armed_until = 0.0
        self.ignore_shift_release = False
        self.ignore_option_release = False
        self.hotkey_suppressed_until = 0.0
        self.waiting_for_hold = False
        self.waiting_for_option_hold = False
        self.event_monitors = []
        self.focus_target = None
        self.tts_focus_target = None
        self.tts_started_at = 0.0
        self.tts_activity_at = 0.0
        self.tts_diagnostic_at = 0.0
        self.retired_tts_workers = []
        self.paste_controller = PasteController()

        self.log_window = LogWindow()
        self.log_window.bind_controller(self)
        self.voice_meter = CompactVoiceIndicator()
        self.voice_meter.bind_controller(self)
        self._setup_logging()
        self.native_status = NoopStatusItem()
        self._setup_menu()
        self._setup_timers()
        self._create_worker()
        self._create_tts_worker()

        self.update_icon()
        use_qt_tray_fallback = not self.native_status.is_available()
        self.setVisible(use_qt_tray_fallback)
        if use_qt_tray_fallback and not QSystemTrayIcon.isSystemTrayAvailable():
            logger.warning("System tray is unavailable; showing diagnostics window")
            self.show_logs()
            self.log_window.setWindowTitle("Whisper Dictation (no tray)")
            self.log_window.append_log("System tray unavailable. App is running in fallback visibility mode.")
        logger.info("Menu bar UI mode: external Swift helper")
        logger.info("Whisper Dictation started. Tap Shift, press Shift again to record, press Shift while recording to transcribe. Same for Option TTS.")

    def _setup_logging(self):
        configure_file_logging()
        if not any(isinstance(handler, QtLogHandler) for handler in logger.handlers):
            gui_handler = QtLogHandler()
            gui_handler.setFormatter(logging.Formatter("%(asctime)s - %(message)s", datefmt="%H:%M:%S"))
            gui_handler.log_signal.connect(self.log_window.append_log)
            logger.addHandler(gui_handler)

        if not any(isinstance(handler, logging.StreamHandler) and not isinstance(handler, RotatingFileHandler) for handler in logger.handlers):
            console_handler = logging.StreamHandler(sys.stdout)
            console_handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - %(message)s"))
            logger.addHandler(console_handler)
        logger.info("SystemTray available=%s log_file=%s", QSystemTrayIcon.isSystemTrayAvailable(), LOG_FILE)

    def _setup_menu(self):
        menu = QMenu()
        logs_action = menu.addAction("View Logs & Cost")
        logs_action.triggered.connect(self.show_logs)
        menu.addSeparator()
        slower_action = menu.addAction("TTS Slower")
        slower_action.triggered.connect(lambda: self.adjust_tts_speed(-TTS_SPEED_STEP))
        faster_action = menu.addAction("TTS Faster")
        faster_action.triggered.connect(lambda: self.adjust_tts_speed(TTS_SPEED_STEP))
        reset_speed_action = menu.addAction("Reset TTS Speed")
        reset_speed_action.triggered.connect(lambda: self.set_tts_speed(DEFAULT_TTS_SPEED))
        menu.addSeparator()
        stop_tts_action = menu.addAction("Stop Local TTS")
        stop_tts_action.triggered.connect(self.stop_tts)
        menu.addSeparator()
        quit_action = menu.addAction("Quit")
        quit_action.triggered.connect(self.app.quit)
        self.setContextMenu(menu)

    def _setup_timers(self):
        self.icon_timer = QTimer()
        self.icon_timer.timeout.connect(self.update_icon)
        self.icon_timer.start(33)

        self._setup_key_monitors()

        self.key_timer = QTimer()
        self.key_timer.timeout.connect(self.check_keys)
        self.key_timer.start(120)

        self.control_timer = QTimer()
        self.control_timer.timeout.connect(self._check_external_controls)
        self.control_timer.start(500)

    def _check_external_controls(self):
        if os.path.exists(TTS_STOP_FILE):
            try:
                os.remove(TTS_STOP_FILE)
            except OSError:
                pass
            logger.info("External stop TTS requested")
            self.stop_tts()
        self._check_tts_watchdog()

    def _begin_tts_tracking(self):
        now = time.time()
        self.tts_started_at = now
        self.tts_activity_at = now
        self.tts_diagnostic_at = 0.0
        logger.info("TTS tracking started: state=%s audio=%s", self.state, audio_output.snapshot())

    def _clear_tts_tracking(self):
        if self.tts_started_at > 0.0:
            logger.info(
                "TTS tracking cleared: state=%s duration=%.2fs audio=%s indicator_mode=%s visible=%s",
                self.state,
                time.time() - self.tts_started_at,
                audio_output.snapshot(),
                self.voice_meter.mode,
                self.voice_meter.isVisible(),
            )
        self.tts_started_at = 0.0
        self.tts_activity_at = 0.0
        self.tts_diagnostic_at = 0.0

    def _check_tts_watchdog(self):
        if self.state == "idle" and self.voice_meter.isVisible() and self.voice_meter.mode in TTS_ACTIVE_STATES:
            logger.warning(
                "TTS watchdog hid stale indicator while idle: indicator_mode=%s audio=%s",
                self.voice_meter.mode,
                audio_output.snapshot(),
            )
            self.voice_meter.set_mode("idle")
            return
        if self.state not in TTS_ACTIVE_STATES:
            return
        now = time.time()
        if self.tts_started_at <= 0.0:
            self._begin_tts_tracking()
        if now - self.tts_diagnostic_at >= TTS_DIAGNOSTIC_INTERVAL_SECONDS:
            worker_running = bool(self.tts_worker and self.tts_worker.isRunning())
            logger.info(
                "TTS watchdog diagnostic: state=%s worker_running=%s elapsed=%.1fs inactive=%.1fs audio=%s indicator_mode=%s visible=%s",
                self.state,
                worker_running,
                now - self.tts_started_at,
                now - self.tts_activity_at,
                audio_output.snapshot(),
                self.voice_meter.mode,
                self.voice_meter.isVisible(),
            )
            self.tts_diagnostic_at = now
        if self.state == "generating" and audio_output.snapshot().get("is_playing"):
            logger.warning("TTS watchdog repaired state: audio is playing while UI state is generating")
            self.set_state("speaking")
            return
        if self.tts_worker and not self.tts_worker.isRunning() and now - self.tts_started_at > 1.0:
            logger.warning("TTS watchdog cleared stale UI state=%s; worker is not running", self.state)
            self._show_tts_finished(audio_output.snapshot(), reason="watchdog_worker_stopped")
            self.tts_focus_target = None
            self._clear_tts_tracking()
            self._replace_tts_worker()
            return
        if now - self.tts_activity_at > TTS_ACTIVITY_TIMEOUT_SECONDS:
            logger.warning(
                "TTS watchdog cancelling inactive TTS: state=%s elapsed=%.1fs inactive=%.1fs audio=%s",
                self.state,
                now - self.tts_started_at,
                now - self.tts_activity_at,
                audio_output.snapshot(),
            )
            self.stop_tts()

    def _clear_hotkey_arms(self):
        self.shift_tap_armed = False
        self.option_tap_armed = False
        self.shift_tap_armed_until = 0.0
        self.option_tap_armed_until = 0.0
        self.waiting_for_hold = False
        self.waiting_for_option_hold = False
        self.ignore_shift_release = False
        self.ignore_option_release = False

    def _suppress_hotkeys(self, reason):
        self.hotkey_suppressed_until = time.time() + HOTKEY.dirty_key_cooldown
        self._clear_hotkey_arms()
        logger.info("Hotkey gestures suppressed for %.1fs: %s", HOTKEY.dirty_key_cooldown, reason)

    def _hotkeys_suppressed(self, now):
        return now < self.hotkey_suppressed_until

    def _suppressed_remaining(self, now):
        return max(0.0, self.hotkey_suppressed_until - now)

    def _is_only_modifier(self, flags, allowed_modifier):
        if flags is None:
            return True
        return (int(flags) & int(HOTKEY_MODIFIER_MASK | allowed_modifier)) == int(allowed_modifier)

    def _setup_key_monitors(self):
        def handle_flags_changed(event):
            try:
                flags = event.modifierFlags()
                self._handle_shift_state(bool(flags & NSEventModifierFlagShift), flags)
                self._handle_option_state(bool(flags & NSEventModifierFlagOption), flags)
            except Exception as exc:
                logger.warning("Modifier event monitor failed: %s", exc)
            return event

        def handle_key_down(event):
            try:
                self._suppress_hotkeys(f"keyDown keyCode={event.keyCode()}")
            except Exception as exc:
                logger.warning("Key event monitor failed: %s", exc)
            return event

        try:
            global_monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
                NSEVENT_MASK_FLAGS_CHANGED,
                handle_flags_changed,
            )
            if global_monitor is not None:
                self.event_monitors.append(global_monitor)

            local_monitor = NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
                NSEVENT_MASK_FLAGS_CHANGED,
                handle_flags_changed,
            )
            if local_monitor is not None:
                self.event_monitors.append(local_monitor)

            global_key_monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
                NSEVENT_MASK_KEY_DOWN,
                handle_key_down,
            )
            if global_key_monitor is not None:
                self.event_monitors.append(global_key_monitor)

            local_key_monitor = NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
                NSEVENT_MASK_KEY_DOWN,
                handle_key_down,
            )
            if local_key_monitor is not None:
                self.event_monitors.append(local_key_monitor)

            logger.info("Modifier event monitors installed: %s", len(self.event_monitors))
        except Exception as exc:
            logger.warning("Could not install modifier event monitors; timer fallback remains active: %s", exc)

    def _create_worker(self):
        self.worker = AudioWorker()
        self.worker.finished_signal.connect(self.on_transcription_done)
        self.worker.cost_update_signal.connect(self.log_window.update_cost_display)
        self.worker.cost_update_signal.connect(self.refresh_settings_ui)
        self.worker.limit_reached_signal.connect(self.on_auto_stop)
        self.worker.level_signal.connect(self.voice_meter.set_level)

    def _create_tts_worker(self):
        self.tts_worker = TextToSpeechWorker()
        self.tts_worker.finished_signal.connect(self.on_tts_done)
        self.tts_worker.stage_signal.connect(self.on_tts_stage)
        self.tts_worker.progress_signal.connect(self.on_tts_progress)

    def _disconnect_tts_worker_signals(self, worker):
        if worker is None:
            return
        for signal, slot in (
            (worker.finished_signal, self.on_tts_done),
            (worker.stage_signal, self.on_tts_stage),
            (worker.progress_signal, self.on_tts_progress),
        ):
            try:
                signal.disconnect(slot)
            except (TypeError, RuntimeError):
                pass

    def _forget_retired_tts_worker(self, worker):
        if worker in self.retired_tts_workers:
            self.retired_tts_workers.remove(worker)
        try:
            worker.deleteLater()
        except RuntimeError:
            pass

    def _retire_tts_worker(self, worker, disconnect=False):
        if worker is None:
            return
        if disconnect:
            self._disconnect_tts_worker_signals(worker)
        if worker not in self.retired_tts_workers:
            self.retired_tts_workers.append(worker)
            try:
                worker.finished.connect(lambda worker=worker: self._forget_retired_tts_worker(worker))
            except TypeError:
                pass
        if not worker.isRunning():
            QTimer.singleShot(0, lambda worker=worker: self._forget_retired_tts_worker(worker))

    def _replace_worker(self):
        if self.worker and self.worker.isRunning():
            self.worker.cancel()
        self._create_worker()

    def _replace_tts_worker(self):
        if self.tts_worker and self.tts_worker.isRunning():
            old_worker = self.tts_worker
            old_worker.cancel()
            self._retire_tts_worker(old_worker, disconnect=True)
        self._create_tts_worker()

    def set_state(self, state):
        logger.info("UI state change: %s -> %s", self.state, state)
        self.state = state
        self.native_status.set_state(state)
        self.voice_meter.set_mode(state)
        self.update_icon()

    def refresh_settings_ui(self):
        self.log_window.update_cost_display()
        self.log_window.sync_settings_display()
        self.native_status.update_settings_items()

    def set_tts_speed(self, speed):
        tts_settings.set_speed(speed)
        self.refresh_settings_ui()
        logger.info("TTS speed set to %.2fx", tts_settings.speed)

    def adjust_tts_speed(self, delta):
        self.set_tts_speed(tts_settings.speed + delta)

    def toggle_mini_app(self):
        if self.log_window.isVisible():
            self.log_window.hide()
            return
        self.show_logs()

    def show_logs(self):
        self.refresh_settings_ui()
        self._position_log_window_top_right()
        self.log_window.show()
        self.log_window.raise_()
        self.log_window.activateWindow()

    def _position_log_window_top_right(self):
        screen = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
        if screen is None:
            return
        area = screen.availableGeometry()
        margin = 12
        x = area.x() + area.width() - self.log_window.width() - margin
        y = area.y() + margin
        self.log_window.move(x, y)

    def on_auto_stop(self):
        if self.state == "recording":
            self.set_state("processing")
            self.waiting_for_hold = False

    def _start_dictation_from_hold(self):
        self.focus_target = FocusController.capture()
        logger.info("Shift tap sequence detected; starting dictation")
        self.set_state("recording")
        QTimer.singleShot(80, lambda target=self.focus_target: FocusController.restore(target))
        self.worker.start_recording()

    def _stop_dictation_from_toggle(self):
        logger.info("Shift pressed while recording; stopping dictation")
        self.set_state("processing")
        self.worker.stop_recording()
        self.waiting_for_hold = False
        self.shift_tap_armed = False
        self.shift_tap_armed_until = 0.0

    def _start_tts_from_hold(self):
        logger.info("Option tap sequence detected; speaking selected text")
        self.voice_meter.set_progress(0)
        self.voice_meter.set_playback_position(0, 0.0, 0.0)
        self._begin_tts_tracking()
        self.set_state("generating")
        self.tts_worker.speak_selection(self.tts_focus_target)

    def check_keys(self):
        try:
            flags = NSEvent.modifierFlags()
            is_shift = bool(flags & NSEventModifierFlagShift)
            is_option = bool(flags & NSEventModifierFlagOption)
        except Exception:
            is_shift = False
            is_option = False
            flags = None
        self._handle_shift_state(is_shift, flags)
        self._handle_option_state(is_option, flags)

    def _handle_shift_state(self, is_shift, flags=None):
        now = time.time()
        if self.shift_tap_armed and now > self.shift_tap_armed_until:
            self.shift_tap_armed = False
            self.shift_tap_armed_until = 0.0

        if is_shift and not self.last_shift:
            if not self._is_only_modifier(flags, NSEventModifierFlagShift):
                self._suppress_hotkeys("Shift pressed with another modifier")
                self.last_shift = is_shift
                return
            suppressed_remaining = self._suppressed_remaining(now)
            logger.info(
                "Shift press: state=%s armed=%s suppressed_remaining=%.2fs",
                self.state,
                self.shift_tap_armed,
                suppressed_remaining,
            )
            if self.state == "recording":
                self._stop_dictation_from_toggle()
            elif self.state == "processing":
                logger.warning("Current transcription cancelled by user")
                self._replace_worker()
                self.set_state("idle")
                self.focus_target = None
                self.waiting_for_hold = False
                self.shift_tap_armed = False
                self.shift_tap_armed_until = 0.0
            elif self.state in TTS_ACTIVE_STATES:
                logger.info("Shift pressed; stopping local TTS before dictation")
                self.stop_tts()
                self.ignore_shift_release = True
                self.shift_press_time = now
                if not self._hotkeys_suppressed(now) and self.shift_tap_armed and now <= self.shift_tap_armed_until:
                    self.shift_tap_armed = False
                    self.shift_tap_armed_until = 0.0
                    self._start_dictation_from_hold()
                self.waiting_for_hold = False
            else:
                self.shift_press_time = now
                if (
                    suppressed_remaining <= 0.0
                    and self.state in HOTKEY_IDLE_STATES
                    and self.shift_tap_armed
                    and now <= self.shift_tap_armed_until
                ):
                    self.shift_tap_armed = False
                    self.shift_tap_armed_until = 0.0
                    self._start_dictation_from_hold()
                elif suppressed_remaining > 0.0:
                    logger.info("Shift press ignored: keyboard cooldown %.2fs remaining", suppressed_remaining)
                self.waiting_for_hold = False

        elif not is_shift and self.last_shift:
            suppressed_remaining = self._suppressed_remaining(now)
            logger.info(
                "Shift release: state=%s duration=%.2fs suppressed_remaining=%.2fs",
                self.state,
                now - self.shift_press_time,
                suppressed_remaining,
            )
            if self.ignore_shift_release:
                logger.info("Shift release ignored: release belongs to TTS stop gesture")
                self.ignore_shift_release = False
            elif self.state in HOTKEY_IDLE_STATES and suppressed_remaining <= 0.0:
                press_duration = now - self.shift_press_time
                if 0 <= press_duration <= HOTKEY.tap_max_duration:
                    self.shift_tap_armed = True
                    self.shift_tap_armed_until = now + HOTKEY.tap_arm_window
                    logger.info("Shift tap armed; press Shift within %.1fs to start dictation", HOTKEY.tap_arm_window)
                else:
                    self.shift_tap_armed = False
                    self.shift_tap_armed_until = 0.0
                    logger.info("Shift release ignored: duration %.2fs is not a tap", press_duration)
            elif suppressed_remaining > 0.0:
                logger.info("Shift release ignored: keyboard cooldown %.2fs remaining", suppressed_remaining)
            self.waiting_for_hold = False

        self.last_shift = is_shift

    def _handle_option_state(self, is_option, flags=None):
        now = time.time()
        if self.option_tap_armed and now > self.option_tap_armed_until:
            self.option_tap_armed = False
            self.option_tap_armed_until = 0.0

        if is_option and not self.last_option:
            if not self._is_only_modifier(flags, NSEventModifierFlagOption):
                self._suppress_hotkeys("Option pressed with another modifier")
                self.last_option = is_option
                return
            suppressed_remaining = self._suppressed_remaining(now)
            logger.info(
                "Option press: state=%s armed=%s suppressed_remaining=%.2fs",
                self.state,
                self.option_tap_armed,
                suppressed_remaining,
            )
            if self.state in TTS_ACTIVE_STATES:
                logger.info("Local TTS stopped by user")
                self.stop_tts()
                self.ignore_option_release = True
                self.waiting_for_option_hold = False
                self.option_tap_armed = False
                self.option_tap_armed_until = 0.0
            elif self.state in HOTKEY_IDLE_STATES:
                self.tts_focus_target = FocusController.capture()
                self.option_press_time = now
                if suppressed_remaining <= 0.0 and self.option_tap_armed and now <= self.option_tap_armed_until:
                    self.option_tap_armed = False
                    self.option_tap_armed_until = 0.0
                    self._start_tts_from_hold()
                elif suppressed_remaining > 0.0:
                    logger.info("Option press ignored: keyboard cooldown %.2fs remaining", suppressed_remaining)
                self.waiting_for_option_hold = False

        elif not is_option and self.last_option:
            suppressed_remaining = self._suppressed_remaining(now)
            logger.info(
                "Option release: state=%s duration=%.2fs suppressed_remaining=%.2fs",
                self.state,
                now - self.option_press_time,
                suppressed_remaining,
            )
            if self.ignore_option_release:
                logger.info("Option release ignored: release belongs to TTS stop gesture")
                self.ignore_option_release = False
            elif self.state in HOTKEY_IDLE_STATES and suppressed_remaining <= 0.0:
                press_duration = now - self.option_press_time
                if 0 <= press_duration <= HOTKEY.tap_max_duration:
                    self.option_tap_armed = True
                    self.option_tap_armed_until = now + HOTKEY.tap_arm_window
                    logger.info("Option tap armed; press Option within %.1fs to speak selected text", HOTKEY.tap_arm_window)
                else:
                    self.option_tap_armed = False
                    self.option_tap_armed_until = 0.0
                    logger.info("Option release ignored: duration %.2fs is not a tap", press_duration)
            elif suppressed_remaining > 0.0:
                logger.info("Option release ignored: keyboard cooldown %.2fs remaining", suppressed_remaining)
            self.waiting_for_option_hold = False

        self.last_option = is_option

    def on_transcription_done(self, text):
        if text is None:
            self.set_state("idle")
            self._replace_worker()
            self.focus_target = None
            return
        try:
            self.paste_controller.paste(text, self.focus_target)
            self.set_state("done")
            QTimer.singleShot(1500, lambda: self.set_state("idle") if self.state == "done" else None)
        except Exception as exc:
            logger.exception("Paste error: %s", exc)
            self.set_state("idle")
        finally:
            self.focus_target = None
            self._replace_worker()

    def _show_tts_finished(self, snapshot=None, reason="finished"):
        snapshot = snapshot or audio_output.snapshot()
        duration = float(snapshot.get("duration") or self.voice_meter.playback_duration or 0.0)
        elapsed = float(snapshot.get("elapsed") or self.voice_meter.playback_elapsed or 0.0)
        progress = int(snapshot.get("progress", self.voice_meter.progress))
        if reason == "completed" and duration > 0.0:
            elapsed = duration
            progress = 100
        elif duration <= 0.0:
            progress = self.voice_meter.progress
        self.voice_meter.set_playback_position(progress, elapsed, duration, paused=False)
        logger.info(
            "TTS finished widget shown: reason=%s progress=%s elapsed=%.2fs duration=%.2fs snapshot=%s",
            reason,
            progress,
            elapsed,
            duration,
            snapshot,
        )
        self.set_state("tts_finished")

    def stop_tts(self, keep_widget=True):
        was_tts_widget_visible = self.voice_meter.isVisible() and self.voice_meter.mode in TTS_WIDGET_STATES
        logger.info(
            "TTS stop requested from controller: state=%s worker_running=%s keep_widget=%s audio=%s",
            self.state,
            bool(self.tts_worker and self.tts_worker.isRunning()),
            keep_widget,
            audio_output.snapshot(),
        )
        if self.tts_worker and self.tts_worker.isRunning():
            self.tts_worker.cancel()
        audio_output.stop()
        self.tts_focus_target = None
        if keep_widget and (self.state in TTS_WIDGET_STATES or was_tts_widget_visible):
            self._show_tts_finished(audio_output.snapshot(), reason="stopped")
            self._clear_tts_tracking()
        elif self.state in TTS_WIDGET_STATES:
            self._clear_tts_tracking()
            self.set_state("idle")

    def close_tts_widget(self):
        logger.info(
            "TTS widget close requested: state=%s worker_running=%s audio=%s",
            self.state,
            bool(self.tts_worker and self.tts_worker.isRunning()),
            audio_output.snapshot(),
        )
        audio_output.stop()
        self.tts_focus_target = None
        self._clear_tts_tracking()
        if self.tts_worker and self.tts_worker.isRunning():
            self._replace_tts_worker()
        if self.state in TTS_WIDGET_STATES or self.voice_meter.isVisible():
            self.set_state("idle")

    def seek_tts(self, seconds):
        logger.info("TTS seek requested from controller: delta=%.1fs state=%s", seconds, self.state)
        snapshot = audio_output.seek_relative(seconds)
        if snapshot is None:
            return
        self.on_tts_progress(snapshot)

    def seek_tts_fraction(self, fraction):
        logger.info("TTS scrub requested from controller: fraction=%.3f state=%s", fraction, self.state)
        snapshot = audio_output.seek_fraction(fraction)
        if snapshot is None:
            return
        self.on_tts_progress(snapshot)

    def toggle_tts_pause(self):
        logger.info("TTS pause toggle requested from controller: state=%s", self.state)
        snapshot = audio_output.toggle_paused()
        if snapshot is None:
            return
        self.on_tts_progress(snapshot)

    def on_tts_stage(self, stage):
        logger.info("TTS UI stage: %s current_state=%s audio=%s", stage, self.state, audio_output.snapshot())
        self.tts_activity_at = time.time()
        if stage == "speaking":
            self.voice_meter.set_playback_position(0, 0.0, 0.0, paused=False)
            if self.state in TTS_ACTIVE_STATES:
                self.set_state("speaking")
            return
        if self.state in TTS_ACTIVE_STATES:
            self.set_state(stage)

    def on_tts_progress(self, progress):
        logger.info("TTS UI progress: %s", progress)
        self.tts_activity_at = time.time()
        if isinstance(progress, dict):
            self.voice_meter.set_playback_position(
                progress.get("progress", 0),
                progress.get("elapsed", 0.0),
                progress.get("duration", 0.0),
                paused=progress.get("paused", False),
            )
        else:
            self.voice_meter.set_progress(progress)

    def on_tts_done(self, ok):
        finished_worker = self.sender()
        logger.info(
            "TTS UI done: ok=%s state=%s current_worker=%s sender=%s audio=%s",
            ok,
            self.state,
            id(self.tts_worker) if self.tts_worker else None,
            id(finished_worker) if finished_worker else None,
            audio_output.snapshot(),
        )
        if finished_worker is not None and finished_worker is not self.tts_worker:
            logger.info("Ignoring stale TTS worker completion: sender=%s current=%s", id(finished_worker), id(self.tts_worker))
            self._retire_tts_worker(finished_worker, disconnect=True)
            return

        snapshot = audio_output.snapshot()
        if ok:
            self._show_tts_finished(snapshot, reason="completed")
        elif self.state in TTS_WIDGET_STATES:
            self._show_tts_finished(snapshot, reason="stopped")
        self.tts_focus_target = None
        self._clear_tts_tracking()
        self._retire_tts_worker(finished_worker or self.tts_worker, disconnect=True)
        self._create_tts_worker()

    def update_icon(self):
        self.frame += 1
        size = 24
        pixmap = QPixmap(size, size)
        pixmap.fill(Qt.GlobalColor.transparent)
        painter = QPainter(pixmap)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        center = size / 2

        if self.state == "idle":
            painter.setBrush(QBrush(QColor(73, 228, 255)))
            painter.setPen(QPen(QColor(14, 105, 160), 2))
            painter.drawEllipse(QRectF(4, 4, 14, 14))
            self.setToolTip("Whisper: idle")
        elif self.state == "recording":
            pulse = (math.sin(self.frame * 0.22) + 1) / 2
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QBrush(QColor(255, 69, 58)))
            painter.drawEllipse(QPointF(center, center), 6 + pulse * 3.5, 6 + pulse * 3.5)
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.setPen(QPen(QColor(255, 69, 58, 110), 1))
            painter.drawEllipse(QPointF(center, center), 10.5, 10.5)
            self.setToolTip("Whisper: recording")
        elif self.state == "processing":
            painter.setPen(QPen(QColor(10, 132, 255), 3))
            painter.drawArc(QRectF(4, 4, 14, 14), ((self.frame * 20) % 360) * 16, 270 * 16)
            self.setToolTip("Whisper: processing")
        elif self.state == "generating":
            painter.setPen(QPen(QColor(255, 196, 87), 3))
            painter.drawArc(QRectF(4, 4, 14, 14), ((self.frame * 25) % 360) * 16, 250 * 16)
            self.setToolTip("Whisper: generating local speech")
        elif self.state == "speaking":
            pulse = (math.sin(self.frame * 0.26) + 1) / 2
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QBrush(QColor(104, 218, 173)))
            painter.drawEllipse(QPointF(center, center), 5.5 + pulse * 2.8, 5.5 + pulse * 2.8)
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.setPen(QPen(QColor(104, 218, 173, 120), 2))
            painter.drawArc(QRectF(3, 5, 18, 14), -45 * 16, 90 * 16)
            self.setToolTip("Whisper: speaking selected text")
        elif self.state == "tts_finished":
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QBrush(QColor(117, 224, 167)))
            painter.drawEllipse(QRectF(4, 4, 14, 14))
            painter.setPen(QPen(QColor(18, 21, 25), 2, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
            painter.drawLine(QPointF(8, 11), QPointF(11, 14))
            painter.drawLine(QPointF(11, 14), QPointF(17, 7))
            self.setToolTip("Whisper: local speech finished")
        else:
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QBrush(QColor(48, 209, 88)))
            painter.drawEllipse(QRectF(4, 4, 14, 14))
            self.setToolTip("Whisper: done")

        painter.end()
        self.setIcon(QIcon(pixmap))


def main():
    configure_file_logging()
    logger.info("Application boot: argv=%s log_file=%s", sys.argv, LOG_FILE)
    lock = SingleInstanceLock(LOCK_FILE)
    if not lock.acquire():
        logger.warning("Application boot stopped: another instance is running lock_file=%s", LOCK_FILE)
        print("Whisper Dictation is already running.")
        return 0

    input_device_selector.refresh_baseline()

    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    ns_app = NSApplication.sharedApplication()
    ns_app.setActivationPolicy_(1)
    app.whisper_controller = StatusBarApp(app)
    print("Whisper Dictation is running.")
    logger.info("Application event loop starting")
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
