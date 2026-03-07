import sys
import os
import time
import math
import wave
import tempfile
import logging
import json
import pyaudio
import pyperclip
from datetime import datetime
from openai import OpenAI
from dotenv import load_dotenv  # 👈 Добавили импорт

from PyQt6.QtWidgets import (
    QApplication,
    QSystemTrayIcon,
    QMenu,
    QWidget,
    QVBoxLayout,
    QPlainTextEdit,
    QLabel,
)
from PyQt6.QtCore import Qt, QTimer, QThread, pyqtSignal, QRectF, QPointF, QObject
from PyQt6.QtGui import QPainter, QColor, QBrush, QPen, QIcon, QPixmap, QFont

from AppKit import NSEvent, NSEventModifierFlagShift, NSApplication

load_dotenv()

API_KEY = os.getenv("OPENAI_API_KEY")

if not API_KEY:
    print(
        "❌ ОШИБКА: API ключ не найден! Убедись, что файл .env существует и содержит OPENAI_API_KEY."
    )
    sys.exit(1)


TAP_GAP_THRESHOLD = 0.5
HOLD_THRESHOLD = 1.0
MAX_RECORD_SECONDS = 120.0
PRICE_WHISPER_PER_MIN = 0.006
COST_FILE = os.path.expanduser("~/.openai_voice_costs.json")

FORMAT = pyaudio.paInt16
CHANNELS = 1
RATE = 44100
CHUNK = 1024

client = OpenAI(api_key=API_KEY)

logger = logging.getLogger("VoiceApp")
logger.setLevel(logging.INFO)


class CostManager:
    def __init__(self):
        self.current_month = datetime.now().strftime("%Y-%m")
        self.total_cost = 0.0
        self._load_costs()

    def _load_costs(self):
        if os.path.exists(COST_FILE):
            try:
                with open(COST_FILE, "r") as f:
                    data = json.load(f)
                    saved_month = data.get("month", "")
                    if saved_month == self.current_month:
                        self.total_cost = data.get("total_cost", 0.0)
                    else:
                        self.total_cost = 0.0
            except Exception as e:
                print(f"Error loading costs: {e}")

    def _save_costs(self):
        data = {"month": self.current_month, "total_cost": self.total_cost}
        try:
            with open(COST_FILE, "w") as f:
                json.dump(data, f)
        except Exception as e:
            print(f"Error saving costs: {e}")

    def add_cost(self, amount):
        now_month = datetime.now().strftime("%Y-%m")
        if now_month != self.current_month:
            self.current_month = now_month
            self.total_cost = 0.0
        self.total_cost += amount
        self._save_costs()
        return self.total_cost


cost_manager = CostManager()


class QtLogHandler(logging.Handler, QObject):
    log_signal = pyqtSignal(str)

    def __init__(self):
        super().__init__()
        QObject.__init__(self)

    def emit(self, record):
        msg = self.format(record)
        self.log_signal.emit(msg)


class LogWindow(QWidget):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Whisper Logs & Costs")
        self.resize(500, 350)
        layout = QVBoxLayout()
        self.cost_label = QLabel(
            f"💰 Total Spend ({cost_manager.current_month}): ${cost_manager.total_cost:.4f}"
        )
        self.cost_label.setStyleSheet(
            "font-size: 16px; font-weight: bold; color: #4CAF50; padding: 10px;"
        )
        layout.addWidget(self.cost_label)
        self.text_edit = QPlainTextEdit()
        self.text_edit.setReadOnly(True)
        self.text_edit.setFont(QFont("Menlo", 12))
        self.text_edit.setStyleSheet("background-color: #1e1e1e; color: #00ff00;")
        layout.addWidget(self.text_edit)
        self.setLayout(layout)

    def append_log(self, text):
        self.text_edit.appendPlainText(text)
        self.text_edit.verticalScrollBar().setValue(
            self.text_edit.verticalScrollBar().maximum()
        )

    def update_cost_display(self):
        self.cost_label.setText(
            f"💰 Total Spend ({cost_manager.current_month}): ${cost_manager.total_cost:.5f}"
        )


