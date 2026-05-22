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
    NSApplicationActivateIgnoringOtherApps,
    NSEvent,
    NSEventModifierFlagShift,
    NSPasteboard,
    NSPasteboardTypeString,
    NSScreenSaverWindowLevel,
    NSWorkspace,
    NSWindowCollectionBehaviorCanJoinAllSpaces,
    NSWindowCollectionBehaviorFullScreenAuxiliary,
    NSWindowCollectionBehaviorIgnoresCycle,
    NSWindowCollectionBehaviorStationary,
)
from dotenv import load_dotenv
from openai import OpenAI
from PyQt6.QtCore import QObject, QPointF, QRectF, Qt, QThread, QTimer, pyqtSignal
from PyQt6.QtGui import QBrush, QColor, QCursor, QFont, QIcon, QPainter, QPen, QPixmap, QRadialGradient
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
    tap_gap_threshold: float = 0.5
    hold_threshold: float = 1.0


AUDIO = AudioConfig()
HOTKEY = HotkeyConfig()
WHISPER_LANGUAGE = os.getenv("WHISPER_LANGUAGE", "ru").strip() or None
COST_FILE = os.path.expanduser("~/.openai_voice_costs.json")
LOCK_FILE = os.path.expanduser("~/.whisper_dictation.lock")
EFFECT_PREF_FILE = os.path.expanduser("~/.whisper_dictation_effect.json")
KEY_CODE_V = 9
CG_EVENT_FLAG_MASK_COMMAND = 1 << 20

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
    max_edge_particles = 180
    max_meteors = 34
    max_explosions = 180

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
        self.edge_spawn_budget = 0.0
        self.meteor_spawn_budget = 0.0
        self.fading_out = False
        self.particles = []
        self.edge_particles = []
        self.border_comets = []
        self.meteors = []
        self.explosions = []

        self.timer = QTimer(self)
        self.timer.timeout.connect(self._animate)
        self.timer.start(self.tick_ms)
        self.hide()

    def show_meter(self):
        self.fading_out = False
        self._cover_current_screen()
        self._seed_border_comets()
        self._seed_meteor_scene()
        self.show()
        self._apply_macos_window_level()
        self.update()

    def hide_meter(self):
        self.level = 0.0
        self.spawn_budget = 0.0
        self.edge_spawn_budget = 0.0
        self.meteor_spawn_budget = 0.0
        self.fading_out = True
        if not self._has_active_pixels():
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
        if not self.isVisible() and not self._has_active_pixels():
            return

        self.frame += 1
        if self.fading_out:
            target_level = 0.0
            smoothing = 0.18
        elif self.mode == "processing":
            target_level = 0.12 + math.sin(self.frame * 0.055) * 0.025
            smoothing = 0.075
        else:
            target_level = max(self.level, 0.16)
            smoothing = 0.88 if target_level > self.display_level else 0.28

        self.display_level = self.display_level * (1.0 - smoothing) + target_level * smoothing
        self._update_particles()
        self._update_edge_particles()
        self._update_border_comets()
        self._update_meteors()
        self._update_explosions()
        if self.isVisible():
            self.update()

    def _has_active_pixels(self):
        return bool(self.particles or self.edge_particles or self.border_comets or self.meteors or self.explosions)

    def _ground_y(self):
        return self.height() - max(64.0, min(150.0, self.height() * 0.13))

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
        if self.fading_out and not self._has_active_pixels():
            self.fading_out = False
            self.hide()

    def _update_meteors(self):
        level = self.display_level
        if self.fading_out:
            self.meteor_spawn_budget = 0.0
        elif self.mode == "processing":
            self.meteor_spawn_budget += 0.08 + level * 0.8
        else:
            self.meteor_spawn_budget += 0.16 + level * 2.8 + level * level * 5.0

        spawn_cap = 2 if self.mode == "processing" else 5
        spawn_count = min(int(self.meteor_spawn_budget), spawn_cap, self.max_meteors - len(self.meteors))
        self.meteor_spawn_budget -= spawn_count
        for _ in range(max(0, spawn_count)):
            self._spawn_meteor(level)

        ground_y = self._ground_y()
        next_meteors = []
        for meteor in self.meteors:
            meteor["x"] += meteor["vx"]
            meteor["y"] += meteor["vy"]
            meteor["vy"] += meteor["gravity"]
            meteor["phase"] += 0.08
            meteor["trail"].append((meteor["x"], meteor["y"]))
            if len(meteor["trail"]) > meteor["trail_limit"]:
                meteor["trail"].pop(0)

            if meteor["y"] >= ground_y - meteor["impact_offset"]:
                self._spawn_explosion(meteor["x"], ground_y - meteor["impact_offset"], meteor["color"], meteor["power"])
                continue

            if -90 < meteor["x"] < self.width() + 90 and meteor["y"] < self.height() + 80:
                next_meteors.append(meteor)

        self.meteors = next_meteors[-self.max_meteors :]

    def _spawn_meteor(self, level):
        w = max(1, self.width())
        h = max(1, self.height())
        entry = random.choice(("top", "top", "left", "right"))
        speed = random.uniform(3.2, 6.2) + level * random.uniform(5.0, 10.5)

        if entry == "top":
            x = random.uniform(-w * 0.1, w * 1.1)
            y = -random.uniform(22.0, 110.0)
            vx = random.uniform(-1.9, 1.9) + random.choice((-1, 1)) * level * random.uniform(0.8, 2.2)
            vy = speed
        elif entry == "left":
            x = -random.uniform(22.0, 130.0)
            y = random.uniform(-20.0, h * 0.38)
            vx = speed * random.uniform(0.45, 0.85)
            vy = speed * random.uniform(0.62, 1.05)
        else:
            x = w + random.uniform(22.0, 130.0)
            y = random.uniform(-20.0, h * 0.38)
            vx = -speed * random.uniform(0.45, 0.85)
            vy = speed * random.uniform(0.62, 1.05)

        color = random.choice(((255, 231, 134), (255, 150, 80), (255, 98, 152), (118, 245, 255), (210, 180, 255)))
        self.meteors.append(
            {
                "x": x,
                "y": y,
                "vx": vx,
                "vy": vy,
                "gravity": random.uniform(0.025, 0.065) + level * 0.025,
                "size": random.choice((4.0, 5.0, 6.0, 7.0)) + level * 3.0,
                "color": color,
                "alpha": random.randint(220, 255),
                "trail": [],
                "trail_limit": random.randint(9, 16),
                "phase": random.uniform(0.0, math.tau),
                "impact_offset": random.uniform(0.0, 20.0),
                "power": random.uniform(0.7, 1.2) + level * 1.6,
            }
        )

    def _spawn_explosion(self, x, y, color, power):
        burst_count = min(34, int(12 + power * 10))
        for _ in range(burst_count):
            angle = random.uniform(math.pi * 1.05, math.pi * 1.95)
            speed = random.uniform(1.1, 4.6) * power
            r, g, b = random.choice((color, (255, 237, 170), (255, 126, 64), (255, 84, 142)))
            life = random.randint(24, 52) + int(power * 8)
            self.explosions.append(
                {
                    "x": x + random.uniform(-5.0, 5.0),
                    "y": y + random.uniform(-4.0, 3.0),
                    "vx": math.cos(angle) * speed,
                    "vy": math.sin(angle) * speed,
                    "life": life,
                    "max_life": life,
                    "size": random.choice((2.0, 3.0, 4.0, 5.0)) + power,
                    "color": (r, g, b),
                    "alpha": random.randint(190, 255),
                }
            )
        self.explosions = self.explosions[-self.max_explosions :]

    def _update_explosions(self):
        next_particles = []
        for particle in self.explosions:
            particle["life"] -= 1
            particle["x"] += particle["vx"]
            particle["y"] += particle["vy"]
            particle["vy"] += 0.12
            particle["vx"] *= 0.955
            particle["vy"] *= 0.975
            particle["size"] *= 0.985
            if particle["life"] > 0 and particle["size"] > 0.35:
                next_particles.append(particle)
        self.explosions = next_particles[-self.max_explosions :]

    def _seed_border_comets(self):
        if self.border_comets:
            return
        for index in range(8):
            self.border_comets.append(self._new_border_comet(index / 8.0))

    def _seed_meteor_scene(self):
        if self.meteors or self.explosions:
            return
        for _ in range(10):
            self._spawn_meteor(0.28)
            meteor = self.meteors[-1]
            meteor["y"] += random.uniform(20.0, self.height() * 0.38)
        ground_y = self._ground_y()
        for x in (self.width() * 0.22, self.width() * 0.55, self.width() * 0.82):
            self._spawn_explosion(x, ground_y - random.uniform(4.0, 16.0), (255, 150, 80), 0.85)

    def _new_border_comet(self, progress=None):
        return {
            "progress": random.random() if progress is None else progress,
            "speed": random.uniform(0.0012, 0.0028),
            "size": random.choice((2.0, 2.5, 3.0, 3.5)),
            "color": random.choice(((88, 248, 255), (145, 255, 214), (255, 238, 148), (255, 142, 222), (226, 240, 255))),
            "alpha": random.randint(140, 230),
            "trail": random.uniform(26.0, 56.0),
            "phase": random.uniform(0.0, math.tau),
            "clockwise": random.choice((True, False)),
        }

    def _update_border_comets(self):
        if self.mode not in ("recording", "processing") and not self.fading_out:
            return

        if not self.border_comets and not self.fading_out:
            self._seed_border_comets()

        next_comets = []
        for comet in self.border_comets:
            speed_boost = 1.0 + self.display_level * 1.6
            comet["progress"] = (comet["progress"] + comet["speed"] * speed_boost) % 1.0
            comet["phase"] += 0.045
            if self.fading_out:
                comet["alpha"] -= 5
            if comet["alpha"] > 0:
                next_comets.append(comet)

        self.border_comets = next_comets

    def _update_edge_particles(self):
        level = self.display_level
        if self.fading_out or level < 0.006:
            self.edge_spawn_budget = 0.0
        elif self.mode == "processing":
            self.edge_spawn_budget += 0.28 + level * 2.8
        else:
            self.edge_spawn_budget += 0.55 + level * 8.5 + level * level * 10.0

        spawn_cap = 6 if self.mode == "processing" else 14
        spawn_count = min(
            int(self.edge_spawn_budget),
            spawn_cap,
            self.max_edge_particles - len(self.edge_particles),
        )
        self.edge_spawn_budget -= spawn_count
        for _ in range(max(0, spawn_count)):
            self._spawn_edge_particle(level)

        w = max(1, self.width())
        h = max(1, self.height())
        next_particles = []
        for particle in self.edge_particles:
            particle["life"] -= 3 if self.fading_out else 1
            particle["phase"] += particle["phase_speed"]
            particle["x"] += particle["vx"] + math.sin(particle["phase"]) * particle["wave"]
            particle["y"] += particle["vy"] + math.cos(particle["phase"] * 0.83) * particle["wave"]
            particle["vx"] *= 0.992
            particle["vy"] *= 0.992

            if particle["life"] > 0 and -90 < particle["x"] < w + 90 and -90 < particle["y"] < h + 90:
                next_particles.append(particle)

        self.edge_particles = next_particles[-self.max_edge_particles :]

    def _spawn_edge_particle(self, level):
        w = max(1, self.width())
        h = max(1, self.height())
        edge = random.choice(("top", "right", "bottom", "left"))
        margin = random.uniform(2.0, 28.0)
        speed = random.uniform(0.95, 2.45) + level * random.uniform(2.2, 5.2)

        if edge == "top":
            x = random.uniform(0, w)
            y = margin
            vx = random.choice((-1, 1)) * speed
            vy = random.uniform(0.02, 0.22) + level * 0.20
        elif edge == "bottom":
            x = random.uniform(0, w)
            y = h - margin
            vx = random.choice((-1, 1)) * speed
            vy = -random.uniform(0.02, 0.22) - level * 0.20
        elif edge == "left":
            x = margin
            y = random.uniform(0, h)
            vx = random.uniform(0.02, 0.22) + level * 0.20
            vy = random.choice((-1, 1)) * speed
        else:
            x = w - margin
            y = random.uniform(0, h)
            vx = -random.uniform(0.02, 0.22) - level * 0.20
            vy = random.choice((-1, 1)) * speed

        color = random.choice(
            (
                (88, 248, 255),
                (145, 255, 214),
                (255, 238, 148),
                (255, 142, 222),
                (226, 240, 255),
            )
        )
        life = random.randint(62, 118) + int(level * 42)
        self.edge_particles.append(
            {
                "x": x,
                "y": y,
                "vx": vx,
                "vy": vy,
                "life": life,
                "max_life": life,
                "color": color,
                "alpha": random.randint(180, 255),
                "size": random.choice((1.5, 2.0, 2.5, 3.0, 3.5)),
                "trail": random.uniform(18.0, 42.0) + level * 34.0,
                "phase": random.uniform(0.0, math.tau),
                "phase_speed": random.uniform(0.035, 0.09),
                "wave": random.uniform(0.02, 0.18) + level * 0.18,
                "spark": random.randint(0, 5),
            }
        )

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

        self._paint_mars_ground(painter)
        self._paint_border_comets(painter)
        self._paint_edge_particles(painter)
        self._paint_meteors(painter)
        self._paint_explosions(painter)

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

    def _paint_mars_ground(self, painter):
        w = self.width()
        h = self.height()
        ground_y = self._ground_y()
        painter.setPen(Qt.PenStyle.NoPen)

        horizon = QColor(164, 68, 54, 122 if self.fading_out else 172)
        painter.setBrush(QBrush(horizon))
        painter.drawRect(QRectF(0, ground_y, w, h - ground_y))

        ridge_color = QColor(216, 92, 62, 168 if self.fading_out else 220)
        shadow_color = QColor(93, 40, 42, 128 if self.fading_out else 180)
        step = 18
        for index, x in enumerate(range(-step, int(w) + step, step)):
            wave = math.sin(index * 0.9 + self.frame * 0.025) * 8.0
            y = ground_y + 8.0 + wave
            painter.setBrush(QBrush(ridge_color))
            painter.drawRect(QRectF(x, y, step + 2, h - y))
            if index % 3 == 0:
                painter.setBrush(QBrush(shadow_color))
                painter.drawRect(QRectF(x + 5, y + 14, step * 1.7, 5))
            if index % 5 == 0:
                painter.setBrush(QBrush(QColor(255, 160, 95, 95)))
                painter.drawRect(QRectF(x + 8, y + 5, 6, 2))

    def _paint_meteors(self, painter):
        painter.setPen(Qt.PenStyle.NoPen)
        for meteor in self.meteors:
            r, g, b = meteor["color"]
            history = meteor["trail"]
            for index, (x, y) in enumerate(history):
                ratio = (index + 1) / max(1, len(history))
                alpha = int(meteor["alpha"] * 0.50 * ratio)
                size = max(1.0, meteor["size"] * ratio * 0.72)
                painter.setBrush(QBrush(QColor(r, g, b, alpha)))
                painter.drawRect(QRectF(round(x - size * 0.5), round(y - size * 0.5), size, size))

            x = meteor["x"]
            y = meteor["y"]
            size = meteor["size"] + math.sin(meteor["phase"]) * 0.7
            painter.setBrush(QBrush(QColor(r, g, b, meteor["alpha"])))
            painter.drawRect(QRectF(round(x - size * 0.5), round(y - size * 0.5), size, size))
            painter.setBrush(QBrush(QColor(255, 250, 210, min(255, meteor["alpha"] + 20))))
            painter.drawRect(QRectF(round(x - size * 0.22), round(y - size * 0.22), max(2.0, size * 0.45), max(2.0, size * 0.45)))

    def _paint_explosions(self, painter):
        painter.setPen(Qt.PenStyle.NoPen)
        for particle in self.explosions:
            life_ratio = max(0.0, min(1.0, particle["life"] / particle["max_life"]))
            alpha = int(particle["alpha"] * life_ratio)
            if alpha <= 0:
                continue
            r, g, b = particle["color"]
            size = particle["size"] * (0.9 + (1.0 - life_ratio) * 1.4)
            painter.setBrush(QBrush(QColor(r, g, b, alpha)))
            painter.drawRect(QRectF(round(particle["x"] - size * 0.5), round(particle["y"] - size * 0.5), size, size))

            if life_ratio > 0.62:
                flash_size = size * 2.4
                painter.setBrush(QBrush(QColor(255, 244, 188, int(alpha * 0.36))))
                painter.drawRect(QRectF(round(particle["x"] - flash_size * 0.5), round(particle["y"] - flash_size * 0.5), flash_size, flash_size))

    def _border_position(self, progress):
        w = max(1, self.width())
        h = max(1, self.height())
        perimeter = 2 * (w + h)
        distance = (progress % 1.0) * perimeter

        if distance < w:
            return distance, 10.0, 1.0, 0.0
        distance -= w
        if distance < h:
            return w - 10.0, distance, 0.0, 1.0
        distance -= h
        if distance < w:
            return w - distance, h - 10.0, -1.0, 0.0
        distance -= w
        return 10.0, h - distance, 0.0, -1.0

    def _paint_border_comets(self, painter):
        painter.setPen(Qt.PenStyle.NoPen)
        for comet in self.border_comets:
            progress = comet["progress"] if comet["clockwise"] else 1.0 - comet["progress"]
            x, y, dx, dy = self._border_position(progress)
            x += math.sin(comet["phase"]) * 4.0
            y += math.cos(comet["phase"] * 0.9) * 4.0
            alpha = max(0, min(255, int(comet["alpha"] * (0.72 + self.display_level * 0.34))))
            if alpha <= 0:
                continue

            r, g, b = comet["color"]
            size = comet["size"] + self.display_level * 2.0
            trail = comet["trail"] * (0.9 + self.display_level)
            for step in range(1, 9):
                ratio = step / 9
                tail_alpha = int(alpha * 0.52 * (1.0 - ratio))
                if tail_alpha <= 2:
                    continue
                tail_x = x - dx * trail * ratio
                tail_y = y - dy * trail * ratio
                painter.setBrush(QBrush(QColor(r, g, b, tail_alpha)))
                painter.drawRect(QRectF(round(tail_x), round(tail_y), max(1.0, size - ratio * 1.2), max(1.0, size - ratio * 1.2)))

            painter.setBrush(QBrush(QColor(r, g, b, alpha)))
            painter.drawRect(QRectF(round(x - size * 0.5), round(y - size * 0.5), size, size))
            painter.setBrush(QBrush(QColor(255, 255, 245, int(alpha * 0.62))))
            painter.drawRect(QRectF(round(x - 1), round(y - size - 1), 2.0, max(1.0, size)))
            painter.drawRect(QRectF(round(x - size - 1), round(y - 1), max(1.0, size), 2.0))

    def _paint_edge_particles(self, painter):
        painter.setPen(Qt.PenStyle.NoPen)
        for particle in self.edge_particles:
            life_ratio = max(0.0, min(1.0, particle["life"] / particle["max_life"]))
            fade = math.sin(life_ratio * math.pi) if life_ratio < 0.98 else 1.0
            alpha = int(particle["alpha"] * fade)
            if alpha <= 0:
                continue

            r, g, b = particle["color"]
            x = particle["x"]
            y = particle["y"]
            size = particle["size"]
            trail_len = particle["trail"] * (0.8 + self.display_level * 0.75)
            tail_steps = 5
            for step in range(1, tail_steps + 1):
                ratio = step / tail_steps
                tail_x = x - particle["vx"] * trail_len * ratio
                tail_y = y - particle["vy"] * trail_len * ratio
                tail_alpha = int(alpha * 0.46 * (1.0 - ratio))
                if tail_alpha <= 2:
                    continue
                painter.setBrush(QBrush(QColor(r, g, b, tail_alpha)))
                painter.drawRect(QRectF(round(tail_x), round(tail_y), max(1.0, size - 0.4), max(1.0, size - 0.4)))

            painter.setBrush(QBrush(QColor(r, g, b, alpha)))
            painter.drawRect(QRectF(round(x - size * 0.5), round(y - size * 0.5), size, size))

            if particle["spark"] == 0 and alpha > 90:
                painter.setBrush(QBrush(QColor(255, 255, 245, int(alpha * 0.58))))
                painter.drawRect(QRectF(round(x - 1), round(y - size - 1), 2.0, max(1.0, size)))
                painter.drawRect(QRectF(round(x - size - 1), round(y - 1), max(1.0, size), 2.0))


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


