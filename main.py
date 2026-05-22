import array
import ctypes
import json
import logging
import math
import os
import random
import subprocess
import sys
import tempfile
import time
import wave
from dataclasses import dataclass
from datetime import datetime

import objc
import pyaudio
import pyperclip
from AppKit import (
    NSApplication,
    NSEvent,
    NSEventModifierFlagShift,
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
from openai import OpenAI
from PyQt6.QtCore import QObject, QPointF, QRectF, Qt, QThread, QTimer, pyqtSignal
from PyQt6.QtGui import QBrush, QColor, QCursor, QFont, QIcon, QPainter, QPen, QPixmap
from PyQt6.QtWidgets import QApplication, QLabel, QMenu, QPlainTextEdit, QSystemTrayIcon, QVBoxLayout, QWidget


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


@dataclass(frozen=True)
class HotkeyConfig:
    hold_threshold: float = 1.0


AUDIO = AudioConfig()
HOTKEY = HotkeyConfig()
COST_FILE = os.path.expanduser("~/.openai_voice_costs.json")
LOCK_FILE = os.path.expanduser("~/.whisper_dictation.lock")
KEY_CODE_V = 9
CG_EVENT_FLAG_MASK_COMMAND = 1 << 20
NSEVENT_MASK_FLAGS_CHANGED = 1 << 12

logger = logging.getLogger("WhisperDictation")
logger.setLevel(logging.INFO)
client = OpenAI(api_key=API_KEY)


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
        self.setWindowTitle("Whisper Logs & Costs")
        self.resize(620, 380)

        layout = QVBoxLayout()
        self.cost_label = QLabel()
        self.cost_label.setStyleSheet("font-size: 16px; font-weight: 700; color: #4CAF50; padding: 10px;")
        layout.addWidget(self.cost_label)

        self.text_edit = QPlainTextEdit()
        self.text_edit.setReadOnly(True)
        self.text_edit.setFont(QFont("Menlo", 12))
        self.text_edit.setStyleSheet("background-color: #101317; color: #7CFFB2;")
        layout.addWidget(self.text_edit)
        self.setLayout(layout)
        self.update_cost_display()

    def append_log(self, text):
        self.text_edit.appendPlainText(text)
        self.text_edit.verticalScrollBar().setValue(self.text_edit.verticalScrollBar().maximum())

    def update_cost_display(self):
        self.cost_label.setText(f"Total Whisper spend ({cost_manager.current_month}): ${cost_manager.total_cost:.5f}")


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
        try:
            logger.info("Start recording")
            stream = audio.open(
                format=AUDIO.format,
                channels=AUDIO.channels,
                rate=AUDIO.rate,
                input=True,
                frames_per_buffer=AUDIO.chunk,
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
            self._transcribe(frames, duration_sec, sample_width)
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

    def _transcribe(self, frames, duration_sec, sample_width):
        temp_path = ""
        try:
            cost, _total = cost_manager.add_recording(duration_sec)
            self.cost_update_signal.emit()
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as temp_file:
                temp_path = temp_file.name
            with wave.open(temp_path, "wb") as wav_file:
                wav_file.setnchannels(AUDIO.channels)
                wav_file.setsampwidth(sample_width)
                wav_file.setframerate(AUDIO.rate)
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
                os.remove(temp_path)


class PasteController:
    edit_menu_names = ("Edit", "Правка", "Редактирование", "Редагування")
    paste_item_names = ("Paste", "Вставить", "Вставити")

    def paste(self, text):
        self._copy_to_clipboard(text)
        logger.info("Text copied to clipboard")
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
        app_services = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
        core_foundation = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

        app_services.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
        app_services.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
        app_services.CGEventSetFlags.argtypes = [ctypes.c_void_p, ctypes.c_uint64]
        app_services.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        core_foundation.CFRelease.argtypes = [ctypes.c_void_p]

        key_down = app_services.CGEventCreateKeyboardEvent(None, KEY_CODE_V, True)
        key_up = app_services.CGEventCreateKeyboardEvent(None, KEY_CODE_V, False)
        if not key_down or not key_up:
            raise RuntimeError("Could not create Cmd+V keyboard event")
        try:
            app_services.CGEventSetFlags(key_down, CG_EVENT_FLAG_MASK_COMMAND)
            app_services.CGEventSetFlags(key_up, CG_EVENT_FLAG_MASK_COMMAND)
            app_services.CGEventPost(0, key_down)
            time.sleep(0.03)
            app_services.CGEventPost(0, key_up)
        finally:
            core_foundation.CFRelease(key_down)
            core_foundation.CFRelease(key_up)


class NativeStatusItem:
    def __init__(self):
        self.item = None
        self.button = None
        try:
            self.item = NSStatusBar.systemStatusBar().statusItemWithLength_(-1)
            self.button = self.item.button()
            self.set_state("idle")
            logger.info("Native macOS status item installed")
        except Exception as exc:
            logger.warning("Could not install native macOS status item: %s", exc)

    def set_state(self, state):
        if self.button is None:
            return
        titles = {
            "idle": "W",
            "recording": "REC",
            "processing": "...",
            "done": "OK",
        }
        tooltips = {
            "idle": "Whisper Dictation: idle",
            "recording": "Whisper Dictation: recording",
            "processing": "Whisper Dictation: transcribing",
            "done": "Whisper Dictation: done",
        }
        self.button.setTitle_(titles.get(state, "W"))
        self.button.setToolTip_(tooltips.get(state, "Whisper Dictation"))


class StatusBarApp(QSystemTrayIcon):
    def __init__(self, app):
        super().__init__()
        self.app = app
        self.state = "idle"
        self.frame = 0
        self.last_shift = False
        self.shift_press_time = 0.0
        self.waiting_for_hold = False
        self.event_monitors = []
        self.paste_controller = PasteController()

        self.log_window = LogWindow()
        self.voice_meter = SimpleVoiceMeterOverlay()
        self._setup_logging()
        self.native_status = NativeStatusItem()
        self._setup_menu()
        self._setup_timers()
        self._create_worker()

        self.update_icon()
        self.setVisible(True)
        if not QSystemTrayIcon.isSystemTrayAvailable():
            logger.warning("System tray is unavailable; showing diagnostics window")
            self.show_logs()
            self.log_window.setWindowTitle("Whisper Dictation (no tray)")
            self.log_window.append_log("System tray unavailable. App is running in fallback visibility mode.")
        logger.info("Whisper Dictation started. Tap then hold Shift to record.")

    def _setup_logging(self):
        gui_handler = QtLogHandler()
        gui_handler.setFormatter(logging.Formatter("%(asctime)s - %(message)s", datefmt="%H:%M:%S"))
        gui_handler.log_signal.connect(self.log_window.append_log)
        logger.addHandler(gui_handler)

        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(logging.Formatter("%(asctime)s - %(levelname)s - %(message)s"))
        logger.addHandler(console_handler)
        logger.info("SystemTray available=%s", QSystemTrayIcon.isSystemTrayAvailable())

    def _setup_menu(self):
        menu = QMenu()
        logs_action = menu.addAction("View Logs & Cost")
        logs_action.triggered.connect(self.show_logs)
        menu.addSeparator()
        quit_action = menu.addAction("Quit")
        quit_action.triggered.connect(self.app.quit)
        self.setContextMenu(menu)

    def _setup_timers(self):
        self.icon_timer = QTimer()
        self.icon_timer.timeout.connect(self.update_icon)
        self.icon_timer.start(33)

        self._setup_shift_monitors()

        self.key_timer = QTimer()
        self.key_timer.timeout.connect(self.check_keys)
        self.key_timer.start(120)

    def _setup_shift_monitors(self):
        def handle_flags_changed(event):
            try:
                self._handle_shift_state(bool(event.modifierFlags() & NSEventModifierFlagShift))
            except Exception as exc:
                logger.warning("Shift event monitor failed: %s", exc)
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

            logger.info("Shift event monitors installed: %s", len(self.event_monitors))
        except Exception as exc:
            logger.warning("Could not install Shift event monitors; timer fallback remains active: %s", exc)

    def _create_worker(self):
        self.worker = AudioWorker()
        self.worker.finished_signal.connect(self.on_transcription_done)
        self.worker.cost_update_signal.connect(self.log_window.update_cost_display)
        self.worker.limit_reached_signal.connect(self.on_auto_stop)
        self.worker.level_signal.connect(self.voice_meter.set_level)

    def _replace_worker(self):
        if self.worker and self.worker.isRunning():
            self.worker.cancel()
        self._create_worker()

    def set_state(self, state):
        self.state = state
        self.native_status.set_state(state)
        self.voice_meter.set_mode(state)
        self.update_icon()

    def show_logs(self):
        self.log_window.update_cost_display()
        self.log_window.show()
        self.log_window.raise_()
        self.log_window.activateWindow()

    def on_auto_stop(self):
        if self.state == "recording":
            self.set_state("processing")
            self.waiting_for_hold = False

    def check_keys(self):
        try:
            is_shift = bool(NSEvent.modifierFlags() & NSEventModifierFlagShift)
        except Exception:
            is_shift = False
        self._handle_shift_state(is_shift)

    def _handle_shift_state(self, is_shift):
        now = time.time()

        if is_shift and not self.last_shift:
            if self.state == "recording":
                self.set_state("processing")
                self.worker.stop_recording()
                self.waiting_for_hold = False
            elif self.state == "processing":
                logger.warning("Current transcription cancelled by user")
                self._replace_worker()
                self.set_state("idle")
                self.waiting_for_hold = False
            else:
                self.shift_press_time = now
                self.waiting_for_hold = True

        elif not is_shift and self.last_shift:
            self.waiting_for_hold = False

        elif is_shift and self.last_shift and self.waiting_for_hold and self.state in ("idle", "done"):
            if now - self.shift_press_time >= HOTKEY.hold_threshold:
                logger.info("Hold detected; starting dictation")
                self.set_state("recording")
                self.worker.start_recording()
                self.waiting_for_hold = False

        self.last_shift = is_shift

    def on_transcription_done(self, text):
        if text is None:
            self.set_state("idle")
            self._replace_worker()
            return
        try:
            self.paste_controller.paste(text)
            self.set_state("done")
            QTimer.singleShot(1500, lambda: self.set_state("idle"))
        except Exception as exc:
            logger.exception("Paste error: %s", exc)
            self.set_state("idle")
        finally:
            self._replace_worker()

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
        else:
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QBrush(QColor(48, 209, 88)))
            painter.drawEllipse(QRectF(4, 4, 14, 14))
            self.setToolTip("Whisper: done")

        painter.end()
        self.setIcon(QIcon(pixmap))


def main():
    lock = SingleInstanceLock(LOCK_FILE)
    if not lock.acquire():
        print("Whisper Dictation is already running.")
        return 0

    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    ns_app = NSApplication.sharedApplication()
    ns_app.setActivationPolicy_(1)
    StatusBarApp(app)
    print("Whisper Dictation is running.")
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
