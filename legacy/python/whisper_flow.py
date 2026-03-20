#!/usr/bin/env python3
"""WhisperFlow — Double-tap Left ⌘ to toggle recording, transcribe via Groq, copy to clipboard."""

import io
import os
import subprocess
import threading
import time

import numpy as np
import requests
import rumps
import sounddevice as sd
import soundfile as sf
from AppKit import NSEvent, NSFlagsChangedMask

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
GROQ_API_KEY = os.environ.get("GROQ_API_KEY", "")
GROQ_URL = "https://api.groq.com/openai/v1/audio/transcriptions"
SAMPLE_RATE = 16000
CHANNELS = 1
MAX_RECORD_SECONDS = 30
API_TIMEOUT = 30

# Known words/terms to guide Whisper's spelling (passed via prompt parameter)
VOCABULARY = [
    "PRs", "PR", "Git", "GitHub", "Netlify", "Supabase", "SQL", "PostgreSQL",
    "API", "APIs", "CLI", "UI", "UX", "OAuth", "JWT", "JSON", "YAML",
    "TypeScript", "JavaScript", "Python", "Node.js", "Next.js", "React",
    "Vercel", "AWS", "Docker", "Kubernetes", "Redis", "GraphQL", "Deskloop",
]

SND_START = "/System/Library/Sounds/Tink.aiff"
SND_STOP = "/System/Library/Sounds/Pop.aiff"
SND_ERROR = "/System/Library/Sounds/Basso.aiff"

KC_LEFT_CMD = 55
DOUBLE_TAP_INTERVAL = 0.4

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
IDLE, RECORDING, TRANSCRIBING = "idle", "recording", "transcribing"


