"""Jarvis's voice: Ryan (en-GB-RyanNeural) through Microsoft Edge's read-aloud service via `edge-tts`,
the same voice the macOS app uses. That service is unofficial and Microsoft changes it from time to time (an
October 2026 change returns HTTP 403 until edge-tts ships an update). Whenever it fails, Windows' own British
male voice (Microsoft George, if installed) speaks instead, and Ryan is retried after a few minutes.

Sentences are synthesized one at a time in the background and played in order, so the first words start
quickly. Only the text being spoken is sent to the speech service.
"""
from __future__ import annotations

import asyncio
import itertools
import tempfile
import threading
import time
from pathlib import Path

from PySide6.QtCore import QObject, QUrl, Signal, Slot
from PySide6.QtMultimedia import QAudioOutput, QMediaPlayer

_counter = itertools.count()
TMP = Path(tempfile.gettempdir()) / "heyaside-tts"


LEGACY_HOST = "speech.platform.bing.com"
EDGE_WSS = "wss://api.msedgeservices.com/tts/cognitiveservices/websocket/v1?Ocp-Apim-Subscription-Key="


def use_current_edge_host() -> bool:
    """Since October 2026 the old host answers synthesis with 403; Edge itself now uses
    api.msedgeservices.com with the same public client id (rany2/edge-tts#491). Point
    edge-tts 7.2.8 there. Does nothing once an edge-tts release already uses a new host."""
    from edge_tts import communicate, constants

    if LEGACY_HOST not in communicate.WSS_URL:
        return False
    url = EDGE_WSS + constants.TRUSTED_CLIENT_TOKEN
    constants.WSS_URL = communicate.WSS_URL = url
    return True


def synthesize(text: str, voice: str, rate: str) -> bytes:
    import edge_tts

    use_current_edge_host()

    async def run() -> bytes:
        out = bytearray()
        async for chunk in edge_tts.Communicate(text, voice, rate=rate).stream():
            if chunk.get("type") == "audio":
                out += chunk["data"]
        return bytes(out)

    return asyncio.run(run())


class Speaker(QObject):
    started = Signal()
    finished = Signal()
    _ready = Signal(int, str)  # generation, file path ("" = synthesis failed)

    def __init__(self, voice: str, rate: str, log):
        super().__init__()
        self.voice, self.rate, self.log = voice, rate, log
        self.player = QMediaPlayer()
        self.out = QAudioOutput()
        self.player.setAudioOutput(self.out)
        self.player.mediaStatusChanged.connect(self._status)
        self._ready.connect(self._enqueue)
        self.gen = 0
        self.pending: list[str] = []
        self.expected = 0
        self.received = 0
        self.playing = False
        self._fallback = None
        self.edge_down_until = 0.0
        TMP.mkdir(parents=True, exist_ok=True)

    @property
    def busy(self) -> bool:
        return self.playing or self.received < self.expected

    def say(self, chunks: list[str]) -> None:
        self._halt()  # replacing what is playing is not "finished": no signal
        chunks = [c for c in chunks if c.strip()]
        if not chunks:
            self.finished.emit()
            return
        gen = self.gen
        self.expected, self.received = len(chunks), 0
        self.started.emit()

        def work() -> None:
            for c in chunks:
                if gen != self.gen:
                    return
                if time.monotonic() < self.edge_down_until:
                    self._ready.emit(gen, "!" + c)
                    continue
                try:
                    data = synthesize(c, self.voice, self.rate)
                    f = TMP / f"say-{next(_counter)}.mp3"
                    f.write_bytes(data)
                    self._ready.emit(gen, str(f) if data else "")
                except Exception as e:  # network down, service changed, ...
                    self.log.info(f"tts: edge voice failed ({e.__class__.__name__}: {str(e)[:80]}); using the Windows voice for 5 min")
                    self.edge_down_until = time.monotonic() + 300
                    self._ready.emit(gen, "!" + c)

        threading.Thread(target=work, daemon=True).start()

    @Slot(int, str)
    def _enqueue(self, gen: int, path: str) -> None:
        if gen != self.gen:
            return
        self.received += 1
        self.pending.append(path)
        if not self.playing:
            self._next()

    def _next(self) -> None:
        while self.pending:
            item = self.pending.pop(0)
            if item.startswith("!"):
                self._speak_fallback(item[1:])
                return
            if item:
                self.playing = True
                self.player.setSource(QUrl.fromLocalFile(item))
                self.player.play()
                return
        self.playing = False
        if self.received >= self.expected:
            self.finished.emit()

    def _status(self, status) -> None:
        if status in (QMediaPlayer.MediaStatus.EndOfMedia, QMediaPlayer.MediaStatus.InvalidMedia):
            self.playing = False
            self._next()

    def _speak_fallback(self, text: str) -> None:
        try:
            from PySide6.QtTextToSpeech import QTextToSpeech

            if self._fallback is None:
                self._fallback = QTextToSpeech()
                self._pick_british_voice(self._fallback)
                self._fallback.stateChanged.connect(
                    lambda s: (setattr(self, "playing", False), self._next()) if s == QTextToSpeech.State.Ready else None)
            self.playing = True
            self._fallback.say(text)
        except Exception:
            self.playing = False
            self._next()

    def _halt(self) -> bool:
        busy = self.busy
        self.gen += 1
        self.pending.clear()
        self.expected = self.received = 0
        self.playing = False
        self.player.stop()
        if self._fallback is not None:
            self._fallback.stop()
        return busy

    @staticmethod
    def _pick_british_voice(engine) -> None:
        """Prefer an en-GB male voice (Windows ships "Microsoft George"), else any en-GB, else the default."""
        from PySide6.QtCore import QLocale
        from PySide6.QtTextToSpeech import QVoice

        voices = engine.availableVoices()
        gb = [v for v in voices if v.locale() == QLocale(QLocale.Language.English, QLocale.Territory.UnitedKingdom)]
        pick = next((v for v in gb if "george" in v.name().lower()), None) \
            or next((v for v in gb if v.gender() == QVoice.Gender.Male), None) or (gb[0] if gb else None)
        if pick is not None:
            engine.setVoice(pick)
        engine.setRate(0.1)

    def stop(self) -> None:
        """Cut Jarvis off (click, hotkey, wake word): counts as finished."""
        if self._halt():
            self.finished.emit()
