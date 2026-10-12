"""The Jarvis island: a black pill at the top centre of the screen, Windows' stand-in for the Mac's Dynamic Island.

Same parts and rules as the Mac version: the blue orb on the left (arc-reactor blue, ice cyan, pale sky; mostly
still, with a slow drift inside, no glow), a state glyph on the right (voice bars, working dots, a check, a muted mic),
and one or two lines of words. Your words are regular weight, Jarvis's medium, working steps dimmed. Size changes ride
springs (width a little bouncy, height calmer), so it blooms open and tucks away instead of popping.
"""
from __future__ import annotations

import math
import time

from PySide6.QtCore import QPointF, QRectF, Qt, QTimer, Signal
from PySide6.QtGui import QColor, QFont, QFontMetricsF, QGuiApplication, QPainter, QPainterPath, QPen, QRadialGradient
from PySide6.QtWidgets import QWidget

BLUE = QColor(11, 134, 255)       # #0B86FF arc-reactor blue
CYAN = QColor(92, 214, 255)       # ice cyan
SKY = QColor(158, 219, 255)       # pale sky highlight
RED = QColor(237, 69, 74)
DIM = QColor(255, 255, 255, 140)

PHASES = ("hidden", "listening", "thinking", "speaking", "done", "error", "muted")


class Spring:
    """Critically-damped-ish spring on one axis; `bounce` 0..0.3 adds a little overshoot when growing."""

    def __init__(self, value: float):
        self.value = self.target = value
        self.v = 0.0

    def step(self, dt: float, duration: float, bounce: float) -> None:
        w = 2 * math.pi / max(duration, 0.05)
        zeta = 1.0 - bounce
        a = -w * w * (self.value - self.target) - 2 * zeta * w * self.v
        self.v += a * dt
        self.value += self.v * dt

    @property
    def settled(self) -> bool:
        return abs(self.value - self.target) < 0.3 and abs(self.v) < 0.3