def play_sound(path):
    if os.path.exists(path):
        subprocess.Popen(["afplay", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def copy_to_clipboard(text):
    proc = subprocess.Popen(["pbcopy"], stdin=subprocess.PIPE)
    proc.communicate(text.encode("utf-8"))


class WhisperFlow(rumps.App):
    def __init__(self):
        super().__init__("🎙", quit_button=None)
        self.state = IDLE
        self.lock = threading.Lock()

        self.audio_frames = []
        self.stream = None
        self.record_start = 0.0
        self._last_lcmd_up = 0.0
        self._monitors_installed = False
        self.selected_device = None  # None = system default

        # Pending UI update from background thread
        self._pending_ui = None
        # Pending notification from background thread (title, subtitle, message)
        self._pending_notification = None

        # Menu
        self.status_item = rumps.MenuItem("Status: Ready")
        self.status_item.set_callback(None)
        self.record_btn = rumps.MenuItem("Start Recording", callback=self.on_toggle_record)
        self.mic_menu = rumps.MenuItem("Mic")
        self._build_mic_submenu()
        self.menu = [self.status_item, self.record_btn, self.mic_menu, None,
                     rumps.MenuItem("Quit", callback=self.on_quit)]

        if not GROQ_API_KEY:
            self._notify("WhisperFlow", "Missing API Key",
                         "Set GROQ_API_KEY environment variable.")

        # Poll timer — 50ms
        self.timer = rumps.Timer(self._poll, 0.05)
        self.timer.start()

    def _set_ui(self, icon, btn_title, status):
        """Thread-safe UI update. If called from background thread, defers to main thread."""
        if threading.current_thread() is threading.main_thread():
            self.title = icon
            self.record_btn.title = btn_title
            self.status_item.title = "Status: " + status
        else:
            self._pending_ui = (icon, btn_title, status)

    def _notify(self, title, subtitle, message):
        """Thread-safe notification. Defers to main thread if called from background."""
        if threading.current_thread() is threading.main_thread():
            rumps.notification(title, subtitle, message)
        else:
            self._pending_notification = (title, subtitle, message)

    def _install_monitors(self):
        mask = NSFlagsChangedMask
        self._global_monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(
            mask, self._handle_event
        )
        self._local_monitor = NSEvent.addLocalMonitorForEventsMatchingMask_handler_(
            mask, self._handle_local_event
        )
        self._monitors_installed = True
        print("[WhisperFlow] Ready", flush=True)
        self._set_ui("🎙", "Start Recording", "Ready — double-tap Left ⌘")

    def _handle_event(self, event):
        self._process_event(event)

    def _handle_local_event(self, event):
        self._process_event(event)
        return event

    def _process_event(self, event):
        try:
            key_code = event.keyCode()
            flags = event.modifierFlags()
            cmd_flag = bool(flags & (1 << 20))

            if key_code != KC_LEFT_CMD:
                return

            if cmd_flag:
                # Left Cmd pressed
                now = time.monotonic()
                gap = now - self._last_lcmd_up
                if gap <= DOUBLE_TAP_INTERVAL:
                    # Second press within window — start recording
                    print("[WhisperFlow] Double-tap hold — recording!", flush=True)
                    self._last_lcmd_up = 0.0  # reset to avoid re-trigger
                    with self.lock:
                        if self.state == IDLE:
                            self._start_recording()
            else:
                # Left Cmd released
                now = time.monotonic()
                self._last_lcmd_up = now

                # Stop recording on release
                with self.lock:
                    if self.state == RECORDING:
                        print("[WhisperFlow] Released — stopping", flush=True)
                        self._stop_recording()
        except Exception as e:
            print(f"[WhisperFlow] Event error: {e}", flush=True)

    # ------------------------------------------------------------------
    # Mic selection
    # ------------------------------------------------------------------
    def _build_mic_submenu(self):
        # clear() fails before the MenuItem is attached to the menu bar
        if self.mic_menu._menu is not None:
            self.mic_menu.clear()

        default_item = rumps.MenuItem("System Default", callback=self._on_mic_select)
        default_item.state = self.selected_device is None
        self.mic_menu.add(default_item)

        seen_names = set()
        devices = sd.query_devices()
        for i, dev in enumerate(devices):
            if dev["max_input_channels"] > 0:
                title = dev["name"]
                # Disambiguate duplicate device names for rumps' dict-based menu
                if title in seen_names or title in ("System Default", "Refresh Devices"):
                    title = f"{title} [{i}]"
                seen_names.add(title)
                item = rumps.MenuItem(title, callback=self._on_mic_select)
                item._device_index = i
                item.state = (self.selected_device == i)
                self.mic_menu.add(item)

        self.mic_menu.add(None)  # separator
        self.mic_menu.add(rumps.MenuItem("Refresh Devices", callback=self._on_refresh_mics))

    def _on_mic_select(self, sender):
        if hasattr(sender, "_device_index"):
            self.selected_device = sender._device_index
        else:
            self.selected_device = None

        # Update checkmarks
        for item in self.mic_menu.values():
            if not isinstance(item, rumps.MenuItem) or item.title == "Refresh Devices":
                continue
            if hasattr(item, "_device_index"):
                item.state = item._device_index == self.selected_device
            else:
                item.state = self.selected_device is None

    def _on_refresh_mics(self, _):
        self._build_mic_submenu()

    def on_toggle_record(self, _):
        with self.lock:
            if self.state == IDLE:
                self._start_recording()
            elif self.state == RECORDING:
                self._stop_recording()

    # ------------------------------------------------------------------
    # Poll timer (main thread)
    # ------------------------------------------------------------------
    def _poll(self, _):
        if not self._monitors_installed:
            self._install_monitors()
            return

        # Apply pending UI updates from background threads
        pending = self._pending_ui
        if pending:
            self._pending_ui = None
            self.title = pending[0]
            self.record_btn.title = pending[1]
            self.status_item.title = "Status: " + pending[2]

        # Apply pending notification from background threads
        pending_notif = self._pending_notification
        if pending_notif:
            self._pending_notification = None
            rumps.notification(pending_notif[0], pending_notif[1], pending_notif[2])

        with self.lock:
            if self.state == RECORDING:
                elapsed = time.monotonic() - self.record_start
                secs = int(elapsed)
                self.status_item.title = f"Status: Recording... {secs}s"
                if elapsed >= MAX_RECORD_SECONDS:
                    self._stop_recording()

    # ------------------------------------------------------------------
    # Recording
    # ------------------------------------------------------------------
    def _start_recording(self):
        if not GROQ_API_KEY:
            play_sound(SND_ERROR)
            return

        self.state = RECORDING
        self._set_ui("🔴", "Stop Recording", "Recording...")
        self.audio_frames = []
        self.record_start = time.monotonic()

        def audio_callback(indata, frames, time_info, status):
            self.audio_frames.append(indata.copy())

        try:
            self.stream = sd.InputStream(
                samplerate=SAMPLE_RATE, channels=CHANNELS,
                dtype="float32", callback=audio_callback,
                device=self.selected_device,
            )
            self.stream.start()
            play_sound(SND_START)
            print("[WhisperFlow] Recording started", flush=True)
        except Exception as e:
            print(f"[WhisperFlow] Audio error: {e}", flush=True)
            play_sound(SND_ERROR)
            self.state = IDLE
            self._set_ui("🎙", "Start Recording", "Audio error")

    def _stop_recording(self):
        self.state = TRANSCRIBING
        self._set_ui("⏳", "Transcribing...", "Transcribing...")
        play_sound(SND_STOP)
        print("[WhisperFlow] Recording stopped", flush=True)

        if self.stream:
            self.stream.stop()
            self.stream.close()
            self.stream = None

        if not self.audio_frames:
            self.state = IDLE
            self._set_ui("🎙", "Start Recording", "Ready — double-tap Left ⌘")
            return

        audio_data = np.concatenate(self.audio_frames, axis=0)
        self.audio_frames = []
        threading.Thread(target=self._transcribe, args=(audio_data,), daemon=True).start()

    # ------------------------------------------------------------------
    # Transcription (background thread)
    # ------------------------------------------------------------------
    def _transcribe(self, audio_data):
        try:
            buf = io.BytesIO()
            sf.write(buf, audio_data, SAMPLE_RATE, format="WAV", subtype="PCM_16")
            buf.seek(0)
            print("[WhisperFlow] Sending to API...", flush=True)

            resp = requests.post(
                GROQ_URL,
                headers={"Authorization": f"Bearer {GROQ_API_KEY}"},
                files={"file": ("recording.wav", buf, "audio/wav")},
                data={
                    "model": "whisper-large-v3-turbo",
                    "response_format": "text",
                    "language": "en",
                    "prompt": " ".join(VOCABULARY),
                },
                timeout=API_TIMEOUT,
            )
            resp.raise_for_status()
            print(f"[WhisperFlow] API response: {resp.status_code}", flush=True)

            text = resp.text.strip()
            if text:
                copy_to_clipboard(text)
                print(f"[WhisperFlow] Transcribed: {text[:80]}", flush=True)
                self._notify("WhisperFlow", "Copied to clipboard", text[:100])
            else:
                print("[WhisperFlow] No speech detected", flush=True)
                self._notify("WhisperFlow", "No speech detected", "")
        except requests.exceptions.Timeout:
            print("[WhisperFlow] API timeout", flush=True)
            play_sound(SND_ERROR)
            self._notify("WhisperFlow", "Error", "API request timed out")
        except Exception as e:
            print(f"[WhisperFlow] Transcription error: {e}", flush=True)
            play_sound(SND_ERROR)
            self._notify("WhisperFlow", "Error", str(e)[:100])
        finally:
            print("[WhisperFlow] Transcription done, resetting state", flush=True)
            with self.lock:
                self.state = IDLE
                self._set_ui("🎙", "Start Recording", "Ready — double-tap Left ⌘")

    def on_quit(self, _):
        if self.stream:
            self.stream.stop()
            self.stream.close()
        if hasattr(self, '_global_monitor') and self._global_monitor:
            NSEvent.removeMonitor_(self._global_monitor)
        if hasattr(self, '_local_monitor') and self._local_monitor:
            NSEvent.removeMonitor_(self._local_monitor)
        rumps.quit_application()


if __name__ == "__main__":
    WhisperFlow().run()
