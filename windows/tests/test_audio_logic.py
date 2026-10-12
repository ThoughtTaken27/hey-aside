import numpy as np

from heyaside import hotkey
from heyaside.audio import FRAME, RATE, Endpointer, level


def frames(amplitude, seconds):
    n = int(seconds * RATE / FRAME)
    rng = np.random.default_rng(1)
    return [amplitude * rng.standard_normal(FRAME).astype(np.float32) for _ in range(n)]


def run(ep, seq):
    out = None
    for f in seq:
        out = ep.feed(f)
        if out in ("done", "timeout"):
            return out
    return out


def test_sentence_ends_after_silence():
    ep = Endpointer(silence=1.2, initial_wait=8)
    assert run(ep, frames(0.001, 0.5) + frames(0.1, 1.5) + frames(0.001, 1.5)) == "done"


def test_short_pause_does_not_end_sentence():
    ep = Endpointer(silence=1.2, initial_wait=8)
    assert run(ep, frames(0.001, 0.5) + frames(0.1, 1.0) + frames(0.001, 0.6) + frames(0.1, 0.5)) == "speaking"


def test_nothing_said_times_out():
    ep = Endpointer(silence=1.2, initial_wait=2)
    assert run(ep, frames(0.001, 3)) == "timeout"


def test_level_is_bounded():
    assert level(np.ones(FRAME, dtype=np.float32)) == 1.0
    assert level(np.zeros(FRAME, dtype=np.float32)) == 0.0


def test_hotkey_parsing():
    mods, vk = hotkey.parse("ctrl+alt+j")
    assert vk == ord("J") and mods & 0x3 == 0x3
    assert hotkey.parse("ctrl+alt+space")[1] == 0x20
    assert hotkey.parse("hyper+j") is None
