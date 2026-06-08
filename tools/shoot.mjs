// Опора 3: рендер-харнесс. Детерминированно гонит index.html?test и снимает беты.
// Запуск:  node tools/shoot.mjs [--seed N] [--headed] [--suffix _before]
import { chromium } from 'playwright';
import { pathToFileURL } from 'node:url';
import { mkdir } from 'node:fs/promises';
import path from 'node:path';

const ROOT = path.resolve(path.dirname(new URL(import.meta.url).pathname.replace(/^\/([A-Za-z]:)/, '$1')), '..');
const args = process.argv.slice(2);
const opt = (k, d) => { const i = args.indexOf(k); return i >= 0 ? args[i + 1] : d; };
const SEED = opt('--seed', '7');
const HEADED = args.includes('--headed');
const SUFFIX = opt('--suffix', '');         // напр. _before / _after для before/after
const Q = opt('--q', '');                   // CONFIG-override-свип: "groundColor=0x5b5668&exposure=0.66"
const W = 720, H = 1280;

// Сценарий = последовательность сегментов вдоль проезда (0,0)->источник->ворота->пад.
// Камера world-aligned следует за дозером, поэтому каждый бет дозеро-центричен (как в рефе).
const SCEN = [
  { steps: 36, target: { x: 0, z: 9 } },                 // разгон к кучке-источнику
  { beat: 'establish' },                                 // подъезд: грунт + ворота + кучка
  { steps: 66, target: { x: 0, z: 17 } },                // плужим кучку к воротам -> горка на ноже
  { beat: 'hill' },
  { steps: 54, target: { x: 0, z: 27 } },                // к паду, золото разъезжается валами
  { beat: 'spread' },
  { steps: 36, target: { x: 0, z: 27 } },                // ссып у апгрейд-пада
  { beat: 'pad' },
];

async function run() {
  await mkdir(path.join(ROOT, 'out'), { recursive: true });
  const browser = await chromium.launch({
    headless: !HEADED,
    args: ['--use-gl=angle', '--use-angle=swiftshader', '--ignore-gpu-blocklist', '--enable-unsafe-swapchain'],
  });
  const page = await browser.newPage({ viewport: { width: W, height: H }, deviceScaleFactor: 1 });
  page.on('pageerror', e => console.error('PAGE ERROR:', e.message));

  const url = pathToFileURL(path.join(ROOT, 'index.html')).href + `?test=1&seed=${SEED}` + (Q ? '&' + Q : '');
  await page.goto(url);
  await page.waitForFunction('window.__sim && window.__sim.ready === true', { timeout: 15000 });
  await page.waitForTimeout(200); // дать three/CDN дорисовать первый кадр

  const shots = [];
  for (const seg of SCEN) {
    if (seg.steps) {
      await page.evaluate(({ n, t }) => { window.__sim.setTarget(t); window.__sim.run(n, 1 / 60); }, { n: seg.steps, t: seg.target });
    }
    if (seg.beat) {
      await page.evaluate(() => window.__sim.render());
      await page.waitForTimeout(50);
      const file = path.join(ROOT, 'out', `shot_${seg.beat}${SUFFIX}.png`);
      await page.screenshot({ path: file });
      const st = await page.evaluate(() => window.__sim.state);
      shots.push({ beat: seg.beat, file: path.basename(file), bank: Math.round(st.bank) });
      console.log(`shot ${seg.beat}${SUFFIX}  dozer=(${st.x.toFixed(1)},${st.z.toFixed(1)})  bank=${Math.round(st.bank)}`);
    }
  }
  await browser.close();
  console.log('done:', shots.length, 'shots ->', path.join('out'));
}
run().catch(e => { console.error(e); process.exit(1); });
