import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
qt = pytest.importorskip("PySide6.QtWidgets")


def test_island_opens_and_closes():
    from heyaside.island import Island

    app = qt.QApplication.instance() or qt.QApplication([])
    i = Island()
    i.set_phase("listening", "what's on my calendar tomorrow", "user")
    assert i.isVisible() and i.w.target > 200
    i.set_text("one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twenty-one twenty-two", "jarvis")
    assert i.h.target > 38
    i.set_phase("hidden")
    assert i.alpha.target == 0
    app.processEvents()
