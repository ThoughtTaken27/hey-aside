"""The conversation state machine end to end, with fakes for the mic, models, voice and Aside CLI."""
import os
import sys
import time
from pathlib import Path

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
qt = pytest.importorskip("PySide6.QtWidgets")

FAKE_CLI = r'''
import sys, time
E = "\x1b"
prompt = sys.argv[-1]
print(f"{E}[2mcreated new session: ses_TEST1{E}[0m", flush=True)
time.sleep(0.2)
print(f"{E}[32mrepl{E}[0m(code: {E}[32m'x'{E}[39m, title: {E}[32m'Opening the calendar'{E}[39m){E}[2m [call_1]{E}[0m", flush=True)
time.sleep(0.2)
print("You have two meetings tomorrow, sir.\n---\n- Standup 9 am\n- Review 2 pm", flush=True)
'''


@pytest.fixture()
def ctl(tmp_path, monkeypatch):
    from heyaside import aside_cli, app, audio, config

    monkeypatch.setattr(config, "SETTINGS_FILE", tmp_path / "settings.json")
    monkeypatch.setattr(config, "LOG_DIR", tmp_path / "logs")
    monkeypatch.setattr(audio.Mic, "start", lambda self: None)
    monkeypatch.setattr(audio, "ensure_wake_models", lambda: None)
    monkeypatch.setattr(audio, "WakeWord", lambda *a, **k: type("W", (), {"feed": lambda s, f: False, "reset": lambda s: None})())
    import heyaside.stt as stt

    monkeypatch.setattr(stt, "Transcriber", lambda *a, **k: (lambda pcm: "Hey Jarvis, what's on my calendar tomorrow?"))
    fake = tmp_path / "fake_aside.py"
    fake.write_text(FAKE_CLI)
    orig_start = aside_cli.AgentRun.start

    def start(self):
        self.cli, self.args = sys.executable, [str(fake), *self.args]
        orig_start(self)

    monkeypatch.setattr(aside_cli.AgentRun, "start", start)
    monkeypatch.setattr(aside_cli, "find_cli", lambda configured="": "fake-aside")
    config.save({**config.DEFAULTS, "spokenReplies": False})
    qapp = qt.QApplication.instance() or qt.QApplication([])
    c = app.Controller(qapp, config.setup_logging())
    deadline = time.time() + 10
    while c.state == "starting" and time.time() < deadline:
        qapp.processEvents()
        time.sleep(0.02)
    yield c, qapp
    c._audio_stop.set()


def pump(qapp, until, timeout=10):
    deadline = time.time() + timeout
    while not until() and time.time() < deadline:
        qapp.processEvents()
        time.sleep(0.02)
    return until()


def test_request_runs_in_aside_and_answer_is_delivered(ctl):
    c, qapp = ctl
    assert c.state == "idle"
    steps = []
    c.sig_step.connect(steps.append)
    c.on_text("Hey Jarvis, what's on my calendar tomorrow?", True)
    assert c.state == "working"
    assert pump(qapp, lambda: c.island.phase == "done")
    assert c.session == "ses_TEST1"
    assert steps == ["Opening the calendar"]
    assert "two meetings tomorrow" in c.island.text
    # the prompt carried the voice-mode instructions
    assert c.run.args[-1].endswith(c.run.args[-1][-20:]) and "Voice mode" in c.run.args[-1]


def test_follow_up_resumes_the_same_chat(ctl):
    c, qapp = ctl
    c.on_text("what's on my calendar", True)
    assert pump(qapp, lambda: c.island.phase == "done")
    c.on_text("and the day after?", False)
    assert c.run.args[1:4] == ["session", "resume", "ses_TEST1"]
    assert pump(qapp, lambda: c.island.phase == "done")


def test_thanks_ends_the_conversation(ctl):
    c, qapp = ctl
    c.on_text("thanks", False)
    assert pump(qapp, lambda: c.state == "idle")
    assert c.island.phase == "hidden"


def test_stop_while_busy(ctl):
    c, qapp = ctl
    c.on_text("open my calendar", True)
    assert c.run.running
    c.on_text("stop", False)
    assert pump(qapp, lambda: not c.run.running)
    assert pump(qapp, lambda: c.state == "idle")


def test_bare_wake_word_asks_again(ctl):
    c, qapp = ctl
    c.from_wake = True
    c.on_text("Hey Jarvis", True)
    assert pump(qapp, lambda: c.state == "followup")


def test_settings_file_with_bom_is_read(tmp_path, monkeypatch):
    from heyaside import config

    f = tmp_path / "settings.json"
    f.write_bytes(b"\xef\xbb\xbf" + b'{"jev": "C:\\\\x\\\\jev"}')
    monkeypatch.setattr(config, "SETTINGS_FILE", f)
    assert config.load()["jev"] == "C:\\x\\jev"
