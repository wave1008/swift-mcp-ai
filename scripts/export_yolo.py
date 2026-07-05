# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = ["ultralytics>=8.3", "coremltools>=8.0", "numpy<2"]
# ///
"""YOLO を Core ML (.mlpackage) に変換して Models/ に配置する。

使い方:
    uv run scripts/export_yolo.py [モデル名]

モデル名の例: yolo11n (既定), yolo11s, yolo11m, yolov8n など。
nms=True で NMS を組み込み、Swift 側は VNRecognizedObjectObservation を
そのまま受け取れる。
"""

import shutil
import sys
from pathlib import Path

from ultralytics import YOLO

model_name = sys.argv[1] if len(sys.argv) > 1 else "yolo11n"
repo_root = Path(__file__).resolve().parent.parent
models_dir = repo_root / "Models"
models_dir.mkdir(exist_ok=True)

model = YOLO(f"{model_name}.pt")
exported = Path(model.export(format="coreml", nms=True, half=True, imgsz=640))

dest = models_dir / exported.name
if dest.exists():
    shutil.rmtree(dest)
shutil.move(str(exported), dest)
print(f"exported: {dest}")
