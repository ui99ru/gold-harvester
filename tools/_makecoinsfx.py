# Slice clean single coin-clinks from refs/coins.wav into a fixed-spacing bank → temp wav.
# Then ffmpeg→ogg, base64→src/coinsfx.js. Source: royalty-free (sfxengine.com); raw wav stays gitignored.
import numpy as np
from scipy.io import wavfile
from scipy.signal import find_peaks

sr, x = wavfile.read('refs/coins.wav')
if x.ndim > 1: x = x.mean(axis=1)
x = x.astype(np.float64); x /= (np.abs(x).max() + 1e-9)

env = np.abs(x); w = int(sr*0.003); es = np.convolve(env, np.ones(w)/w, 'same')
on, _ = find_peaks(es, height=es.max()*0.25, distance=int(sr*0.012))

SLOT = int(sr*0.18); CLIP = int(sr*0.13); FADE = int(sr*0.002)
chosen = []
for i, p in enumerate(on):
    prev = on[i-1] if i > 0 else -10**9
    if p - prev < int(sr*0.14):   # нужен тихий разбег → чистая атака одного клинка
        continue
    a = p - FADE
    if a < 0: continue
    seg = x[a:a+CLIP].copy()
    if len(seg) < CLIP: continue
    # нормировать + фейды
    seg /= (np.abs(seg).max() + 1e-9)
    seg[:FADE] *= np.linspace(0, 1, FADE)
    tail = int(sr*0.03); seg[-tail:] *= np.linspace(1, 0, tail)
    chosen.append(seg)
    if len(chosen) >= 8: break

print('chosen clinks:', len(chosen))
out = np.zeros(SLOT*len(chosen), np.float64)
offs = []
for i, seg in enumerate(chosen):
    out[i*SLOT:i*SLOT+CLIP] = seg
    offs.append(round(i*0.18, 3))
out = (out*0.95*32767).astype(np.int16)
wavfile.write('refs/_coinbank.wav', sr, out)
print('offsets:', offs)
print('clipDur: 0.13')
