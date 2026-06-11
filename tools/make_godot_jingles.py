#!/usr/bin/env python3
"""Запекает джинглы web-версии (src/audio.js chime) в wav для Godot.

gate [660,990,1320], upgrade [523,659,784,1047], trash [294,220,147] —
triangle, нота 0.36 с, старт +50 мс, env: linear 0->0.26 за 10 мс,
затем exp до 0.0004 к 0.32 с. Выход: godot/assets/audio/chime_*.wav
"""
import wave
from pathlib import Path

import numpy as np

SR = 44100
OUT = Path(__file__).resolve().parent.parent / "godot" / "assets" / "audio"
JINGLES = {
    "gate": [660, 990, 1320],
    "upgrade": [523, 659, 784, 1047],
    "trash": [294, 220, 147],
}


def triangle(freq, n):
    t = np.arange(n) / SR
    return 2.0 / np.pi * np.arcsin(np.sin(2 * np.pi * freq * t))


def envelope(n):
    t = np.arange(n) / SR
    env = np.zeros(n)
    a = t < 0.01
    env[a] = 0.26 * t[a] / 0.01
    d = ~a
    # exponentialRamp 0.26 -> 0.0004 на интервале 0.01..0.32
    k = np.log(0.0004 / 0.26) / (0.32 - 0.01)
    env[d] = 0.26 * np.exp(k * (t[d] - 0.01))
    env[t >= 0.36] = 0.0
    return env


def save(path, data):
    data = np.clip(data, -1, 1)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes((data * 32767).astype(np.int16).tobytes())


OUT.mkdir(parents=True, exist_ok=True)
for name, notes in JINGLES.items():
    total = int(SR * (0.05 * (len(notes) - 1) + 0.38))
    mix = np.zeros(total)
    note_n = int(SR * 0.37)
    for i, f in enumerate(notes):
        start = int(SR * 0.05 * i)
        mix[start:start + note_n] += triangle(f, note_n) * envelope(note_n)
    out = OUT / f"chime_{name}.wav"
    save(out, mix)
    rms = float(np.sqrt(np.mean(mix ** 2)))
    print(f"OK {out.name}: {total / SR:.2f}s rms={rms:.3f}")