class CosmicSpecterOverlay(QWidget):
    tick_ms = 33
    max_particles = 360
    max_specters = 9

    def __init__(self):
        flags = Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool
        super().__init__(None, flags)
        self.setWindowFlag(Qt.WindowType.WindowDoesNotAcceptFocus, True)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

        self.mode = "idle"
        self.level = 0.0
        self.display_level = 0.0
        self.frame = 0
        self.spawn_budget = 0.0
        self.specter_budget = 0.0
        self.fading_out = False
        self.particles = []
        self.specters = []

        self.timer = QTimer(self)
        self.timer.timeout.connect(self._animate)
        self.timer.start(self.tick_ms)
        self.hide()

    def set_mode(self, mode):
        self.mode = mode
        if mode == "recording":
            self.fading_out = False
            self._cover_current_screen()
            self._seed_side_specters()
            self.show()
            self._apply_macos_window_level()
            self.raise_()
            self.update()
        elif mode == "processing":
            self.level = 0.0
            self.spawn_budget = 0.0
            self.specter_budget = 0.0
            self._start_specter_exit()
            self.fading_out = True
            if self.particles or self.specters:
                self.show()
                self._apply_macos_window_level()
                self.raise_()
                self.update()
            else:
                self.fading_out = False
                self.hide()
        else:
            self.level = 0.0
            self.spawn_budget = 0.0
            self.specter_budget = 0.0
            self._start_specter_exit()
            self.fading_out = True
            if not self.particles and not self.specters:
                self.fading_out = False
                self.hide()

    def prepare_for_paste(self):
        if self.isVisible() or self.particles or self.specters:
            self.set_mode("processing")
            QApplication.processEvents()

    def set_level(self, level):
        if self.mode != "recording":
            return
        self.level = max(0.0, min(1.0, float(level)))

    def _cover_current_screen(self):
        screen = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
        if screen:
            self.setGeometry(screen.geometry())

    def _animate(self):
        if not self.isVisible() and not self.particles and not self.specters:
            return

        self.frame += 1
        target = 0.0 if self.fading_out else self.level
        if self.mode == "processing" and not self.fading_out:
            target = 0.16 + math.sin(self.frame * 0.055) * 0.035
        smoothing = 0.55 if target > self.display_level else 0.18
        self.display_level = self.display_level * (1.0 - smoothing) + target * smoothing
        self._update_particles()
        self._update_specters()
        if self.isVisible():
            self.update()

    def _update_particles(self):
        level = self.display_level
        if self.fading_out or level < 0.004:
            self.spawn_budget = 0.0
        else:
            self.spawn_budget += 0.72 + level * 18.0

        spawn_count = min(int(self.spawn_budget), 16, self.max_particles - len(self.particles))
        self.spawn_budget -= spawn_count
        for _ in range(max(0, spawn_count)):
            self._spawn_particle(level)

        next_particles = []
        edge_band = max(110, min(max(1, self.width()), max(1, self.height())) * 0.16)
        for particle in self.particles:
            life_decay = 9 if self.fading_out else 1
            if not self.fading_out and level < 0.018:
                life_decay = 4

            particle["life"] -= life_decay
            particle["x"] += particle["vx"]
            particle["y"] += particle["vy"]
            particle["vx"] += math.sin((self.frame + particle["phase"]) * 0.045) * 0.006
            particle["vy"] += math.cos((self.frame + particle["phase"]) * 0.04) * 0.006
            particle["vx"] *= 0.998
            particle["vy"] *= 0.998
            particle["size"] *= 0.998
            near_edge = (
                particle["y"] <= edge_band
                if particle["edge"] == "top"
                else particle["y"] >= self.height() - edge_band
            )
            if particle["life"] > 0 and particle["size"] > 0.25 and near_edge:
                next_particles.append(particle)

        self.particles = next_particles[-self.max_particles :]

    def _update_specters(self):
        level = self.display_level
        if self.fading_out or level < 0.004:
            self.specter_budget = 0.0
        else:
            self.specter_budget += 0.018 + level * 0.045

        specter_count = int(self.specter_budget)
        self.specter_budget -= specter_count
        if len(self.specters) < self.max_specters:
            for _ in range(min(specter_count, 2)):
                self._spawn_specter(level)

        next_specters = []
        for specter in self.specters:
            if self.fading_out:
                specter["exit_age"] = specter.get("exit_age", 0) + 1
            else:
                if specter.get("enter_age", 0) < specter.get("enter_duration", 1):
                    specter["enter_age"] = specter.get("enter_age", 0) + 1
                specter["age"] += 1
            specter["bob"] += 0.06
            if self.fading_out:
                if specter.get("exit_age", 0) < specter.get("exit_duration", 58):
                    next_specters.append(specter)
            elif specter["age"] < specter["duration"]:
                next_specters.append(specter)

        self.specters = next_specters[-self.max_specters :]
        if self.fading_out and not self.particles and not self.specters:
            self.fading_out = False
            self.hide()

    def _start_specter_exit(self):
        for specter in self.specters:
            if specter.get("leaving"):
                continue
            progress = max(0.0, min(1.0, specter["age"] / specter["duration"]))
            specter["leaving"] = True
            specter["exit_age"] = 0
            specter["exit_duration"] = random.randint(92, 128)
            specter["exit_wave"] = max(0.72, math.sin(progress * math.pi))
            specter["exit_drift"] = random.uniform(-32, 32)

    def _spawn_particle(self, level):
        edge = random.choice(("top", "bottom"))
        w = max(1, self.width())
        h = max(1, self.height())
        margin = 54 + level * 48
        if edge == "top":
            source_x = random.uniform(0, w)
            source_y = random.uniform(0, margin)
            angle = random.uniform(math.pi * 0.24, math.pi * 0.76)
        else:
            source_x = random.uniform(0, w)
            source_y = h - random.uniform(0, margin)
            angle = random.uniform(math.pi * 1.24, math.pi * 1.76)

        speed = random.uniform(0.05 + level * 0.18, 0.26 + level * 0.72)
        palette = random.choice(((98, 245, 255), (172, 112, 255), (255, 88, 202), (130, 255, 184), (255, 238, 154)))
        alpha = int(random.uniform(90, 180) + level * 70)
        self.particles.append(
            {
                "x": source_x,
                "y": source_y,
                "vx": math.cos(angle) * speed,
                "vy": math.sin(angle) * speed + random.uniform(-0.08, 0.08),
                "size": random.uniform(0.42, 1.55 + level * 1.1),
                "life": random.randint(76, 160) + int(level * 48),
                "max_life": 210,
                "color": QColor(*palette, min(205, int(alpha * 0.78))),
                "edge": edge,
                "phase": random.uniform(0, 360),
                "sparkle": random.random() < 0.18,
                "kind": random.choice(("dust", "firefly")),
            }
        )

    def _seed_side_specters(self):
        self.specters = []
        h = max(1, self.height())
        anchors = (h * 0.18, h * 0.38, h * 0.62, h * 0.82)
        for index, anchor in enumerate(anchors):
            self._spawn_specter(
                self.display_level,
                side="left" if index % 2 == 0 else "right",
                anchor=anchor + random.uniform(-28, 28),
                immediate=True,
            )
        self._spawn_specter(self.display_level, side=random.choice(("left", "right")), anchor=random.uniform(h * 0.26, h * 0.74), immediate=True)
        self.specter_budget = 0.0

    def _free_specter_anchor(self, side):
        h = max(1, self.height())
        for _ in range(12):
            candidate = random.uniform(h * 0.12, h * 0.88)
            if all(specter["side"] != side or abs(specter["anchor"] - candidate) > 92 for specter in self.specters):
                return candidate
        return random.uniform(h * 0.12, h * 0.88)

    def _spawn_specter(self, level, side=None, anchor=None, immediate=False):
        side = side or random.choice(("left", "right"))
        h = max(1, self.height())
        size = random.uniform(46, 76 + level * 18)
        anchor = anchor if anchor is not None else self._free_specter_anchor(side)
        anchor = max(h * 0.1, min(h * 0.9, anchor))
        self.specters.append(
            {
                "side": side,
                "anchor": anchor,
                "age": int(random.uniform(46, 132)) if immediate else 0,
                "duration": random.randint(260, 430),
                "peek": size * random.uniform(1.08, 1.34),
                "drift": random.uniform(-24, 24),
                "size": size,
                "bob": random.uniform(0, math.tau),
                "enter_age": 0,
                "enter_duration": random.randint(30, 48) if immediate else random.randint(22, 36),
                "tint": random.choice((QColor(180, 251, 255, 168), QColor(214, 180, 255, 154), QColor(255, 178, 232, 146))),
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
            logger.warning("Cosmic overlay native window setup failed: %s", exc)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        self._paint_particles(painter)
        self._paint_specters(painter)
        painter.end()

    def _paint_particles(self, painter):
        painter.setPen(Qt.PenStyle.NoPen)
        for particle in self.particles:
            color = QColor(particle["color"])
            color.setAlpha(int(color.alpha() * max(0.0, min(1.0, particle["life"] / particle["max_life"]))))
            if color.alpha() <= 0:
                continue

            if particle["sparkle"] and color.alpha() > 48:
                glow = QRadialGradient(QPointF(particle["x"], particle["y"]), particle["size"] * 4.0)
                glow.setColorAt(0.0, QColor(color.red(), color.green(), color.blue(), int(color.alpha() * 0.62)))
                glow.setColorAt(0.42, QColor(color.red(), color.green(), color.blue(), int(color.alpha() * 0.18)))
                glow.setColorAt(1.0, QColor(color.red(), color.green(), color.blue(), 0))
                painter.setBrush(QBrush(glow))
                painter.drawEllipse(QPointF(particle["x"], particle["y"]), particle["size"] * 4.0, particle["size"] * 4.0)

            core = QColor(color)
            core.setAlpha(min(235, color.alpha() + 30))
            painter.setBrush(QBrush(core))
            radius = particle["size"] * (0.75 if particle["kind"] == "firefly" else 1.0)
            painter.drawEllipse(QPointF(particle["x"], particle["y"]), radius, radius)

    def _paint_specters(self, painter):
        painter.setPen(Qt.PenStyle.NoPen)
        w = self.width()
        for specter in self.specters:
            size = specter["size"]
            bob = math.sin(specter["bob"]) * size * 0.18
            progress = max(0.0, min(1.0, specter["age"] / specter["duration"]))
            if specter.get("leaving"):
                exit_progress = max(0.0, min(1.0, specter.get("exit_age", 0) / specter.get("exit_duration", 58)))
                exit_ease = exit_progress * exit_progress * (3.0 - 2.0 * exit_progress)
                peek_wave = specter.get("exit_wave", max(0.72, math.sin(progress * math.pi)))
                outward = exit_ease * (specter["peek"] + size * 2.8)
                fade = math.pow(1.0 - exit_progress, 0.55) * min(1.0, peek_wave * 1.9)
            else:
                exit_ease = 0.0
                outward = 0.0
                peek_wave = math.sin(progress * math.pi)
                fade = min(1.0, peek_wave * 1.9)

            if not specter.get("leaving"):
                enter_progress = max(0.0, min(1.0, specter.get("enter_age", 0) / specter.get("enter_duration", 1)))
                enter_ease = enter_progress * enter_progress * (3.0 - 2.0 * enter_progress)
                peek_wave *= enter_ease
                fade *= enter_ease

            offset = specter["peek"] * peek_wave
            if specter["side"] == "left":
                x = -size * 0.56 + offset - outward
            else:
                x = w + size * 0.56 - offset + outward
            y = specter["anchor"] + bob + specter["drift"] * progress + specter.get("exit_drift", 0.0) * exit_ease

            tint = QColor(specter["tint"])
            tint.setAlpha(int(tint.alpha() * fade))
            glow = QRadialGradient(QPointF(x, y), size * 1.4)
            glow.setColorAt(0.0, QColor(tint.red(), tint.green(), tint.blue(), int(tint.alpha() * 0.55)))
            glow.setColorAt(1.0, QColor(tint.red(), tint.green(), tint.blue(), 0))
            painter.setBrush(QBrush(glow))
            painter.drawEllipse(QPointF(x, y), size * 1.4, size * 1.4)

            pixel = max(3.0, size / 7.0)
            body = QColor(226, 250, 255, min(210, tint.alpha() + 62))
            eye = QColor(38, 21, 80, min(210, tint.alpha() + 70))
            painter.setBrush(QBrush(body))
            painter.drawRect(QRectF(x - pixel * 3, y - pixel * 4, pixel * 6, pixel * 6))
            painter.drawRect(QRectF(x - pixel * 2, y - pixel * 5, pixel * 4, pixel))
            painter.drawRect(QRectF(x - pixel * 2, y + pixel * 2, pixel, pixel))
            painter.drawRect(QRectF(x, y + pixel * 2, pixel, pixel))
            painter.drawRect(QRectF(x + pixel * 2, y + pixel * 2, pixel, pixel))
            painter.setBrush(QBrush(eye))
            painter.drawRect(QRectF(x - pixel * 1.45, y - pixel * 2, pixel * 0.9, pixel * 0.9))
            painter.drawRect(QRectF(x + pixel * 0.55, y - pixel * 2, pixel * 0.9, pixel * 0.9))


class PixelCometOverlay(QWidget):
    tick_ms = 33
    max_meteors = 56
    max_bursts = 240

    def __init__(self):
        flags = Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool
        super().__init__(None, flags)
        self.setWindowFlag(Qt.WindowType.WindowDoesNotAcceptFocus, True)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)

        self.mode = "idle"
        self.level = 0.0
        self.display_level = 0.0
        self.frame = 0
        self.spawn_budget = 0.0
        self.fading_out = False
        self.meteors = []
        self.bursts = []

        self.timer = QTimer(self)
        self.timer.timeout.connect(self._animate)
        self.timer.start(self.tick_ms)
        self.hide()

    def set_mode(self, mode):
        self.mode = mode
        if mode == "recording":
            self.fading_out = False
            self._cover_current_screen()
            self._seed_scene()
            self.show()
            self._apply_macos_window_level()
            self.raise_()
            self.update()
            logger.info("Pixel Comet overlay shown: %sx%s", self.width(), self.height())
        elif mode == "processing":
            self.level = 0.0
            self.spawn_budget = 0.0
            self.fading_out = True
            if self.meteors or self.bursts:
                self.show()
                self._apply_macos_window_level()
                self.raise_()
                self.update()
        else:
            self.level = 0.0
            self.spawn_budget = 0.0
            self.fading_out = True
            if not self.meteors and not self.bursts:
                self.fading_out = False
                self.hide()

    def prepare_for_paste(self):
        if self.isVisible() or self.meteors or self.bursts:
            self.set_mode("processing")
            QApplication.processEvents()

    def set_level(self, level):
        if self.mode != "recording":
            return
        self.level = max(0.0, min(1.0, float(level)))

    def _cover_current_screen(self):
        screen = QApplication.screenAt(QCursor.pos()) or QApplication.primaryScreen()
        if screen:
            self.setGeometry(screen.geometry())

    def _animate(self):
        if self.mode in ("recording", "processing"):
            if not self.isVisible():
                self.show()
                self._apply_macos_window_level()
                self.raise_()
            elif self.frame % 24 == 0:
                self._cover_current_screen()
                self._apply_macos_window_level()
                self.raise_()

        if not self.isVisible() and not self.meteors and not self.bursts:
            return

        self.frame += 1
        if self.fading_out:
            target = 0.0
            smoothing = 0.16
        elif self.mode == "recording":
            target = max(0.24, self.level)
            smoothing = 0.58 if target > self.display_level else 0.20
        elif self.mode == "processing":
            target = 0.16
            smoothing = 0.12
        else:
            target = 0.0
            smoothing = 0.12

        self.display_level = self.display_level * (1.0 - smoothing) + target * smoothing
        self._update_meteors()
        self._update_bursts()
        if self.isVisible():
            self.update()

    def _ground_y(self):
        return self.height() - max(74.0, min(170.0, self.height() * 0.16))

    def _seed_scene(self):
        if not self.meteors:
            for _ in range(18):
                self._spawn_meteor(random.uniform(0.22, 0.55), seeded=True)
        if not self.bursts:
            ground_y = self._ground_y()
            for x in (self.width() * 0.18, self.width() * 0.42, self.width() * 0.66, self.width() * 0.86):
                self._spawn_burst(x, ground_y - random.uniform(4.0, 26.0), random.uniform(0.7, 1.15))

    def _update_meteors(self):
        level = self.display_level
        if self.fading_out:
            self.spawn_budget = 0.0
        elif self.mode == "recording":
            self.spawn_budget += 0.55 + level * 4.8 + level * level * 7.2
        elif self.mode == "processing":
            self.spawn_budget += 0.12 + level * 1.4

        spawn_count = min(int(self.spawn_budget), 7, self.max_meteors - len(self.meteors))
        self.spawn_budget -= spawn_count
        for _ in range(max(0, spawn_count)):
            self._spawn_meteor(level)

        ground_y = self._ground_y()
        next_meteors = []
        for meteor in self.meteors:
            meteor["age"] += 1
            meteor["x"] += meteor["vx"]
            meteor["y"] += meteor["vy"]
            meteor["vy"] += meteor["gravity"]
            meteor["phase"] += 0.12
            meteor["history"].append((meteor["x"], meteor["y"]))
            if len(meteor["history"]) > meteor["history_limit"]:
                meteor["history"].pop(0)

            if meteor["y"] >= ground_y - meteor["impact_offset"]:
                self._spawn_burst(meteor["x"], ground_y - meteor["impact_offset"], meteor["power"])
                continue

            if -150 < meteor["x"] < self.width() + 150 and meteor["y"] < self.height() + 90:
                next_meteors.append(meteor)

        self.meteors = next_meteors[-self.max_meteors :]
        if self.fading_out and not self.meteors and not self.bursts:
            self.fading_out = False
            self.hide()

    def _spawn_meteor(self, level, seeded=False):
        w = max(1, self.width())
        h = max(1, self.height())
        entry = random.choice(("top", "top", "left", "right"))
        speed = random.uniform(4.8, 8.4) + level * random.uniform(7.0, 13.0)

        if entry == "top":
            x = random.uniform(-w * 0.08, w * 1.08)
            y = -random.uniform(20.0, 130.0)
            vx = random.uniform(-2.6, 2.6) + random.choice((-1, 1)) * level * random.uniform(0.8, 2.8)
            vy = speed
        elif entry == "left":
            x = -random.uniform(24.0, 160.0)
            y = random.uniform(-30.0, h * 0.38)
            vx = speed * random.uniform(0.58, 0.95)
            vy = speed * random.uniform(0.54, 0.92)
        else:
            x = w + random.uniform(24.0, 160.0)
            y = random.uniform(-30.0, h * 0.38)
            vx = -speed * random.uniform(0.58, 0.95)
            vy = speed * random.uniform(0.54, 0.92)

        if seeded:
            y += random.uniform(80.0, h * 0.48)

        self.meteors.append(
            {
                "x": x,
                "y": y,
                "vx": vx,
                "vy": vy,
                "gravity": random.uniform(0.025, 0.08) + level * 0.035,
                "size": random.choice((5.0, 6.0, 7.0, 8.0)) + level * 4.0,
                "color": random.choice(((255, 232, 132), (255, 150, 72), (255, 82, 142), (112, 240, 255), (204, 166, 255))),
                "alpha": random.randint(220, 255),
                "history": [],
                "history_limit": random.randint(12, 22),
                "phase": random.uniform(0.0, math.tau),
                "age": 0,
                "impact_offset": random.uniform(0.0, 24.0),
                "power": random.uniform(0.8, 1.35) + level * 1.7,
            }
        )

    def _spawn_burst(self, x, y, power):
        for _ in range(min(42, int(14 + power * 14))):
            angle = random.uniform(math.pi * 1.04, math.pi * 1.96)
            speed = random.uniform(1.2, 5.2) * power
            life = random.randint(22, 54) + int(power * 10)
            self.bursts.append(
                {
                    "x": x + random.uniform(-8.0, 8.0),
                    "y": y + random.uniform(-5.0, 4.0),
                    "vx": math.cos(angle) * speed,
                    "vy": math.sin(angle) * speed,
                    "life": life,
                    "max_life": life,
                    "size": random.choice((2.0, 3.0, 4.0, 5.0)) + power * 1.2,
                    "color": random.choice(((255, 240, 170), (255, 154, 74), (255, 76, 128), (120, 238, 255))),
                    "alpha": random.randint(190, 255),
                }
            )
        self.bursts = self.bursts[-self.max_bursts :]

    def _update_bursts(self):
        next_bursts = []
        for burst in self.bursts:
            burst["life"] -= 2 if self.fading_out else 1
            burst["x"] += burst["vx"]
            burst["y"] += burst["vy"]
            burst["vx"] *= 0.956
            burst["vy"] = burst["vy"] * 0.976 + 0.14
            burst["size"] *= 0.985
            if burst["life"] > 0 and burst["size"] > 0.35:
                next_bursts.append(burst)
        self.bursts = next_bursts[-self.max_bursts :]

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
            logger.warning("Pixel Comet native window setup failed: %s", exc)

    def paintEvent(self, event):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, False)
        painter.setPen(Qt.PenStyle.NoPen)
        self._paint_edge_stars(painter)
        self._paint_ground(painter)
        self._paint_meteors(painter)
        self._paint_bursts(painter)
        painter.end()

    def _paint_edge_stars(self, painter):
        w = self.width()
        h = self.height()
        alpha = 70 if self.fading_out else 122
        painter.setBrush(QBrush(QColor(120, 236, 255, alpha)))
        for index in range(42):
            x = (index * 83 + self.frame * (1 + index % 3)) % max(1, w)
            y = (index * 47) % max(1, int(h * 0.34))
            size = 1 + (index % 3)
            if index % 2 == 0:
                painter.drawRect(QRectF(x, y, size, size))
            painter.drawRect(QRectF(w - x, h - y - 1, size, size))

    def _paint_ground(self, painter):
        w = self.width()
        h = self.height()
        ground_y = self._ground_y()
        painter.setBrush(QBrush(QColor(146, 56, 48, 175 if self.fading_out else 225)))
        painter.drawRect(QRectF(0, ground_y, w, h - ground_y))
        for index, x in enumerate(range(-24, int(w) + 48, 24)):
            ridge = math.sin(index * 0.75 + self.frame * 0.025) * 10.0
            y = ground_y + 12.0 + ridge
            painter.setBrush(QBrush(QColor(222, 92, 58, 170 if self.fading_out else 235)))
            painter.drawRect(QRectF(x, y, 26, h - y))
            painter.setBrush(QBrush(QColor(84, 36, 42, 135)))
            if index % 3 == 0:
                painter.drawRect(QRectF(x + 6, y + 18, 34, 5))

    def _paint_meteors(self, painter):
        for meteor in self.meteors:
            r, g, b = meteor["color"]
            history = meteor["history"]
            for index, (x, y) in enumerate(history):
                ratio = (index + 1) / max(1, len(history))
                alpha = int(meteor["alpha"] * 0.58 * ratio)
                size = max(2.0, meteor["size"] * ratio * 0.72)
                painter.setBrush(QBrush(QColor(r, g, b, alpha)))
                painter.drawRect(QRectF(round(x - size * 0.5), round(y - size * 0.5), size, size))

            x = meteor["x"]
            y = meteor["y"]
            size = meteor["size"] + math.sin(meteor["phase"]) * 0.8
            painter.setBrush(QBrush(QColor(r, g, b, meteor["alpha"])))
            painter.drawRect(QRectF(round(x - size * 0.5), round(y - size * 0.5), size, size))
            painter.setBrush(QBrush(QColor(255, 255, 220, min(255, meteor["alpha"] + 24))))
            painter.drawRect(QRectF(round(x - size * 0.22), round(y - size * 0.22), max(2.0, size * 0.44), max(2.0, size * 0.44)))

    def _paint_bursts(self, painter):
        for burst in self.bursts:
            life_ratio = max(0.0, min(1.0, burst["life"] / burst["max_life"]))
            alpha = int(burst["alpha"] * life_ratio)
            if alpha <= 0:
                continue
            r, g, b = burst["color"]
            size = burst["size"] * (0.9 + (1.0 - life_ratio) * 1.2)
            painter.setBrush(QBrush(QColor(r, g, b, alpha)))
            painter.drawRect(QRectF(round(burst["x"] - size * 0.5), round(burst["y"] - size * 0.5), size, size))

            if life_ratio > 0.66:
                flash = size * 2.7
                painter.setBrush(QBrush(QColor(255, 240, 170, int(alpha * 0.32))))
                painter.drawRect(QRectF(round(burst["x"] - flash * 0.5), round(burst["y"] - flash * 0.5), flash, flash))


