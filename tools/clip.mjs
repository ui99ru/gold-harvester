// Мотион-рекордер: пишет клип проезда (для сверки ДВИЖЕНИЯ/физики с рефом, чего статика не ловит).
// Запуск:  node tools/clip.mjs [--seed N] [--steps 360] [--every 2] [--q "k=v&..."]
import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import { mkdir, rm } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const SEED = opt('--seed', '7'), STEPS = +opt('--steps', '360'), EVERY = +opt('--every', '2');
const Q = opt('--q', ''), HEADED = args.includes('--headed');
const W = 720, H = 1280, DT = 1 / 60;

async function run() {
  const dir = path.join(ROOT, 'out', 'clip');
  await rm(dir, { recursive: true, force: true }); await mkdir(dir, { recursive: true });
  const browser = await chromium.launch({ headless: !HEADED, args: ['--use-gl=angle', '--use-angle=swiftshader', '--ignore-gpu-blocklist', '--enable-unsafe-swapchain'] });
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  page.on('pageerror', e => console.error('PAGE ERROR:', e.message));
  const url = pathToFileURL(path.join(ROOT, 'dist', 'index.html')).href + `?test=1&seed=${SEED}` + (Q ? '&' + Q : '');
  await page.goto(url);
  await page.waitForFunction('window.__sim && window.__sim.ready === true', { timeout: 15000 });
  await page.evaluate(() => window.__sim.setTarget({ x: 0, z: 56 }));   // проезд по коридору
  let f = 0;
  for (let s = 0; s < STEPS; s++) {
    await page.evaluate((dt) => window.__sim.run(1, dt), DT);
    if (s % EVERY === 0) {
      await page.evaluate(() => window.__sim.render());
      await page.screenshot({ path: path.join(dir, `f_${String(f).padStart(4, '0')}.png`) });
      f++;
    }
  }
  await browser.close();
  // собрать в mp4 (fps подобран под EVERY: симвремя/кадр = EVERY*DT)
  const fps = Math.round(1 / (EVERY * DT));
  const out = path.join(ROOT, 'out', 'clip.mp4');
  const r = spawnSync('ffmpeg', ['-y', '-framerate', String(fps), '-i', path.join(dir, 'f_%04d.png'), '-pix_fmt', 'yuv420p', '-vf', 'scale=360:-2', out], { encoding: 'utf8' });
  console.log(r.status === 0 ? `clip: ${f} frames -> out/clip.mp4 @${fps}fps` : 'ffmpeg failed:\n' + r.stderr.split('\n').slice(-3).join('\n'));
}
run().catch(e => { console.error(e); process.exit(1); });