class Island(QWidget):
    clicked = Signal()

    PAD = 14
    ORB = 20

    def __init__(self):
        super().__init__(None, Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint
                         | Qt.WindowType.Tool | Qt.WindowType.WindowDoesNotAcceptFocus)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating)
        self.setWindowTitle("Hey Aside")
        self.phase = "hidden"
        self.text = ""
        self.text_kind = "user"   # user | jarvis | step | hint
        self.level = 0.0
        self.levels = [0.0] * 5
        self.w = Spring(0.0)
        self.h = Spring(0.0)
        self.alpha = Spring(0.0)
        self.t0 = time.monotonic()
        self.last = self.t0
        self.font_user = QFont("Segoe UI Variable Text", 10)
        self.font_jarvis = QFont("Segoe UI Variable Text", 10, QFont.Weight.DemiBold)
        self.resize(460, 140)
        self._place()
        self.timer = QTimer(self)
        self.timer.timeout.connect(self._tick)
        self.timer.start(16)

    # ------------------------------------------------------------------ public

    def set_phase(self, phase: str, text: str | None = None, kind: str | None = None) -> None:
        self.phase = phase
        if text is not None:
            self.text = text
        if kind is not None:
            self.text_kind = kind
        self._retarget()

    def set_text(self, text: str, kind: str = "user") -> None:
        self.text, self.text_kind = text, kind
        self._retarget()

    def set_level(self, v: float) -> None:
        self.level = max(0.0, min(1.0, v))

    # ------------------------------------------------------------------ layout

    def _place(self) -> None:
        screen = QGuiApplication.primaryScreen().availableGeometry()
        self.move(screen.x() + (screen.width() - self.width()) // 2, screen.y() + 6)

    def _lines(self, width: float) -> list[str]:
        if not self.text:
            return []
        fm = QFontMetricsF(self.font_jarvis if self.text_kind == "jarvis" else self.font_user)
        words, lines, cur = self.text.split(), [], ""
        for w in words:
            trial = (cur + " " + w).strip()
            if fm.horizontalAdvance(trial) > width and cur:
                lines.append(cur)
                cur = w
            else:
                cur = trial
        if cur:
            lines.append(cur)
        if len(lines) > 2:  # keep the newest words, like the Mac ticker
            lines = lines[-2:]
            lines[0] = "…" + lines[0]
        return lines

    def _retarget(self) -> None:
        if self.phase == "hidden":
            self.w.target, self.h.target, self.alpha.target = 120, 0, 0
            return
        self.alpha.target = 1
        text_w = 300
        lines = self._lines(text_w)
        if not lines:
            self.w.target, self.h.target = 220, 38
        elif len(lines) == 1:
            fm = QFontMetricsF(self.font_user)
            self.w.target = max(240, min(420, fm.horizontalAdvance(lines[0]) + self.ORB + 3 * self.PAD + 40))
            self.h.target = 38
        else:
            self.w.target, self.h.target = 420, 78
        if not self.isVisible():
            self.w.value, self.h.value = 120, 20
            self._place()
            self.show()

    # ------------------------------------------------------------------ animation

    def _tick(self) -> None:
        now = time.monotonic()
        dt = min(0.05, now - self.last)
        self.last = now
        grow_w = self.w.target > self.w.value
        grow_h = self.h.target > self.h.value
        self.w.step(dt, 0.44 if grow_w else 0.30, 0.25 if grow_w else 0.0)
        self.h.step(dt, 0.38 if grow_h else 0.26, 0.22 if grow_h else 0.0)
        self.alpha.step(dt, 0.25, 0.0)
        target = self.level if self.phase in ("listening", "speaking") else 0.0
        if self.phase == "speaking":
            target = 0.35 + 0.3 * abs(math.sin(now * 7.3)) * abs(math.sin(now * 3.1))
        self.levels = self.levels[1:] + [0.7 * self.levels[-1] + 0.3 * target]
        if self.phase == "hidden" and self.alpha.value < 0.02 and self.alpha.settled:
            if self.isVisible():
                self.hide()
            return
        self.update()

    # ------------------------------------------------------------------ painting

    def paintEvent(self, _event) -> None:
        w, h = max(0.0, self.w.value), max(0.0, self.h.value)
        if w < 4 or h < 4:
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setOpacity(max(0.0, min(1.0, self.alpha.value)))
        x = (self.width() - w) / 2
        body = QRectF(x, 0, w, h)
        r = min(h / 2, 22)
        path = QPainterPath()
        path.addRoundedRect(body, r, r)
        p.fillPath(path, QColor(0, 0, 0))
        p.setClipPath(path)

        t = time.monotonic() - self.t0
        cy = min(h, 38) / 2
        orb_c = QPointF(x + self.PAD + self.ORB / 2, cy)
        self._orb(p, orb_c, self.ORB / 2, t)
        self._glyph(p, QPointF(x + w - self.PAD - 14, cy), t)

        lines = self._lines(w - self.ORB - 3 * self.PAD - 40)
        if lines and h > 30:
            font = self.font_jarvis if self.text_kind == "jarvis" else self.font_user
            p.setFont(font)
            p.setPen(DIM if self.text_kind in ("step", "hint") else QColor(255, 255, 255))
            fm = QFontMetricsF(font)
            tx = x + self.PAD + self.ORB + 10
            if len(lines) == 1:
                p.drawText(QPointF(tx, cy + fm.ascent() / 2 - 1), lines[0])
            else:
                y0 = (h - len(lines) * fm.height()) / 2 + fm.ascent()
                for i, line in enumerate(lines):
                    p.drawText(QPointF(tx, y0 + i * fm.height()), line)
        p.end()

    def _orb(self, p: QPainter, c: QPointF, r: float, t: float) -> None:
        if self.phase == "muted":
            p.setBrush(QColor(110, 110, 115))
            p.setPen(Qt.PenStyle.NoPen)
            p.drawEllipse(c, r, r)
            p.setPen(QPen(QColor(30, 30, 30), 2))
            p.drawLine(QPointF(c.x() - r * 0.6, c.y() + r * 0.6), QPointF(c.x() + r * 0.6, c.y() - r * 0.6))
            return
        # Mostly still, with a slow drift inside: no swelling, no glow.
        drift = QPointF(c.x() + r * 0.28 * math.sin(t * 0.55), c.y() + r * 0.22 * math.cos(t * 0.43))
        g = QRadialGradient(drift, r * 1.25)
        g.setColorAt(0.0, SKY)
        g.setColorAt(0.35, CYAN)
        g.setColorAt(0.75, BLUE)
        g.setColorAt(1.0, QColor(4, 60, 140))
        p.setBrush(g)
        p.setPen(Qt.PenStyle.NoPen)
        p.drawEllipse(c, r, r)

    def _glyph(self, p: QPainter, c: QPointF, t: float) -> None:
        p.setPen(Qt.PenStyle.NoPen)
        if self.phase in ("listening", "speaking"):
            p.setBrush(QColor(255, 255, 255) if self.phase == "speaking" else CYAN)
            for i, v in enumerate(self.levels):
                bh = 4 + 14 * v
                p.drawRoundedRect(QRectF(c.x() - 12 + i * 5.5, c.y() - bh / 2, 3, bh), 1.5, 1.5)
        elif self.phase == "thinking":
            for i in range(3):
                a = 0.35 + 0.65 * max(0.0, math.sin(t * 4 - i * 0.7))
                col = QColor(CYAN)
                col.setAlphaF(a)
                p.setBrush(col)
                p.drawEllipse(QPointF(c.x() - 7 + i * 7, c.y()), 2.4, 2.4)
        elif self.phase == "done":
            p.setPen(QPen(CYAN, 2.2, Qt.PenStyle.SolidLine, Qt.PenCapStyle.RoundCap))
            p.drawPolyline([QPointF(c.x() - 6, c.y()), QPointF(c.x() - 2, c.y() + 4), QPointF(c.x() + 6, c.y() - 4)])
        elif self.phase == "error":
            p.setBrush(RED)
            p.drawEllipse(c, 4, 4)
        elif self.phase == "muted":
            p.setBrush(RED)
            p.drawEllipse(c, 4, 4)

    def mousePressEvent(self, _event) -> None:
        self.clicked.emit()