class DisabledVoiceMeterOverlay(QObject):
    def set_mode(self, mode):
        pass

    def set_level(self, level):
        pass

    def hide(self):
        pass


EFFECT_OPTIONS = {
    "specters": ("👻 Cosmic Specters", CosmicSpecterOverlay),
    "ufo": ("🛸 Pixel UFO Trail", SimpleVoiceMeterOverlay),
    "comet": ("☄️ Pixel Comet", PixelCometOverlay),
    "off": ("Off", DisabledVoiceMeterOverlay),
}
DEFAULT_EFFECT = "specters"


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
            request_kwargs = {"model": "whisper-1", "timeout": 30.0}
            if WHISPER_LANGUAGE:
                request_kwargs["language"] = WHISPER_LANGUAGE
            with open(temp_path, "rb") as audio_file:
                transcript = client.audio.transcriptions.create(file=audio_file, **request_kwargs)

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

    def __init__(self):
        self.target = None

    def remember_target(self):
        try:
            frontmost = NSWorkspace.sharedWorkspace().frontmostApplication()
            if frontmost is None:
                return
            pid = int(frontmost.processIdentifier())
            bundle_id = frontmost.bundleIdentifier() or ""
            if pid == os.getpid() or bundle_id.startswith("org.python"):
                return
            self.target = {
                "pid": pid,
                "bundle_id": bundle_id,
                "name": frontmost.localizedName() or bundle_id or str(pid),
            }
            logger.info("Paste target: %s", self.target["name"])
        except Exception as exc:
            logger.warning("Could not remember paste target: %s", exc)

    def restore_target(self):
        if not self.target:
            return
        try:
            workspace = NSWorkspace.sharedWorkspace()
            target_app = None
            for app in workspace.runningApplications():
                if int(app.processIdentifier()) == self.target["pid"]:
                    target_app = app
                    break
            if target_app is None and self.target["bundle_id"]:
                apps = workspace.runningApplicationsWithBundleIdentifier_(self.target["bundle_id"])
                if apps:
                    target_app = apps[0]
            if target_app is None:
                return
            target_app.activateWithOptions_(NSApplicationActivateIgnoringOtherApps)
            time.sleep(0.25)
        except Exception as exc:
            logger.warning("Could not restore paste target: %s", exc)

    def paste(self, text):
        self._copy_to_clipboard(text)
        logger.info("Text copied to clipboard")
        self.restore_target()
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


