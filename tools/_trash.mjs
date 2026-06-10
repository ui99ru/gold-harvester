// temp: зонд утилизатора — дешёвые разблокировки, прогнать кучу до конца коридора,
// ссыпать в trash-пад (z=64): счёт монет падает, банк НЕ меняется. node tools/_trash.mjs
import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..');
async function run() {
  const browser = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--ignore-gpu-blocklist', '--enable-unsafe-swapchain'] });
  const page = await browser.newPage({ viewport: { width: 720, height: 1280 } });
  page.on('pageerror', e => console.error('PAGE ERROR:', e.message));
  await page.goto(pathToFileURL(path.join(ROOT, 'dist', 'index.html')).href + '?test=1&seed=7&startCoins=40&gate1cost=5&gate2cost=20&upgradeCost=10');
  await page.waitForFunction('window.__sim && window.__sim.ready === true', { timeout: 15000 });
  const r = await page.evaluate(() => {
    const drive = (tx, tz, max) => { window.__sim.setTarget({ x: tx, z: tz }); for (let i = 0; i < max; i++) { window.__sim.run(1, 1 / 60); const s = window.__sim.state; if (Math.hypot(s.x - tx, s.z - tz) < 1.5) break; } };
    drive(0, 18.5, 600); window.__sim.run(60, 1 / 60);    // ворота ×10 открыты, волна рассыпалась z~21-26
    drive(0, 25, 600); window.__sim.run(30, 1 / 60);      // подцепить рассыпанное
    const b0 = Math.round(window.__sim.state.bank), n0 = window.__sim.coinStats.n;
    drive(9.2, 30, 600); window.__sim.run(150, 1 / 60);   // правый карман: утилизатор — банк стоит, счёт падает
    const b1 = Math.round(window.__sim.state.bank), n1 = window.__sim.coinStats.n;
    drive(0, 21, 600); window.__sim.run(30, 1 / 60); drive(0, 27, 600); window.__sim.run(30, 1 / 60);   // ещё горсть, дотолкать к проёму
    const b2 = Math.round(window.__sim.state.bank), ahead0 = window.__sim.coinStats.ahead;
    drive(-9.2, 30, 600); window.__sim.run(150, 1 / 60);  // пологая диагональ сквозь центр проёма → апгрейд-пад
    const b3 = Math.round(window.__sim.state.bank), s = window.__sim.coinStats, p = window.__sim.state;
    return { trash: { b0, b1, destroyed: n0 - n1 }, upgrade: { b2, b3, gained: b3 - b2, ahead0, endPos: [+p.x.toFixed(1), +p.z.toFixed(1)] }, lean: s.lean };
  });
  console.log('trash:', JSON.stringify(r));
  await page.evaluate(() => window.__sim.render());
  await page.screenshot({ path: path.join(ROOT, 'out', 'trash_pad.png') });
  await browser.close();
}
run().catch(e => { console.error(e); process.exit(1); });
