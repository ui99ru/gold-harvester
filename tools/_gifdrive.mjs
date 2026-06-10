// Запись проезда по сложной траектории → кадры PNG (для GIF в README).
// node tools/_gifdrive.mjs  →  out/gif/f_NNN.png (15 fps реального времени: 4 сим-шага на кадр)
import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import { mkdirSync } from 'node:fs';

mkdirSync('out/gif', { recursive: true });
const b = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--ignore-gpu-blocklist'] });
const p = await b.newPage({ viewport: { width: 720, height: 1280 } });
await p.goto(pathToFileURL('dist/index.html').href + '?test=1&seed=7&startCoins=70&srcR=2.4');
await p.waitForFunction('window.__sim && window.__sim.ready === true', { timeout: 15000 });

// Этапы: [x, z, кадров] — змейка через кучу → ворота ×10 → змейка → мат ворот-2 (подъём) → разворот → обратно.
const legs = [
  [0, 12, 70], [-3.5, 16, 55], [3.5, 20, 55], [0, 24, 60],
  [-4, 30, 55], [4, 36, 55], [0, 43, 65],
  [4, 34, 55], [-4, 26, 55], [0, 18, 55], [-3, 11, 55], [0, 6, 50],
];
let n = 0;
for (const [x, z, frames] of legs) {
  await p.evaluate(([tx, tz]) => window.__sim.setTarget({ x: tx, z: tz }), [x, z]);
  for (let f = 0; f < frames; f++) {
    await p.evaluate(() => { window.__sim.run(4, 1 / 60); window.__sim.render(); });
    await p.screenshot({ path: `out/gif/f_${String(n++).padStart(3, '0')}.png` });
  }
}
await b.close();
console.log('frames:', n);
