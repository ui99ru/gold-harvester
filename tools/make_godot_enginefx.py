#!/usr/bin/env python3
"""Запекает бесшовный луп двигателя из модели web-версии (src/audio.js).

Модель: sawtooth 78 Гц «корпус» через lowpass 240 + путты (square ~82 Гц
через lowpass 700 c env 4 мс -> 70 мс) + шум-клаттер bandpass 2200 Q0.8 +
ВЧ-шум highpass 9000. Темп путтов ~8/с (sp=0.5), джиттер ±18% детерминирован
и нормирован — последний интервал замыкает луп точно. Шов: кроссфейд 40 мс.
Рантайм: pitch_scale 0.9+0.5sp, volume 0.55+0.45sp (game_audio.gd).
Выход: godot/assets/audio/engine_loop.wav (~3 c, 44.1 кГц mono)
"""
import wave
from pathlib import Path

import numpy as np

SR = 44100
DUR = 3.0
RATE = 8.0          # путтов/с при sp=0.5
PITCH = 82.0        # 74 + 0.5*16
BED_LEVEL = 0.16    # корпус относительно путтов (web 0.12/0.9 при sp=0.5)
OUT = Path(__file__).resolve().parent.parent / "godot" / "assets" / "audio" / "engine_loop.wav"

rng = np.random.default_rng(20260611)


def biquad_lowpass(x, fc, q=0.7071):
    return _biquad(x, *_lp_coef(fc, q))


def _lp_coef(fc, q):
    w = 2 * np.pi * fc / SR
    alpha = np.sin(w) / (2 * q)
    cw = np.cos(w)
    b0 = (1 - cw) / 2
    b1 = 1 - cw
    b2 = (1 - cw) / 2
    a0 = 1 + alpha
    a1 = -2 * cw
    a2 = 1 - alpha
    return b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0


def _bp_coef(fc, q):
    w = 2 * np.pi * fc / SR
    alpha = np.sin(w) / (2 * q)
    cw = np.cos(w)
    a0 = 1 + alpha
    return alpha / a0, 0.0, -alpha / a0, -2 * cw / a0, (1 - alpha) / a0


def _hp_coef(fc, q):
    w = 2 * np.pi * fc / SR
    alpha = np.sin(w) / (2 * q)
    cw = np.cos(w)
    b0 = (1 + cw) / 2
    a0 = 1 + alpha
    return b0 / a0, -(1 + cw) / a0, b0 / a0, -2 * cw / a0, (1 - alpha) / a0


def _biquad(x, b0, b1, b2, a1, a2):
    y = np.zeros_like(x)
    x1 = x2 = y1 = y2 = 0.0
    for i, xi in enumerate(x):
        yi = b0 * xi + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1 = x1, xi
        y2, y1 = y1, yi
        y[i] = yi
    return y


def putt(pitch, amp):
    """Один «туп» зажигания: square+lp700 с env, клаттер bp2200, ВЧ hp9000."""
    n = int(SR * 0.1)
    t = np.arange(n) / SR
    sq = np.sign(np.sin(2 * np.pi * pitch * t))
    env = np.where(
        t < 0.004,
        0.0001 * (amp * 0.9 / 0.0001) ** (t / 0.004),
        amp * 0.9 * (0.0006 / (amp * 0.9)) ** np.clip((t - 0.004) / 0.066, 0, 1))
    body = _biquad(sq * env, *_lp_coef(700, 0.7071))

    nb = (rng.random(900) * 2 - 1) * (1 - np.arange(900) / 900) ** 3
    clatter = _biquad(nb, *_bp_coef(2200, 0.8)) * amp * 0.5

    n2 = (rng.random(200) * 2 - 1) * (1 - np.arange(200) / 200) ** 4
    hiss = _biquad(n2, *_hp_coef(9000, 0.7071)) * amp * 0.18

    out = body.copy()
    out[:900] += clatter
    out[:200] += hiss
    return out


total = int(SR * DUR)
mix = np.zeros(total + SR)  # хвост последнего путта заворачивается в начало

# Корпус: sawtooth 82 Гц (целое число периодов на луп -> бесшовно) через lp240
periods = round(PITCH * DUR)
bed_freq = periods / DUR
tt = np.arange(total) / SR
saw = 2.0 * ((tt * bed_freq) % 1.0) - 1.0
bed = _biquad(saw, *_lp_coef(240, 0.7071)) * BED_LEVEL

# Путты: интервалы с джиттером, нормированные ровно на DUR
n_putts = int(RATE * DUR)
ivals = 1.0 + (rng.random(n_putts) - 0.5) * 0.36
ivals *= DUR / ivals.sum()
t0 = 0.0
for iv in ivals:
    s = int(t0 * SR)
    p = putt(PITCH + (rng.random() - 0.5) * 3, 0.8 + rng.random() * 0.4)
    mix[s:s + p.size] += p
    t0 += iv

# Завернуть хвост за DUR в начало (луп) + кроссфейд 40 мс
mix[:SR] += mix[total:total + SR]
loop = mix[:total] + bed
xf = int(SR * 0.04)
fade = np.linspace(0, 1, xf)
loop[:xf] = loop[:xf] * fade + loop[-xf:] * (1 - fade)
loop = loop[:total - xf]  # убрать дублированный хвост шва

peak = np.max(np.abs(loop))
loop = loop / peak * 0.85

OUT.parent.mkdir(parents=True, exist_ok=True)
with wave.open(str(OUT), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(SR)
    w.writeframes((np.clip(loop, -1, 1) * 32767).astype(np.int16).tobytes())
rms = float(np.sqrt(np.mean(loop ** 2)))
print(f"OK {OUT.name}: {loop.size / SR:.2f}s rms={rms:.3f} peak->0.85")
