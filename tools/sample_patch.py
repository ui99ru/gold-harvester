#!/usr/bin/env python3
"""Средний RGB патча изображения: python tools/sample_patch.py img.png x0 y0 x1 y1"""
import sys
from PIL import Image

img = Image.open(sys.argv[1]).convert("RGB")
x0, y0, x1, y1 = map(int, sys.argv[2:6])
px = img.crop((x0, y0, x1, y1))
data = list(px.getdata())
n = len(data)
r = sum(p[0] for p in data) / n
g = sum(p[1] for p in data) / n
b = sum(p[2] for p in data) / n
print(f"{sys.argv[1]}: mean RGB = ({r:.1f}, {g:.1f}, {b:.1f})  hex #{int(r):02x}{int(g):02x}{int(b):02x}")
