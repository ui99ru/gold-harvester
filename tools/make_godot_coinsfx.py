#!/usr/bin/env python3
"""Нарезает 4 wav-клинка для Godot из банка src/coinsfx.js (ogg base64).

Использование: python tools/make_godot_coinsfx.py
Требует ffmpeg в PATH. Результат: godot/assets/audio/clink_1..4.wav
"""
import base64
import re
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "src" / "coinsfx.js"
OUT_DIR = ROOT / "godot" / "assets" / "audio"
CLIP_DUR = 0.13
N_CLIPS = 4

text = SRC.read_text(encoding="utf-8")
b64 = re.search(r"base64,([A-Za-z0-9+/=]+)'", text).group(1)
offs = [float(x) for x in re.search(r"COIN_OFFS = \[([^\]]+)\]", text).group(1).split(",")]

OUT_DIR.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory() as td:
    ogg = Path(td) / "bank.ogg"
    ogg.write_bytes(base64.b64decode(b64))
    for i in range(N_CLIPS):
        out = OUT_DIR / f"clink_{i + 1}.wav"
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error",
             "-ss", str(offs[i]), "-t", str(CLIP_DUR), "-i", str(ogg),
             "-ar", "44100", "-ac", "1", "-sample_fmt", "s16",
             "-af", "afade=t=out:st=%.3f:d=0.02" % (CLIP_DUR - 0.02),
             str(out)],
            check=True)
        print(f"OK {out.relative_to(ROOT)}")
