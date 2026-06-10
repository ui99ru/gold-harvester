// temp: замер sim-step при насыщенном пуле монет. node tools/_perf.mjs --n 1200
// Дешёвые ворота → волны до упора пула → 600 шагов с таймером (физика+экономика, без рендера).
import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const CN = +opt('--n', '700');
async function run() {
  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--ignore-gpu-blocklist', '--enable-unsafe-swapchain'] });
  const page = await browser.newPage({ viewport: { width: 720, height: 1280 } });
  page.on('pageerror', e => console.error('PAGE ERROR:', e.message));
  await page.goto(pathToFileURL(path.join(ROOT, 'dist', 'index.html')).href + `?test=1&seed=7&startCoins=60&gate1cost=5&gate2cost=20&coinN=${CN}`);
  await page.waitForFunction('window.__sim && window.__sim.ready === true', { timeout: 15000 });
  const r = await page.evaluate((CN) => {
    const drive = (tx, tz, max) => { window.__sim.setTarget({ x: tx, z: tz }); for (let i = 0; i < max; i++) { window.__sim.run(1, 1 / 60); const s = window.__sim.state; if (Math.hypot(s.x - tx, s.z - tz) < 1.5) break; } };
    // насыщение: челнок сквозь открытые ворота ×10 (туда-обратно = волны, пока пул не упрётся)
    drive(0, 18.5, 600); window.__sim.run(60, 1 / 60);
    for (let l = 0; l < 8 && window.__sim.coinStats.n < CN - 20; l++) { drive(0, 26, 700); drive(0, 14, 700); }
    drive(0, 24, 700);   // встать в гущу
    const n = window.__sim.coinStats.n, awake0 = window.__sim.coinStats.awake;
    const t0 = performance.now(); window.__sim.run(600, 1 / 60); const dt = (performance.now() - t0) / 600;
    return { pool: CN, coins: n, awake0, msPerStep: +dt.toFixed(3) };
  }, CN);
  console.log(JSON.stringify(r));
  await browser.close();
}
run().catch(e => { console.error(e); process.exit(1); });