class AudioWorker(QThread):
    finished_signal = pyqtSignal(object)
    cost_update_signal = pyqtSignal()
    limit_reached_signal = pyqtSignal()

    def __init__(self):
        super().__init__()
        self.is_recording = False
        self.is_cancelled = False  # Флаг для отмены повисших процессов

    def start_recording(self):
        self.is_recording = True
        if not self.isRunning():
            self.start()

    def stop_recording(self):
        self.is_recording = False

    def run(self):
        frames = []
        start_time = time.time()
        audio = pyaudio.PyAudio()
        try:
            logger.info("🎙 Start recording...")
            stream = audio.open(
                format=FORMAT,
                channels=CHANNELS,
                rate=RATE,
                input=True,
                frames_per_buffer=CHUNK,
            )
            while self.is_recording:
                data = stream.read(CHUNK, exception_on_overflow=False)
                frames.append(data)

                if time.time() - start_time >= MAX_RECORD_SECONDS:
                    logger.info("⏱️ 2 minutes limit reached. Auto-stopping.")
                    self.is_recording = False
                    self.limit_reached_signal.emit()
                    break

            stream.stop_stream()
            stream.close()

            duration_sec = time.time() - start_time

            if len(frames) < 10:
                logger.warning("⚠️ Recording too short, cancelled.")
                self.finished_signal.emit(None)
                return

            logger.info(f"🎙 Recording finished ({duration_sec:.2f}s). Processing...")
            sample_width = audio.get_sample_size(FORMAT)
            self._transcribe(frames, duration_sec, sample_width)
        except Exception as e:
            if not self.is_cancelled:
                logger.error(f"❌ Audio Error: {e}")
                self.finished_signal.emit(None)
        finally:
            audio.terminate()

    def _transcribe(self, frames, duration_sec, sample_width):
        duration_min = duration_sec / 60.0
        cost = duration_min * PRICE_WHISPER_PER_MIN
        cost_manager.add_cost(cost)
        self.cost_update_signal.emit()

        temp_path = ""
        try:
            with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tf:
                wf = wave.open(tf.name, "wb")
                wf.setnchannels(CHANNELS)
                wf.setsampwidth(sample_width)
                wf.setframerate(RATE)
                wf.writeframes(b"".join(frames))
                wf.close()
                temp_path = tf.name

            logger.info(f"🚀 Sending to OpenAI Whisper... (Cost: ${cost:.5f})")
            with open(temp_path, "rb") as audio_file:
                transcript = client.audio.transcriptions.create(
                    model="whisper-1", file=audio_file, timeout=30.0
                )

            if self.is_cancelled:
                logger.info("⚠️ Old transcription result discarded (cancelled).")
                return

            text = transcript.text
            if text:
                text = text[0].lower() + text[1:]
                logger.info(f"✅ Transcribed: '{text}'")
                self.finished_signal.emit(text)
            else:
                logger.info("⚠️ Empty response.")
                self.finished_signal.emit(None)

        except Exception as e:
            if not self.is_cancelled:
                logger.error(f"❌ API Error / Timeout: {e}")
                self.finished_signal.emit(None)
        finally:
            if temp_path and os.path.exists(temp_path):
                os.remove(temp_path)


