<div align="center">

# ▦ Block Widgets

**Transparent glass desktop widgets for macOS, written in a single Swift file and built without an Xcode project.**

![Swift](https://img.shields.io/badge/Swift-F05138?logo=swift&logoColor=white)
![macOS 13+](https://img.shields.io/badge/macOS-13%2B-000000?logo=apple&logoColor=white)
![AppKit](https://img.shields.io/badge/AppKit-native-1f6feb)
![No dependencies](https://img.shields.io/badge/dependencies-0-2ea44f)

English · [Русский](README.ru.md)

</div>

---

Block Widgets puts a grid of tinted-glass cards on your desktop: SF fonts, SF Symbols and progress rings.
The app draws the transparency itself instead of using the system blur, so nothing flickers when you swipe between Spaces.

## Widgets

| Widget | What it shows |
|---|---|
| 🕐 **Clock** | time, date, week number, and a "year elapsed" ring |
| 🌤 **Weather** | [Open-Meteo](https://open-meteo.com), using your location or a city you choose (menu ▦ → *Set city…*) |
| 🔋 **System** | battery charge and CPU load |
| 📅 **Calendar** | month view with today highlighted |
| 🍅 **Pomodoro** | 25/5 with a 15-minute break after every 4 rounds. Click to start or pause, double-click to reset |
| 🌐 **Network & SSD** | connection quality (TCP ping to 1.1.1.1, jitter, Wi-Fi), ↓↑ speed, and the external SSD's link type, free space and read/write |
| 🌿 **Git** | for every repo in `projects/*/*`: branch, changed files, and ↑↓ against the remote |
| 🧠 **Training** | live progress of an ML training run (see below) |

## Quick start

```bash
./build.sh            # compiles Sources/main.swift with swiftc, no Xcode project needed
open BlockWidgets.app
```

## Training widget

Drop [`python/train_widget.py`](python/train_widget.py) into any ML project and report progress from your training loop:

```python
from train_widget import TrainWidget

tw = TrainWidget("resnet18-cifar10", epochs=20)
for epoch in range(1, 21):
    for step, batch in enumerate(loader, 1):
        ...
        tw.update(epoch=epoch, step=step, steps=len(loader), loss=loss.item())
    tw.update(epoch=epoch, val_loss=val_loss, metric=("acc", acc))
tw.done()
```

The widget reads `~/.local/state/train-widget/status.json` and shows the epoch, step, loss and metric as they update.
To try it without a model, run `python3 python/train_widget.py`.

## How it works

- Everything is one file, [`Sources/main.swift`](Sources/main.swift) (~1.2k lines of AppKit), compiled by [`build.sh`](build.sh) with plain `swiftc`.
- The widgets live in a borderless window at desktop level that is shown on every Space.
- Data comes from system frameworks only: IOKit, CoreWLAN, CoreLocation and Network. The one outside service is Open-Meteo, which needs no API key.
