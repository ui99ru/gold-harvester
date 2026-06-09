// temp: быстрый одно-кадровый зонд «несения» — едет до z~15 (между источником и воротами), снимает 1 кадр.
// node tools/_probe.mjs --q "move=5" --out p5
import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const Q = opt('--q', ''), OUT = opt('--out', 'probe'), ZSTOP = +opt('--z', '15'), TURN = args.includes('--turn'), SETTLE = +opt('--settle', '0');
async function run() {
  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--ignore-gpu-blocklist', '--enable-unsafe-swapchain'] });
  const page = await browser.newPage({ viewport: { width: 720, height: 1280 } });
  page.on('pageerror', e => console.error('PAGE ERROR:', e.message));
  const url = pathToFileURL(path.join(ROOT, 'dist', 'index.html')).href + '?test=1&seed=7' + (Q ? '&' + Q : '');
  await page.goto(url);
  await page.waitForFunction('window.__sim && window.__sim.ready === true', { timeout: 15000 });
  const st = await page.evaluate(({ zstop, turn, settle }) => {
    window.__sim.setTarget({ x: 0, z: 30 });
    for (let i = 0; i < 600 && window.__sim.state.z < zstop; i++) window.__sim.run(1, 1 / 60);
    let peak = 0;
    if (turn) { const z = window.__sim.state.z; window.__sim.setTarget({ x: 16, z }); for (let i = 0; i < 45; i++) { window.__sim.run(1, 1 / 60); peak = Math.max(peak, window.__sim.coinStats.maxv); } }
    if (settle) { window.__sim.setTarget({ x: window.__sim.state.x, z: window.__sim.state.z }); window.__sim.run(settle, 1 / 60); }
    window.__sim.render();
    return { st: window.__sim.state, cs: window.__sim.coinStats, peak: +peak.toFixed(1) };
  }, { zstop: ZSTOP, turn: TURN, settle: SETTLE });
  await page.screenshot({ path: path.join(ROOT, 'out', `probe_${OUT}.png`) });
  console.log(`probe_${OUT}: dozer=(${st.st.x.toFixed(1)},${st.st.z.toFixed(1)})  peakV=${st.peak}  coins`, JSON.stringify(st.cs));
  await browser.close();
}
run().catch(e => { console.error(e); process.exit(1); });
