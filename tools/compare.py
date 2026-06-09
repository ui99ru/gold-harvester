#!/usr/bin/env python3
"""Опора 4: метрики реф<->рендер + side-by-side композит + scorecard.

Использование:
    python tools/compare.py <ref_keyframe.png> <shot.png> [--label name]

- Реф кропается к игровой области (y 0..GAME_H), оверлеи рекламы маскируются.
- Рендер кропается так же. Обе картинки 720 шириной -> сравнение 1:1.
- Метрики: палитра грунта/золота (mean RGB + дельта), доля золота, средняя
  яркость, % пересвета. Пишется out/cmp_<label>.png и строка в out/report.md.
"""
import sys, os
from PIL import Image, ImageDraw
import numpy as np

try:
    sys.stdout.reconfigure(encoding='utf-8')   # Δ/кириллица в cp1251-консоли Windows
except Exception:
    pass

GAME_H = 1080            # низ рекламного баннера; игра выше
# оверлеи рекламы (x0,y0,x1,y1) в координатах исходного 720x1280 кадра
OVERLAYS = [(460, 968, 704, 1046), (0, 1024, 132, 1078), (652, 0, 720, 66)]
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_game(path):
    im = Image.open(path).convert('RGB')
    if im.size[1] >= GAME_H:
        im = im.crop((0, 0, im.size[0], GAME_H))
    return im


def masks(rgb):
    """rgb: HxWx3 uint8. Возврат: (gold_mask, ground_mask, luma 0..1, valid)."""
    h, w, _ = rgb.shape
    hsv = np.asarray(Image.fromarray(rgb).convert('HSV'), dtype=np.float32)
    H, S, V = hsv[..., 0], hsv[..., 1], hsv[..., 2]   # 0..255
    valid = np.ones((h, w), bool)
    for x0, y0, x1, y1 in OVERLAYS:
        y0c, y1c = min(y0, h), min(y1, h)
        valid[y0c:y1c, x0:x1] = False
    gold = (H >= 12) & (H <= 48) & (S > 80) & (V > 80) & valid       # тёплое золото (по hue)
    ground = (~gold) & (H >= 150) & (H <= 220) & (S > 25) & (V > 40) & valid   # сине-фиолетовый грунт (по hue, насыщенный)
    luma = (0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]) / 255.0
    return gold, ground, luma, valid


def mean_rgb(rgb, m):
    if m.sum() < 50:
        return np.array([0, 0, 0], float)
    return rgb[m].mean(axis=0)


def metrics(im):
    rgb = np.asarray(im, dtype=np.uint8)
    gold, ground, luma, valid = masks(rgb)
    n = max(valid.sum(), 1)
    return {
        'gold_rgb': mean_rgb(rgb, gold),
        'ground_rgb': mean_rgb(rgb, ground),
        'gold_frac': gold.sum() / n,
        'luma': luma[valid].mean(),
        'overexp': (luma[valid] > 0.92).mean(),
    }


def fmt_rgb(c):
    return f"({c[0]:3.0f},{c[1]:3.0f},{c[2]:3.0f})"


def main():
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(1)
    ref_p, shot_p = sys.argv[1], sys.argv[2]
    label = sys.argv[sys.argv.index('--label') + 1] if '--label' in sys.argv else \
        os.path.splitext(os.path.basename(shot_p))[0]

    ref, shot = load_game(ref_p), load_game(shot_p)
    if shot.size != ref.size:
        shot = shot.resize(ref.size)
    mr, ms = metrics(ref), metrics(shot)

    d_gold = float(np.linalg.norm(mr['gold_rgb'] - ms['gold_rgb']))
    d_ground = float(np.linalg.norm(mr['ground_rgb'] - ms['ground_rgb']))
    d_luma = abs(mr['luma'] - ms['luma'])
    d_goldfrac = abs(mr['gold_frac'] - ms['gold_frac'])
    score = d_gold + d_ground + 300 * d_luma + 200 * d_goldfrac

    lines = [
        f"### {label}",
        "| metric | REF | SHOT | Δ |",
        "|---|---|---|---|",
        f"| ground RGB | {fmt_rgb(mr['ground_rgb'])} | {fmt_rgb(ms['ground_rgb'])} | {d_ground:.1f} |",
        f"| gold RGB | {fmt_rgb(mr['gold_rgb'])} | {fmt_rgb(ms['gold_rgb'])} | {d_gold:.1f} |",
        f"| gold frac | {mr['gold_frac']:.3f} | {ms['gold_frac']:.3f} | {d_goldfrac:.3f} |",
        f"| mean luma | {mr['luma']:.3f} | {ms['luma']:.3f} | {d_luma:.3f} |",
        f"| overexp % | {100*mr['overexp']:.1f} | {100*ms['overexp']:.1f} | {100*abs(mr['overexp']-ms['overexp']):.1f} |",
        f"| **SCORE (↓)** | | | **{score:.1f}** |",
        "",
    ]
    report = "\n".join(lines)
    print(report)

    os.makedirs(os.path.join(ROOT, 'out'), exist_ok=True)
    with open(os.path.join(ROOT, 'out', 'report.md'), 'a', encoding='utf-8') as f:
        f.write(report + "\n")

    # side-by-side: REF | SHOT с подписями
    w, h = ref.size
    cmp = Image.new('RGB', (w * 2 + 12, h + 28), (20, 20, 28))
    cmp.paste(ref, (0, 28)); cmp.paste(shot, (w + 12, 28))
    d = ImageDraw.Draw(cmp)
    d.text((6, 6), f"REF  {label}", fill=(180, 220, 255))
    d.text((w + 18, 6), f"SHOT  score={score:.1f}", fill=(255, 220, 160))
    out = os.path.join(ROOT, 'out', f'cmp_{label}.png')
    cmp.save(out)
    print('wrote', os.path.relpath(out, ROOT))


if __name__ == '__main__':
    main()
