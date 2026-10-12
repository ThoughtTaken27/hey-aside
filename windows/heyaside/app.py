"""Hey Aside for Windows: say "Hey Jarvis", ask, and Aside does it; Ryan reads the answer back.

Flow (same as the Mac app):
  wake word (or the hotkey) -> listen until you stop talking -> transcribe on this PC -> Aside session via aside.exe
  -> steps shown on the island -> the answer spoken -> 30 s of follow-up listening with no wake word.
While Aside works you can say "Hey Jarvis, what are you doing", "stop", "actually ...", or add something for after.
"""
from __future__ import annotations

import json
import os
import random
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor

import numpy as np
from PySide6.QtCore import QObject, QTimer, QUrl, Signal, Slot
from PySide6.QtGui import QAction, QColor, QDesktopServices, QIcon, QPainter, QPixmap, QRadialGradient
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

from . import aside_cli, audio, config, hotkey, spoken
from .island import BLUE, CYAN, SKY, Island

ACKS = ["One moment, sir.", "Let me look.", "Right, checking now.", "Give me a second.", "Looking into it."]
SUMMONED = ["Sir?", "Yes, sir?"]
SIGN_OFF = ["Very good, sir.", "Anytime.", "Of course."]
RUN_KEY = r"Software\Microsoft\Windows\CurrentVersion\Run"


def orb_icon() -> QIcon:
    pm = QPixmap(64, 64)
    pm.fill(QColor(0, 0, 0, 0))
    p = QPainter(pm)
    p.setRenderHint(QPainter.RenderHint.Antialiasing)
    g = QRadialGradient(26, 24, 34)
    g.setColorAt(0, SKY)
    g.setColorAt(0.4, CYAN)
    g.setColorAt(0.8, BLUE)
    p.setBrush(g)
    p.setPen(QColor(0, 0, 0, 0))
    p.drawEllipse(6, 6, 52, 52)
    p.end()
    return QIcon(pm)


