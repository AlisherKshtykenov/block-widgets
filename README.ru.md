# Block Widgets

[English](README.md) · Русский

Прозрачные виджеты рабочего стола macOS: тонированное стекло, шрифты SF, иконки SF Symbols, кольца прогресса.
Прозрачность рисуется самим приложением (без системного размытия), поэтому при свайпе между столами ничего не мигает.

```bash
./build.sh
open BlockWidgets.app
```

| Виджет | Что показывает |
|---|---|
| Часы | время, дата, неделя, кольцо «прошло от года» |
| Погода | Open-Meteo; место по геопозиции или вручную (меню ▦ → «Указать город…») |
| Система | заряд батареи и загрузка CPU |
| Календарь | день, месяц, сегодня подсвечено |
| Помодоро | 25/5, каждые 4 — 15 мин; клик — старт/пауза, двойной клик — сброс |
| Сеть и SSD | качество интернета (TCP-пинг 1.1.1.1, джиттер, Wi-Fi), скорость ↓↑; SSD KASHTAN: подключён ли, тип связи, место, чтение/запись |
| Git | репозитории в `/Volumes/KASHTAN/projects/*/*`: ветка, изменённые файлы, ↑↓ относительно remote |
| Обучение | прогресс обучения из `~/.local/state/train-widget/status.json` |

## Обучение модели

Скопируйте `python/train_widget.py` в проект:

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

Демо: `python3 python/train_widget.py`.