class StatusBarApp(QSystemTrayIcon):
    def __init__(self, app):
        super().__init__()
        self.app = app
        self.state = "idle"
        self.frame = 0
        self.last_shift = False
        self.last_shift_release_time = 0.0
        self.shift_press_time = 0.0
        self.waiting_for_hold = False
        self.paste_controller = PasteController()
        self.effect_key = self._load_effect_key()
        self.effect_actions = {}
        self.worker = None

        self.log_window = LogWindow()
        self.voice_meter = self._create_voice_meter(self.effect_key)
        self._setup_logging()
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

    def _load_effect_key(self):
        try:
            with open(EFFECT_PREF_FILE, "r", encoding="utf-8") as fh:
                key = json.load(fh).get("effect")
            if key in EFFECT_OPTIONS:
                return key
        except FileNotFoundError:
            pass
        except Exception as exc:
            logger.warning("Could not load effect preference: %s", exc)
        return DEFAULT_EFFECT

    def _save_effect_key(self):
        try:
            with open(EFFECT_PREF_FILE, "w", encoding="utf-8") as fh:
                json.dump({"effect": self.effect_key}, fh)
        except Exception as exc:
            logger.warning("Could not save effect preference: %s", exc)

    def _create_voice_meter(self, effect_key):
        _, overlay_cls = EFFECT_OPTIONS.get(effect_key, EFFECT_OPTIONS[DEFAULT_EFFECT])
        return overlay_cls()

    def set_effect(self, effect_key):
        if effect_key not in EFFECT_OPTIONS or effect_key == self.effect_key:
            return

        old_meter = self.voice_meter
        if self.worker is not None:
            try:
                self.worker.level_signal.disconnect(old_meter.set_level)
            except TypeError:
                pass

        try:
            old_meter.hide()
        except Exception:
            pass
        if isinstance(old_meter, QWidget):
            old_meter.deleteLater()

        self.effect_key = effect_key
        self.voice_meter = self._create_voice_meter(effect_key)
        if self.worker is not None:
            self.worker.level_signal.connect(self.voice_meter.set_level)
        self.voice_meter.set_mode(self.state)
        self._save_effect_key()
        self._sync_effect_actions()
        logger.info("Voice effect selected: %s", EFFECT_OPTIONS[effect_key][0])

    def _sync_effect_actions(self):
        for key, action in self.effect_actions.items():
            action.setChecked(key == self.effect_key)

    def _setup_menu(self):
        menu = QMenu()
        logs_action = menu.addAction("View Logs & Cost")
        logs_action.triggered.connect(self.show_logs)
        effects_menu = menu.addMenu("🛸 Effects")
        for key, (label, _) in EFFECT_OPTIONS.items():
            action = effects_menu.addAction(label)
            action.setCheckable(True)
            action.triggered.connect(lambda checked=False, effect_key=key: self.set_effect(effect_key))
            self.effect_actions[key] = action
        self._sync_effect_actions()
        menu.addSeparator()
        quit_action = menu.addAction("Quit")
        quit_action.triggered.connect(self.app.quit)
        self.setContextMenu(menu)

    def _setup_timers(self):
        self.icon_timer = QTimer()
        self.icon_timer.timeout.connect(self.update_icon)
        self.icon_timer.start(33)

        self.key_timer = QTimer()
        self.key_timer.timeout.connect(self.check_keys)
        self.key_timer.start(50)

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
                self.waiting_for_hold = (now - self.last_shift_release_time) < HOTKEY.tap_gap_threshold

        elif not is_shift and self.last_shift:
            self.last_shift_release_time = now
            self.waiting_for_hold = False

        elif is_shift and self.last_shift and self.waiting_for_hold and self.state in ("idle", "done"):
            if now - self.shift_press_time >= HOTKEY.hold_threshold:
                logger.info("Hold detected; starting dictation")
                self.paste_controller.remember_target()
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
            prepare_for_paste = getattr(self.voice_meter, "prepare_for_paste", None)
            if prepare_for_paste is not None:
                prepare_for_paste()
            else:
                self.voice_meter.hide()
                QApplication.processEvents()
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