class Controller(QObject):
    # cross-thread signals (audio thread / worker threads -> Qt main thread)
    sig_wake = Signal()
    sig_level = Signal(float)
    sig_utterance = Signal(object)
    sig_timeout = Signal()
    sig_text = Signal(str, bool)        # transcript, came from a fresh wake
    sig_session = Signal(str)
    sig_step = Signal(str)
    sig_done = Signal(object)
    sig_ready = Signal(str)             # "" = ready, else an error to show
    sig_fast = Signal(str, str)         # (request, answer) from the optional fast path

    def __init__(self, app: QApplication, log):
        super().__init__()
        self.app, self.log = app, log
        self.s = config.load()
        self.island = Island()
        self.island.clicked.connect(self.poke)
        self.mic = audio.Mic(self.s.get("micDevice"))
        self.endpointer = audio.Endpointer(self.s["silence"], self.s["initialWait"])
        self.wake = None
        self.stt = None
        self.cli = aside_cli.find_cli(self.s["asideCli"])
        self.pool = ThreadPoolExecutor(max_workers=2)
        self.state = "starting"          # starting | idle | listening | transcribing | speaking | followup
        self.from_wake = False
        self.buffer: list[np.ndarray] = []
        self.run: aside_cli.AgentRun | None = None
        self.session: str | None = None
        self.session_at = 0.0
        self.last_step: str | None = None
        self.speaker = None
        self.cancelled: aside_cli.AgentRun | None = None
        self._audio_stop = threading.Event()

        for sig, slot in ((self.sig_wake, self.on_wake), (self.sig_level, self.island.set_level),
                          (self.sig_utterance, self.on_utterance), (self.sig_timeout, self.on_timeout),
                          (self.sig_text, self.on_text), (self.sig_session, self.on_session), (self.sig_step, self.on_step),
                          (self.sig_done, self.on_done), (self.sig_ready, self.on_ready), (self.sig_fast, self.on_fast)):
            sig.connect(slot)

        self.tray = QSystemTrayIcon(orb_icon(), self.app)
        self.tray.setToolTip("Hey Aside: getting ready")
        self._menu()
        self.tray.show()

        from .tts import Speaker

        self.speaker = Speaker(self.s["voice"], self.s["rate"], log)
        self.speaker.finished.connect(self.on_spoken)

        hotkey.listen(self.s["hotkey"], lambda: QTimer.singleShot(0, self.poke), log)
        threading.Thread(target=self._load_models, daemon=True).start()

    # ------------------------------------------------------------------ setup

    def _load_models(self) -> None:
        try:
            audio.ensure_wake_models()
            self.wake = audio.WakeWord(self.s["wakeThreshold"])
            from .stt import Transcriber

            self.stt = Transcriber(self.s["whisperModel"])
            self.sig_ready.emit("")
        except Exception as e:
            self.log.exception("model load failed")
            self.sig_ready.emit(f"{e.__class__.__name__}: {e}")

    @Slot(str)
    def on_ready(self, err: str) -> None:
        if err:
            self.tray.setToolTip("Hey Aside: could not start (see the log)")
            self.tray.showMessage("Hey Aside", f"Could not load speech models: {err[:120]}")
            return
        if not self.cli:
            self.tray.showMessage("Hey Aside", "Aside CLI not found. Install it (Aside Settings > Developer), then restart Hey Aside.")
        self.state = "idle"
        self.tray.setToolTip('Hey Aside: say "Hey Jarvis"' if not self.s["muted"] else "Hey Aside: muted")
        if self.s["muted"]:
            self.island.set_phase("hidden")
        else:
            self.mic.start()
        threading.Thread(target=self._audio_loop, daemon=True).start()
        self.log.info(f"ready; aside cli: {self.cli}")

    def _menu(self) -> None:
        m = QMenu()
        self.act_talk = QAction("Talk now", m, triggered=self.poke)
        self.act_mute = QAction("Mute microphone", m, checkable=True, checked=self.s["muted"], triggered=self.set_muted)
        self.act_voice = QAction("Speak replies", m, checkable=True, checked=self.s["spokenReplies"],
                                 triggered=lambda on: self._set("spokenReplies", on))
        self.act_words = QAction("Show Jarvis's words", m, checkable=True, checked=self.s["showJarvisWords"],
                                 triggered=lambda on: self._set("showJarvisWords", on))
        self.act_login = QAction("Start at login", m, checkable=True, checked=self.login_enabled(), triggered=self.set_login)
        for a in (self.act_talk, self.act_mute, self.act_voice, self.act_words, self.act_login):
            m.addAction(a)
        m.addSeparator()
        m.addAction(QAction("Open settings file", m, triggered=self.open_settings))
        m.addAction(QAction("Open log folder", m, triggered=lambda: QDesktopServices.openUrl(QUrl.fromLocalFile(str(config.LOG_DIR)))))
        m.addSeparator()
        m.addAction(QAction("Quit Hey Aside", m, triggered=self.quit))
        self.menu = m
        self.tray.setContextMenu(m)
        self.tray.activated.connect(lambda r: self.poke() if r == QSystemTrayIcon.ActivationReason.Trigger else None)

    def _set(self, key: str, value) -> None:
        self.s[key] = value
        config.save(self.s)

    def open_settings(self) -> None:
        if not config.SETTINGS_FILE.exists():
            config.save(self.s)
        QDesktopServices.openUrl(QUrl.fromLocalFile(str(config.SETTINGS_FILE)))

    # ------------------------------------------------------------------ login item (HKCU Run, no admin)

    def login_command(self) -> str:
        exe = sys.executable
        if exe.lower().endswith("python.exe"):
            exe = exe[:-10] + "pythonw.exe"   # no console window at login
        return f'"{exe}" -m heyaside'

    def login_enabled(self) -> bool:
        if sys.platform != "win32":
            return False
        import winreg

        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY) as k:
                winreg.QueryValueEx(k, "HeyAside")
                return True
        except OSError:
            return False

    def set_login(self, on: bool) -> None:
        if sys.platform != "win32":
            return
        import winreg

        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, RUN_KEY, 0, winreg.KEY_SET_VALUE) as k:
            if on:
                winreg.SetValueEx(k, "HeyAside", 0, winreg.REG_SZ, self.login_command())
            else:
                try:
                    winreg.DeleteValue(k, "HeyAside")
                except OSError:
                    pass

    # ------------------------------------------------------------------ audio thread

    def _audio_loop(self) -> None:
        while not self._audio_stop.is_set():
            try:
                frame = self.mic.frames.get(timeout=0.5)
            except Exception:
                continue
            st = self.state
            if st == "idle" or (st == "working" and self.run and self.run.running):
                if self.wake and self.wake.feed(frame):
                    self.sig_wake.emit()
            elif st in ("listening", "followup"):
                self.buffer.append(frame)
                self.sig_level.emit(audio.level(frame))
                r = self.endpointer.feed(frame)
                if r == "done":
                    self.state = "transcribing"
                    self.sig_utterance.emit(np.concatenate(self.buffer))
                elif r == "timeout":
                    self.state = "transcribing"  # parked until the main thread decides
                    self.sig_timeout.emit()
            # speaking / transcribing / starting / muted: frames are dropped (never recorded, never saved)

    # ------------------------------------------------------------------ conversation

    def chime(self) -> None:
        if not self.s["sounds"] or sys.platform != "win32":
            return
        import winsound

        f = r"C:\Windows\Media\Speech On.wav"
        if os.path.exists(f):
            winsound.PlaySound(f, winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT)

    def listen(self, from_wake: bool, wait: float | None = None) -> None:
        if self.s["muted"]:
            return
        self.buffer = []
        self.from_wake = from_wake
        self.endpointer = audio.Endpointer(self.s["silence"], wait if wait is not None else self.s["initialWait"])
        self.state = "listening" if from_wake else "followup"
        self.island.set_phase("listening", "", "user")

    @Slot()
    def on_wake(self) -> None:
        if self.state == "working":
            self.speaker.stop()
        self.chime()
        self.listen(from_wake=True)

    @Slot()
    def poke(self) -> None:
        """Hotkey, tray click or island click: start talking, or cut Jarvis off, or finish your sentence now."""
        if self.state == "speaking":
            self.speaker.stop()
        elif self.state in ("listening", "followup") and self.buffer:
            self.state = "transcribing"
            self.on_utterance(np.concatenate(self.buffer))
        elif self.state in ("idle", "working"):
            self.chime()
            self.listen(from_wake=True)

    @Slot(object)
    def on_utterance(self, pcm: np.ndarray) -> None:
        self.island.set_phase("thinking", "", "user")
        from_wake = self.from_wake

        def work() -> None:
            try:
                text = self.stt(pcm) if self.stt else ""
            except Exception:
                self.log.exception("transcription failed")
                text = ""
            self.sig_text.emit(text, from_wake)

        self.pool.submit(work)

    @Slot()
    def on_timeout(self) -> None:
        if self.from_wake:
            # A bare "Hey Jarvis" and then nothing: answer once, then wait a little longer.
            self.say([random.choice(SUMMONED)], then_listen=12.0)
        else:
            self.end_conversation()

    @Slot(str, bool)
    def on_text(self, text: str, from_wake: bool) -> None:
        cmd = spoken.strip_wake(text)
        self.log.info(f"heard: {len(cmd)} chars")
        if not cmd:
            if from_wake:
                self.say([random.choice(SUMMONED)], then_listen=12.0)
            else:
                self.end_conversation()
            return
        self.island.set_text(cmd, "user")
        busy = bool(self.run and self.run.running)
        if spoken.is_dismissal(cmd) and not busy:
            self.say([random.choice(SIGN_OFF)], then_end=True)
            return
        kind = spoken.intent(cmd, busy)
        if kind == "stop":
            self.cancelled = self.run
            self.run.terminate()
            if self.session:
                self.pool.submit(aside_cli.control, self.cli, ["session", "stop", self.session])
            self.say(["Stopped, sir."], then_end=True)
            return
        if kind == "status":
            self.say([f"I'm {self.last_step[0].lower() + self.last_step[1:]}." if self.last_step else "Still working on it."], then_back_to_work=True)
            return
        if kind in ("steer", "queue") and self.session:
            self.pool.submit(aside_cli.control, self.cli, ["session", "steer" if kind == "steer" else "queue", self.session, cmd])
            self.say(["Understood." if kind == "steer" else "I'll do that next."], then_back_to_work=True)
            return
        self.start_task(cmd)

    def start_task(self, cmd: str) -> None:
        if not self.cli:
            self.island.set_phase("error", "Aside CLI not found", "hint")
            self.say(["I can't reach Aside, sir. The command line tool isn't installed."], then_end=True)
            return
        if self.s.get("jev") and self.try_fast(cmd):
            return
        fresh = time.monotonic() - self.session_at > self.s["newChatAfterMinutes"] * 60
        prompt = cmd + spoken.VOICE_SUFFIX
        if self.session and not fresh:
            args = ["session", "resume", self.session, prompt]
        else:
            self.session = None
            args = []
            if self.s["agentModel"]:
                args += ["--model", self.s["agentModel"]]
            args += ["--permission", self.s["permission"], prompt]
        self.last_step = None
        self.state = "working"
        self.island.set_phase("thinking", "", "step")
        if self.s["spokenReplies"]:
            self.speaker.say([random.choice(ACKS)])
        self.run = aside_cli.AgentRun(self.cli, args, on_session=self.sig_session.emit, on_step=self.sig_step.emit,
                                      on_done=self.sig_done.emit, log=self.log.info)
        try:
            self.run.start()
        except OSError as e:
            self.log.info(f"could not start aside: {e}")
            self.on_done(aside_cli.Result(error=str(e), exit_code=-1))

    def try_fast(self, cmd: str) -> bool:
        """Optional: Aside Phone's `jev quick` answers plain-knowledge questions in ~2 s without an Aside session."""
        jev = self.s["jev"]
        node = "node"

        def work() -> None:
            try:
                p = subprocess.run([node, jev, "quick", cmd], capture_output=True, text=True, timeout=7,
                                   creationflags=aside_cli.NO_WINDOW)
                ans = json.loads(p.stdout.strip().splitlines()[-1]).get("answer") if p.returncode == 0 and p.stdout.strip() else None
            except Exception:
                ans = None
            self.sig_fast.emit(cmd, ans or "")

        self.state = "working"
        self.island.set_phase("thinking", "", "step")
        self.pool.submit(work)
        return True

    @Slot(str, str)
    def on_fast(self, cmd: str, answer: str) -> None:
        if answer:
            self.deliver(answer)
        else:
            saved, self.s["jev"] = self.s["jev"], ""
            try:
                self.start_task(cmd)
            finally:
                self.s["jev"] = saved

    @Slot(str)
    def on_session(self, sid: str) -> None:
        self.session = sid
        self.session_at = time.monotonic()

    @Slot(str)
    def on_step(self, step: str) -> None:
        self.last_step = step
        if self.state == "working":
            self.island.set_phase("thinking", step, "step")

    @Slot(object)
    def on_done(self, r: aside_cli.Result) -> None:
        self.session_at = time.monotonic()
        if self.cancelled is not None and self.cancelled is self.run:
            self.cancelled = None
            return  # you stopped it; "Stopped, sir." was already said
        if r.error and not r.answer:
            self.log.info(f"aside error: {r.error}")
            self.island.set_phase("error", "Aside couldn't finish that", "hint")
            self.say(["Sorry, sir, that didn't go through. It's in Aside if you want to look."], then_end=True)
            return
        self.deliver(r.answer or "Done.")

    def deliver(self, answer: str) -> None:
        text = spoken.spoken_from(answer)
        shown = text if self.s["showJarvisWords"] else ""
        if not self.s["spokenReplies"]:
            self.island.set_phase("done", text, "jarvis")
            QTimer.singleShot(6000, self.end_conversation)
            return
        self.island.set_phase("speaking", shown, "jarvis")
        self.say(spoken.speech_chunks(text), then_listen=float(self.s["followUpSeconds"]))

    # ------------------------------------------------------------------ speaking

    def say(self, chunks: list[str], then_listen: float | None = None, then_end: bool = False, then_back_to_work: bool = False) -> None:
        self._after = ("listen", then_listen) if then_listen else ("end", None) if then_end else ("work", None) if then_back_to_work else ("listen", float(self.s["followUpSeconds"]))
        self.state = "speaking"
        if not self.s["spokenReplies"]:
            self.on_spoken()
            return
        if self.island.phase != "speaking":
            self.island.set_phase("speaking", None, None)
        self.speaker.say(chunks)

    @Slot()
    def on_spoken(self) -> None:
        if self.state != "speaking":
            return  # the acknowledgement finished while Aside works, or speech was cut off mid-listen
        what, wait = getattr(self, "_after", ("end", None))
        if self.run and self.run.running and what != "end":
            self.state = "working"
            self.island.set_phase("thinking", self.last_step or "", "step")
            return
        if what == "listen":
            self.listen(from_wake=False, wait=wait)
        elif what == "work":
            self.state = "working"
            self.island.set_phase("thinking", self.last_step or "", "step")
        else:
            self.end_conversation()

    def end_conversation(self) -> None:
        self.state = "idle"
        self.island.set_phase("hidden")
        if self.wake:
            self.wake.reset()

    # ------------------------------------------------------------------ mute / quit

    def set_muted(self, on: bool) -> None:
        self._set("muted", on)
        if on:
            self.mic.stop()          # really releases the microphone
            self.speaker.stop()
            self.island.set_phase("muted", "Muted", "hint")
            QTimer.singleShot(1500, lambda: self.island.set_phase("hidden") if self.s["muted"] else None)
            self.tray.setToolTip("Hey Aside: muted")
        else:
            self.mic.start()
            self.state = "idle"
            self.tray.setToolTip('Hey Aside: say "Hey Jarvis"')
        self.act_mute.setChecked(on)

    def quit(self) -> None:
        self._audio_stop.set()
        self.mic.stop()
        if self.run:
            self.run.terminate()
        self.app.quit()


def single_instance(app: QApplication) -> QLocalServer | None:
    name = f"heyaside-{os.environ.get('USERNAME') or os.environ.get('USER') or 'user'}"
    probe = QLocalSocket()
    probe.connectToServer(name)
    if probe.waitForConnected(300):
        probe.write(b"poke")
        probe.flush()
        probe.waitForBytesWritten(300)
        return None
    QLocalServer.removeServer(name)
    server = QLocalServer(app)
    server.listen(name)
    return server


def main(argv: list[str]) -> int:
    log = config.setup_logging(echo="--verbose" in argv)
    app = QApplication(argv)
    app.setQuitOnLastWindowClosed(False)
    app.setApplicationName("Hey Aside")
    server = single_instance(app)
    if server is None:
        return 0  # already running; the other copy starts listening
    ctl = Controller(app, log)
    server.newConnection.connect(lambda: (server.nextPendingConnection(), ctl.poke()))
    if "--enable-login" in argv:
        ctl.set_login(True)
    log.info("Hey Aside started")
    return app.exec()
