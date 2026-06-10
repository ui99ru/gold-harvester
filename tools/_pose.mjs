// temp: render dozer at given heading via setPose (camera-aligned comparison vs ref frame)
import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..');
const args = process.argv.slice(2);
const HEADINGS = (args[0] || '0').split(',').map(Number);
const url = pathToFileURL(path.join(ROOT, 'dist', 'index.html')).href + '?test=1&seed=7&startCoins=0';
const b = await chromium.launch({ args: ['--use-gl=angle', '--use-angle=swiftshader', '--ignore-gpu-blocklist'] });
const p = await b.newPage({ viewport: { width: 720, height: 1280 } });
await p.goto(url); await p.waitForFunction('window.__sim && window.__sim.ready === true', { timeout: 15000 });
for (const h of HEADINGS) {
  await p.evaluate((hh) => { window.__sim.setPose({ x: 0, z: 10, heading: hh }); window.__sim.render(); }, h);
  await p.screenshot({ path: path.join(ROOT, 'out', `pose_${h.toFixed(2)}.png`) });
  console.log('pose', h);
}
await b.close();