class StatusBarApp(QSystemTrayIcon):
    def __init__(self, app):
        super().__init__()
        self.app = app
        self.state = "idle"
        self.anim_frame = 0

        self.log_window = LogWindow()

        gui_handler = QtLogHandler()
        gui_handler.setFormatter(
            logging.Formatter("%(asctime)s - %(message)s", datefmt="%H:%M:%S")
        )
        gui_handler.log_signal.connect(self.log_window.append_log)
        logger.addHandler(gui_handler)

        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(
            logging.Formatter("%(asctime)s - %(levelname)s - %(message)s")
        )
        logger.addHandler(console_handler)

        self.menu = QMenu()
        logs_action = self.menu.addAction("📄 View Logs & Cost")
        logs_action.triggered.connect(self.show_logs)
        self.menu.addSeparator()
        quit_action = self.menu.addAction("Exit")
        quit_action.triggered.connect(self.app.quit)
        self.setContextMenu(self.menu)

        self.anim_timer = QTimer()
        self.anim_timer.timeout.connect(self.update_icon)
        self.anim_timer.start(33)

        self.worker = None
        self._recreate_worker()

        self.key_timer = QTimer()
        self.key_timer.timeout.connect(self.check_keys)
        self.key_timer.start(50)

        self.last_shift = False
        self.last_shift_release_time = 0.0
        self.shift_press_time = 0.0
        self.waiting_for_hold = False

        self.update_icon()
        self.setVisible(True)

        logger.info("✅ Whisper App started. Tap then Hold Shift to record.")

    def _recreate_worker(self):
        if self.worker is not None:
            self.worker.is_cancelled = True
            try:
                self.worker.finished_signal.disconnect()
                self.worker.cost_update_signal.disconnect()
                self.worker.limit_reached_signal.disconnect()
            except TypeError:
                pass

        self.worker = AudioWorker()
        self.worker.finished_signal.connect(self.on_transcription_done)
        self.worker.cost_update_signal.connect(self.log_window.update_cost_display)
        self.worker.limit_reached_signal.connect(self.on_auto_stop)

    def show_logs(self):
        self.log_window.update_cost_display()
        self.log_window.show()
        self.log_window.raise_()
        self.log_window.activateWindow()

    def on_auto_stop(self):
        if self.state == "recording":
            self.state = "processing"
            self.waiting_for_hold = False

    def check_keys(self):
        try:
            flags = NSEvent.modifierFlags()
            is_shift = bool(flags & NSEventModifierFlagShift)
        except:
            is_shift = False

        now = time.time()

        if is_shift and not self.last_shift:
            if self.state == "recording":
                self.state = "processing"
                self.worker.stop_recording()
                self.waiting_for_hold = False
            elif self.state == "processing":
                # --- ЛОГИКА ОТМЕНЫ ЗАВИСАНИЯ ---
                logger.warning("⛔ Запрос отменен пользователем вручную.")
                self._recreate_worker()
                self.state = "idle"
                self.waiting_for_hold = False
            else:
                self.shift_press_time = now
                if (now - self.last_shift_release_time) < TAP_GAP_THRESHOLD:
                    self.waiting_for_hold = True
                else:
                    self.waiting_for_hold = False

        elif not is_shift and self.last_shift:
            self.last_shift_release_time = now
            self.waiting_for_hold = False

        elif is_shift and self.last_shift:
            if self.waiting_for_hold and self.state in ["idle", "done"]:
                if (now - self.shift_press_time) >= HOLD_THRESHOLD:
                    logger.info("🎤 Tap and Hold detected. Starting dictation.")
                    self.state = "recording"
                    self.worker.start_recording()
                    self.waiting_for_hold = False

        self.last_shift = is_shift

    def on_transcription_done(self, text):
        if text is None:
            self.state = "idle"
            self.update_icon()
            return

        self._paste(text)
        self.state = "done"
        QTimer.singleShot(1500, lambda: setattr(self, "state", "idle"))

    def _paste(self, text):
        try:
            pyperclip.copy(text)
            logger.info("📋 Text copied to clipboard.")
            time.sleep(0.1)
            cmd = """osascript -e 'tell application "System Events" to keystroke "v" using command down'"""
            os.system(cmd)
            logger.info("⌨️ Pasted (Cmd+V).")
        except Exception as e:
            logger.error(f"❌ Paste Error: {e}")

    def update_icon(self):
        self.anim_frame += 1
        size = 22
        pixmap = QPixmap(size, size)
        pixmap.fill(Qt.GlobalColor.transparent)

        painter = QPainter(pixmap)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        center = size / 2

        if self.state == "idle":
            painter.setPen(QPen(QColor("white"), 2))
            painter.drawEllipse(QRectF(4, 4, 14, 14))

        elif self.state == "recording":
            pulse = (math.sin(self.anim_frame * 0.2) + 1) / 2
            radius = 6 + (pulse * 3)
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QBrush(QColor(255, 59, 48)))
            painter.drawEllipse(QPointF(center, center), radius, radius)
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.setPen(QPen(QColor(255, 59, 48, 100), 1))
            painter.drawEllipse(QPointF(center, center), 10, 10)

        elif self.state == "processing":
            painter.setPen(QPen(QColor(10, 132, 255), 3))
            start_angle = (self.anim_frame * 20) % 360
            span_angle = 270
            rect = QRectF(4, 4, 14, 14)
            painter.drawArc(rect, start_angle * 16, span_angle * 16)

        elif self.state == "done":
            painter.setPen(Qt.PenStyle.NoPen)
            painter.setBrush(QBrush(QColor(48, 209, 88)))
            painter.drawEllipse(QRectF(4, 4, 14, 14))

        painter.end()
        self.setIcon(QIcon(pixmap))


def main():
    app = QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    ns_app = NSApplication.sharedApplication()
    ns_app.setActivationPolicy_(1)
    tray = StatusBarApp(app)
    print("✅ Running. Check 'View Logs & Cost' in menu.")
    sys.exit(app.exec())


if __name__ == "__main__":
    main()

