// temp: зонд «волны из ворот» — откатать разблокировку ×10, протолкнуть кучу сквозь
// открытые ворота, снять серию кадров прохода. node tools/_wave.mjs
import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const Q = opt('--q', '');   // CONFIG-override: "calmFlatG=0.45"
async function run() {
  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--ignore-gpu-blocklist', '--enable-unsafe-swapchain'] });
  const page = await browser.newPage({ viewport: { width: 720, height: 1280 } });
  page.on('pageerror', e => console.error('PAGE ERROR:', e.message));
  await page.goto(pathToFileURL(path.join(ROOT, 'dist', 'index.html')).href + '?test=1&seed=7&startCoins=25' + (Q ? '&' + Q : ''));
  await page.waitForFunction('window.__sim && window.__sim.ready === true', { timeout: 15000 });
  // разблокировка одним заездом (25 монет > cost 10), назад к источнику, подцепить отреспауненную кучу
  const pre = await page.evaluate(() => {
    const drive = (tx, tz, max) => { window.__sim.setTarget({ x: tx, z: tz }); for (let i = 0; i < max; i++) { window.__sim.run(1, 1 / 60); const s = window.__sim.state; if (Math.hypot(s.x - tx, s.z - tz) < 1.5) break; } };
    drive(0, 18.5, 600); window.__sim.run(60, 1 / 60);   // ссып на мат → ворота открыты
    drive(0, 5, 600); window.__sim.run(120, 1 / 60);     // назад, куча оседает у источника
    window.__sim.setTarget({ x: 0, z: 9 }); window.__sim.run(50, 1 / 60);   // подцепить кучу в ковш
    return { bank: Math.round(window.__sim.state.bank), z: +window.__sim.state.z.toFixed(1) };
  });
  console.log('pre-gate:', JSON.stringify(pre));
  // проезд сквозь открытые ворота (z=20) с серией кадров каждые 10 шагов
  for (let f = 0; f < 10; f++) {
    const st = await page.evaluate(() => { window.__sim.setTarget({ x: 0, z: 32 }); window.__sim.run(10, 1 / 60); window.__sim.render(); return { z: +window.__sim.state.z.toFixed(1), cs: window.__sim.coinStats }; });
    await page.screenshot({ path: path.join(ROOT, 'out', `wave_${String(f).padStart(2, '0')}.png`) });
    console.log(`wave_${String(f).padStart(2, '0')}: z=${st.z} coins=${st.cs.n} airborne=${st.cs.airborne} maxv=${st.cs.maxv} maxw=${st.cs.maxw}`);
  }
  // стояночный тест: вернуться в створ ворот с монетами в ковше и стоять — счёт монет НЕ должен расти
  const park = await page.evaluate(() => {
    const drive = (tx, tz, max) => { window.__sim.setTarget({ x: tx, z: tz }); for (let i = 0; i < max; i++) { window.__sim.run(1, 1 / 60); const s = window.__sim.state; if (Math.hypot(s.x - tx, s.z - tz) < 1.5) break; } };
    drive(0, 26, 600); drive(0, 17.5, 600);   // развернуться и встать ковшом в створ (плоскость z=20, губа ковша ~z+2.9)
    window.__sim.setTarget(null);
    const s0 = window.__sim.coinStats; window.__sim.run(900, 1 / 60); const s1 = window.__sim.coinStats;
    return { n0: s0.n, n1: s1.n, grew: s1.n - s0.n, maxw0: s0.maxw, maxw1: s1.maxw, edge: s1.edge, lean: s1.lean, awake: s1.awake };
  });
  console.log('park-in-gate:', JSON.stringify(park));
  await page.screenshot({ path: path.join(ROOT, 'out', 'wave_park.png') });
  await browser.close();
}
run().catch(e => { console.error(e); process.exit(1); });
