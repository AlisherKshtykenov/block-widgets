"""Report training progress to the «Обучение» desktop widget.

No dependencies. Copy this file into your project (or add its folder to PYTHONPATH).

    from train_widget import TrainWidget

    tw = TrainWidget("resnet18-cifar10", epochs=20)
    for epoch in range(1, 21):
        for step, batch in enumerate(loader, 1):
            ...
            tw.update(epoch=epoch, step=step, steps=len(loader), loss=loss.item())
        tw.update(epoch=epoch, val_loss=val_loss, metric=("acc", acc))
    tw.done()

The widget reads ~/.local/state/train-widget/status.json; a run that has not
reported for 2 minutes is shown as stopped.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path

PATH = Path.home() / ".local/state/train-widget/status.json"
MAX_HISTORY = 120


class TrainWidget:
    def __init__(self, name: str, epochs: int, every: float = 2.0):
        self.every = every
        self._last_write = 0.0
        self.state: dict = {
            "name": name,
            "epoch": 1,
            "epochs": epochs,
            "started": time.time(),
            "updated": time.time(),
            "done": False,
            "history": [],
        }
        self._write()

    def update(self, epoch=None, step=None, steps=None, loss=None, val_loss=None, metric=None):
        s = self.state
        new_epoch = epoch is not None and epoch != s.get("epoch")
        for key, value in (("epoch", epoch), ("step", step), ("steps", steps), ("val_loss", val_loss)):
            if value is not None:
                s[key] = value
        if metric is not None:
            s["metric"], s["metric_value"] = metric[0], float(metric[1])
        if loss is not None:
            s["loss"] = float(loss)
            h = s["history"]
            h.append(float(loss))
            if len(h) > MAX_HISTORY:  # keep the curve's shape: halve the resolution
                s["history"] = h[::2]
        now = time.time()
        if new_epoch or val_loss is not None or now - self._last_write >= self.every:
            self._write()

    def done(self):
        self.state["done"] = True
        self._write()

    def _write(self):
        self.state["updated"] = time.time()
        self._last_write = self.state["updated"]
        PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.state))
        os.replace(tmp, PATH)  # atomic: the widget never sees a half-written file


if __name__ == "__main__":  # demo: python train_widget.py
    import math
    import random

    tw = TrainWidget("demo-model", epochs=5)
    for e in range(1, 6):
        for s in range(1, 51):
            loss = 2.0 * math.exp(-(e - 1 + s / 50) / 1.5) + random.uniform(0, 0.08)
            tw.update(epoch=e, step=s, steps=50, loss=loss)
            time.sleep(0.2)
        tw.update(epoch=e, val_loss=loss * 1.1, metric=("acc", 1 - loss / 2.2))
    tw.done()
