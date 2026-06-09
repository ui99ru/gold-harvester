import * as THREE from 'three';
import { CFG, rnd, TEST, QS } from './config.js';
import { UP, state, fmt } from './state.js';
import { audioInit, pumpEngine, pumpClinks, addClinks, chime, toggleMute } from './audio.js';
import { initPhysics } from './physics.js';

THREE.ColorManagement.enabled = false;   // как в r128: палитра тюнилась без color management; держим паритет
UP.move = CFG.move;   // скорость дозера управляема через ?move= для свипа «несения»

const srgb = (tex) => { tex.colorSpace = THREE.SRGBColorSpace; return tex; };   // r184: цветные canvas-текстуры в sRGB

/* RENDERER / SCENE */
const app = document.getElementById('app');
const renderer = new THREE.WebGLRenderer({ antialias: true }); renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
renderer.toneMapping = THREE.ACESFilmicToneMapping; renderer.toneMappingExposure = CFG.exposure;
const scene = new THREE.Scene(); scene.background = new THREE.Color(CFG.bgColor);
// мягкая equirect-среда (вертикальный градиент) для блеска золота — RGBA (r184: RGBFormat удалён)
const eg = new Uint8Array(16 * 64 * 4);
for (let y = 0; y < 64; y++) { const t = y / 63, r = Math.round((110 + t * 120) * 0.45), g = Math.round((140 + t * 90) * 0.45), b = Math.round((196 - t * 120) * 0.5); for (let x = 0; x < 16; x++) { const i = (y * 16 + x) * 4; eg[i] = r; eg[i + 1] = g; eg[i + 2] = b; eg[i + 3] = 255; } }
const env = new THREE.DataTexture(eg, 16, 64, THREE.RGBAFormat); env.mapping = THREE.EquirectangularReflectionMapping; env.needsUpdate = true; scene.environment = env;
scene.fog = new THREE.Fog(CFG.bgColor, CFG.fogNear, CFG.fogFar);
app.appendChild(renderer.domElement);
const camera = new THREE.PerspectiveCamera(CFG.fov, innerWidth / innerHeight, 0.1, 400);
scene.add(new THREE.HemisphereLight(0xcfe0f5, 0x5a4a40, CFG.hemiInt)); const sun = new THREE.DirectionalLight(0xfff4de, CFG.sunInt); sun.position.set(10, 22, 6); scene.add(sun);
// Фактура земли: лавандовая база + бесшовный value-noise (пятна) + зерно. Детерминир. (trig+hash, без rng) → шоты воспроизводимы.
// Тот же tex как bumpMap (рельеф по красному каналу). repeat → тайлинг по кругу.
function groundTex() {
  const S = 256, c = document.createElement('canvas'); c.width = c.height = S; const x = c.getContext('2d');
  const bc = new THREE.Color(CFG.groundColor), br = bc.r * 255, bg = bc.g * 255, bb = bc.b * 255, TAU = 6.2831853;
  const img = x.createImageData(S, S), d = img.data;
  for (let j = 0; j < S; j++) for (let i = 0; i < S; i++) {
    const u = i / S, v = j / S;
    let n = Math.sin(u * TAU * 3) * Math.cos(v * TAU * 3) * 0.5 + Math.sin(u * TAU * 7 + 1.3) * Math.cos(v * TAU * 5 + 2.1) * 0.25 + Math.sin(u * TAU * 13 + 0.7) * Math.cos(v * TAU * 11 + 4.2) * 0.13;
    const hh = Math.sin(i * 12.9898 + j * 78.233) * 43758.5453, g = (hh - Math.floor(hh)) - 0.5;   // зерно
    const k = 1 + n * 0.12 + g * 0.07, o = (j * S + i) * 4;
    d[o] = Math.min(255, br * k); d[o + 1] = Math.min(255, bg * k); d[o + 2] = Math.min(255, bb * k); d[o + 3] = 255;
  }
  x.putImageData(img, 0, 0);
  const t = srgb(new THREE.CanvasTexture(c)); t.wrapS = t.wrapT = THREE.RepeatWrapping; t.repeat.set(14, 14); return t;
}
const groundMap = groundTex();
const ground = new THREE.Mesh(new THREE.CircleGeometry(150, 48), new THREE.MeshStandardMaterial({ map: groundMap, bumpMap: groundMap, bumpScale: 0.6, roughness: 1 })); ground.rotation.x = -Math.PI / 2; scene.add(ground);
const rockMat = new THREE.MeshStandardMaterial({ color: 0x8f72c8, roughness: 1, flatShading: true });
for (let i = 0; i < 50; i++) { const a = rnd() * 6.28, r = 70 + rnd() * 35, s = 3 + rnd() * 5; const m = new THREE.Mesh(new THREE.DodecahedronGeometry(s, 0), rockMat); m.position.set(Math.cos(a) * r, s * 0.5 - 0.5, Math.sin(a) * r); m.rotation.set(rnd() * 3, rnd() * 3, rnd() * 3); scene.add(m); }

/* DOZER (детальная миниатюра: фиолетовое шасси, синяя кабина, тёмные гусеницы, фары) */
const dozer = new THREE.Group();
const chassisM = new THREE.MeshStandardMaterial({ color: 0x6a4fc0, roughness: .45, metalness: .2 });
const cabM = new THREE.MeshStandardMaterial({ color: 0x5e7be0, roughness: .4, metalness: .2 }); const roofM = new THREE.MeshStandardMaterial({ color: 0x9fb4f5, roughness: .45 });
const dark = new THREE.MeshStandardMaterial({ color: 0x222633, roughness: .75 }); const tread = new THREE.MeshStandardMaterial({ color: 0x14161d, roughness: .85 });
const steel = new THREE.MeshStandardMaterial({ color: 0xc8ccd6, roughness: .35, metalness: .6 });
const purple = new THREE.MeshStandardMaterial({ color: 0x8a4fd6, roughness: .35, metalness: .3, emissive: 0x240a44, emissiveIntensity: .4 });
const glass = new THREE.MeshStandardMaterial({ color: 0x9fe0ff, roughness: .1, metalness: .5, transparent: true, opacity: .7 });
function box(w, h, d, m, x, y, z, p) { const b = new THREE.Mesh(new THREE.BoxGeometry(w, h, d), m); b.position.set(x, y, z); (p || dozer).add(b); return b; }
function cyl(r, h, m, x, y, z, ax, p) { const b = new THREE.Mesh(new THREE.CylinderGeometry(r, r, h, 16), m); b.position.set(x, y, z); if (ax === 'x') b.rotation.z = Math.PI / 2; if (ax === 'z') b.rotation.x = Math.PI / 2; (p || dozer).add(b); return b; }
const treads = [];   // блоки протектора — прокручиваются по скорости (вращение гусениц)
const TREAD_N = 6, TREAD_SP = 0.5, TREAD_SPAN = TREAD_N * TREAD_SP, TREAD_MIN = -1.5;
for (const sx of [-1, 1]) {   // гусеницы: длинные тёмные, округлые торцы + протектор + ступица
  box(.8, .5, 3.0, dark, sx * 1.0, .42, 0); cyl(.27, .82, dark, sx * 1.0, .42, 1.5, 'x'); cyl(.27, .82, dark, sx * 1.0, .42, -1.5, 'x');
  cyl(.16, .86, steel, sx * 1.0, .42, 0, 'x');
  for (let k = 0; k < TREAD_N; k++) treads.push(box(.86, .1, .13, tread, sx * 1.0, .66, TREAD_MIN + k * TREAD_SP));
}
box(1.7, .6, 2.1, chassisM, 0, .95, -.05); box(1.5, .46, .9, chassisM, 0, .86, .9); box(1.2, .32, .06, dark, 0, .82, 1.36);   // шасси + капот + решётка
cyl(.15, .18, steel, -.45, .9, 1.4, 'z'); cyl(.15, .18, steel, .45, .9, 1.4, 'z');                                            // фары
box(1.25, .66, 1.1, cabM, 0, 1.6, -.5); box(1.36, .12, 1.22, roofM, 0, 1.98, -.5);                                            // кабина + крыша
box(1.04, .42, .05, glass, 0, 1.6, .04); box(.05, .42, .86, glass, -.62, 1.6, -.5); box(.05, .42, .86, glass, .62, 1.6, -.5); // стёкла
cyl(.08, .5, dark, .52, 2.0, 0, 'y'); cyl(.12, .1, dark, .52, 2.27, 0, 'y');                                                  // выхлоп
box(.38, .4, .38, new THREE.MeshStandardMaterial({ color: 0x6ab04c, roughness: .7 }), 0, 1.66, -.42); box(.44, .18, .44, new THREE.MeshStandardMaterial({ color: 0xf4c542, roughness: .6 }), 0, 1.93, -.42); // водитель
const blade = box(2.6, .9, .28, purple, 0, .66, 1.62); blade.rotation.x = -0.16;
box(2.6, .16, .42, purple, 0, .5, .16, blade); box(2.6, .12, .1, steel, 0, -.46, .12, blade);                                 // кромки (children)
for (const s of [-1, 1]) { const wg = box(.24, .82, .62, purple, s * 1.28, 0, .34, blade); wg.rotation.y = -s * CFG.bladeWingAng; }   // крылья вогнутого отвала (меньше)
box(.2, .16, 1.2, chassisM, -.95, .55, 1.0); box(.2, .16, 1.2, chassisM, .95, .55, 1.0); scene.add(dozer);                    // рычаги
const shadow = new THREE.Mesh(new THREE.CircleGeometry(2.2, 24), new THREE.MeshBasicMaterial({ color: 0, transparent: true, opacity: .25 })); shadow.rotation.x = -Math.PI / 2; shadow.position.y = .04; scene.add(shadow);

/* DISCRETE COINS */
const N = 700, THK = 0.085, RAD = 0.40;   // тонкие диски: ребром почти не встают; меньше тел ради 60fps
const coinGeo = new THREE.CylinderGeometry(RAD, RAD, THK, 20);   // группы: 0=ребро,1=верх,2=низ → разные материалы
// Грань монеты: кольцевое углубление + гравированный знак (рельеф через тёмные углубления, map умножается на цвет).
function coinFaceTex() {
  const c = document.createElement('canvas'); c.width = c.height = 128; const x = c.getContext('2d');
  x.fillStyle = '#fff'; x.fillRect(0, 0, 128, 128);
  const g = x.createRadialGradient(64, 60, 22, 64, 64, 64); g.addColorStop(0, 'rgba(255,255,255,0)'); g.addColorStop(1, 'rgba(58,36,6,0.32)'); x.fillStyle = g; x.fillRect(0, 0, 128, 128);   // округлость
  x.lineCap = 'round';
  x.strokeStyle = 'rgba(58,36,6,0.5)'; x.lineWidth = 5; x.beginPath(); x.arc(64, 64, 50, 0, 6.2832); x.stroke();      // кольцевое углубление
  x.strokeStyle = 'rgba(255,255,255,0.45)'; x.lineWidth = 2; x.beginPath(); x.arc(64, 64, 46, 0, 6.2832); x.stroke(); // блик-ободок
  x.save(); x.translate(64, 65); x.fillStyle = 'rgba(58,36,6,0.42)'; x.beginPath();
  for (let i = 0; i < 10; i++) { const a = -Math.PI / 2 + i * Math.PI / 5, r = i % 2 ? 8 : 19; const px = Math.cos(a) * r, py = Math.sin(a) * r; i ? x.lineTo(px, py) : x.moveTo(px, py); }
  x.closePath(); x.fill(); x.strokeStyle = 'rgba(255,255,255,0.4)'; x.lineWidth = 1; x.stroke();                       // знак-звезда (гравировка)
  x.restore();
  return srgb(new THREE.CanvasTexture(c));
}
// Карта высот для рельефа (bumpMap, линейная, НЕ sRGB): светлее=выше. Углубления = тёмное → реальная игра света.
function coinBumpTex() {
  const c = document.createElement('canvas'); c.width = c.height = 128; const x = c.getContext('2d');
  x.fillStyle = '#9a9a9a'; x.fillRect(0, 0, 128, 128);                                                      // поле
  x.lineCap = 'round';
  x.strokeStyle = '#e6e6e6'; x.lineWidth = 9; x.beginPath(); x.arc(64, 64, 55, 0, 6.2832); x.stroke();      // приподнятый ободок
  x.strokeStyle = '#2a2a2a'; x.lineWidth = 7; x.beginPath(); x.arc(64, 64, 46, 0, 6.2832); x.stroke();      // кольцевое УГЛУБЛЕНИЕ
  x.fillStyle = '#b2b2b2'; x.beginPath(); x.arc(64, 64, 30, 0, 6.2832); x.fill();                           // центральная площадка
  x.fillStyle = '#262626'; x.save(); x.translate(64, 65); x.beginPath();
  for (let i = 0; i < 10; i++) { const a = -Math.PI / 2 + i * Math.PI / 5, r = i % 2 ? 9 : 21; const px = Math.cos(a) * r, py = Math.sin(a) * r; i ? x.lineTo(px, py) : x.moveTo(px, py); }
  x.closePath(); x.fill(); x.restore();                                                                     // знак-звезда — углубление
  return new THREE.CanvasTexture(c);
}
const capMat = new THREE.MeshStandardMaterial({ map: coinFaceTex(), bumpMap: coinBumpTex(), bumpScale: 1.4, color: CFG.coinColor, metalness: CFG.coinMetal, roughness: CFG.coinRough, emissive: CFG.coinEmissive, emissiveIntensity: CFG.coinEmInt, envMapIntensity: 0.8 });
const sideMat = new THREE.MeshStandardMaterial({ color: 0xe0a52e, metalness: CFG.coinMetal + 0.05, roughness: CFG.coinRough * 0.9, emissive: CFG.coinEmissive, emissiveIntensity: CFG.coinEmInt, envMapIntensity: 0.8 });   // ребро чуть темнее золота
const mesh = new THREE.InstancedMesh(coinGeo, [sideMat, capMat, capMat], N); mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage); mesh.frustumCulled = false; scene.add(mesh);   // монеты по всему полю → культинг съедал весь меш
// C[i] держит ТОЛЬКО геймплей-метадату; поза/кувырок живут в теле Rapier (phys.coinBodies[i]).
const C = []; for (let i = 0; i < N; i++) C.push({ st: 'free', worth: 1, gateCd: 0 });
const free = []; const _m = new THREE.Matrix4(), _p = new THREE.Vector3(), _q = new THREE.Quaternion(), _s = new THREE.Vector3();
function setMfromBody(i) { if (phys && phys.readCoin(i, _p, _q)) { _m.compose(_p, _q, _s.setScalar(1)); mesh.setMatrixAt(i, _m); } }   // полный кватернион → настоящий кувырок
function hideM(i) { _m.compose(_p.set(0, -999, 0), _q.identity(), _s.setScalar(0.0001)); mesh.setMatrixAt(i, _m); }
const SRC = [0, 9];
// respawn/boot: seeded-разброс + падение с высоты (оседают в кучу, не копланарны → солвер стабилен).
function placeAtSource(i) { const a = rnd() * 6.28, r = Math.sqrt(rnd()) * CFG.srcR, y = THK * 0.5 + rnd() * 6.0; const o = C[i]; o.worth = 1; o.gateCd = 0; o.st = 'rest'; phys.enableCoin(i); phys.setCoinTransform(i, SRC[0] + Math.cos(a) * r, y, SRC[1] + Math.sin(a) * r); }

/* GATES + PADS */
const gates = []; const obstacles = [];   // твёрдые препятствия для дозера (столбы ворот, задние стенки падов) — AABB
function gateTex(label, kind) {
  const c = document.createElement('canvas'); c.width = 256; c.height = 256; const x = c.getContext('2d');
  if (kind === 'red') {   // красно-белый полосатый шеврон (×100 в рефе = заблокировано)
    x.fillStyle = '#fff'; x.fillRect(0, 0, 256, 256); x.save(); x.translate(128, 128); x.rotate(-0.5); x.fillStyle = '#e8392f';
    for (let i = -320; i < 320; i += 56) x.fillRect(i, -260, 28, 520); x.restore();
    x.font = '900 92px Trebuchet MS,sans-serif'; x.textAlign = 'center'; x.textBaseline = 'middle'; x.lineWidth = 9; x.strokeStyle = '#b81d16'; x.strokeText(label, 128, 140); x.fillStyle = '#fff'; x.fillText(label, 128, 140);
  } else {                // светло-циановая стеклянная завеса (активно)
    x.fillStyle = 'rgba(150,225,255,.16)'; x.fillRect(0, 0, 256, 256); x.fillStyle = '#f2ffff'; x.font = '900 140px Trebuchet MS,sans-serif'; x.textAlign = 'center'; x.textBaseline = 'middle'; x.shadowColor = '#5ec8ff'; x.shadowBlur = 20; x.fillText(label, 128, 138);
  }
  return srgb(new THREE.CanvasTexture(c));
}
function bannerTex(text) {
  const c = document.createElement('canvas'); c.width = 256; c.height = 128; const x = c.getContext('2d');
  x.fillStyle = '#5a3fb4'; x.strokeStyle = '#7d5fe0'; x.lineWidth = 8; const r = 26; x.beginPath();
  x.moveTo(12 + r, 18); x.arcTo(244, 18, 244, 110, r); x.arcTo(244, 110, 12, 110, r); x.arcTo(12, 110, 12, 18, r); x.arcTo(12, 18, 244, 18, r); x.closePath(); x.fill(); x.stroke();
  x.fillStyle = '#fff'; x.font = '900 62px Trebuchet MS,sans-serif'; x.textAlign = 'center'; x.textBaseline = 'middle'; x.shadowColor = 'rgba(0,0,0,.4)'; x.shadowBlur = 6; x.fillText(text, 128, 66);
  return srgb(new THREE.CanvasTexture(c));
}
function addGate(x, z, rot, mult, cost) {
  const g = new THREE.Group(); g.position.set(x, 0, z); g.rotation.y = rot; scene.add(g);
  const body = new THREE.MeshStandardMaterial({ color: 0x4a47c0, roughness: .4, metalness: .2, emissive: 0x191455, emissiveIntensity: .5 });
  const copper = new THREE.MeshStandardMaterial({ color: 0xb5642a, roughness: .6, metalness: .3 });
  const gemMat = new THREE.MeshStandardMaterial({ color: 0x6fe0ff, roughness: .2, metalness: .3, emissive: 0x2aa0d0, emissiveIntensity: .7 });
  const PW = 4.6;   // полу-разнос столбов: огромная арка, дозер ~1/4 высоты
  for (const sx of [-1, 1]) {
    box(1.1, 8.4, 1.1, body, sx * PW, 4.2, 0, g); box(1.3, .8, 1.3, copper, sx * PW, 2.3, 0, g);
    const gem = new THREE.Mesh(new THREE.OctahedronGeometry(.85, 0), gemMat); gem.position.set(sx * PW, 8.9, 0); g.add(gem);
    const ox = x + sx * PW * Math.cos(rot), oz = z - sx * PW * Math.sin(rot); obstacles.push({ x0: ox - 0.75, x1: ox + 0.75, z0: oz - 0.75, z1: oz + 0.75 });   // столб — твёрдый
  }
  function curtain(kind) {   // одна завеса в двух состояниях: red=locked / white=active
    const red = kind === 'red'; const m = new THREE.Mesh(new THREE.PlaneGeometry(11.0, 8.2), new THREE.MeshBasicMaterial({ map: gateTex('×' + mult, kind), transparent: true, opacity: red ? .97 : .9, side: THREE.DoubleSide, blending: red ? THREE.NormalBlending : THREE.AdditiveBlending, depthWrite: false }));
    m.position.set(0, 4.6, 0); m.rotation.y = Math.PI; g.add(m); return m;
  }
  const redM = curtain('red'), whiteM = curtain('white'); whiteM.visible = false;
  const b = new THREE.Mesh(new THREE.PlaneGeometry(4.6, 2.3), new THREE.MeshBasicMaterial({ map: bannerTex(String(cost)), transparent: true, side: THREE.DoubleSide, depthWrite: false })); b.position.set(0, 10.4, 0); b.rotation.y = Math.PI; g.add(b);
  gates.push({ x, z, n: new THREE.Vector3(Math.sin(rot), 0, Math.cos(rot)), right: new THREE.Vector3(Math.cos(rot), 0, -Math.sin(rot)), mult, cost, active: false, red: redM, white: whiteM, halfW: 2.8 });
}
const pads = [];
function makeLabel() { const c = document.createElement('canvas'); c.width = 256; c.height = 128; const m = new THREE.Mesh(new THREE.PlaneGeometry(4.2, 2.1), new THREE.MeshBasicMaterial({ map: srgb(new THREE.CanvasTexture(c)), transparent: true, side: THREE.DoubleSide, depthWrite: false })); m.userData.c = c; return m; }
function drawLabel(spr, top, bottom, col) { const c = spr.userData.c, x = c.getContext('2d'); x.clearRect(0, 0, 256, 128); x.fillStyle = col || '#fff'; x.font = '900 58px Trebuchet MS,sans-serif'; x.textAlign = 'center'; x.textBaseline = 'middle'; x.shadowColor = 'rgba(0,0,0,.5)'; x.shadowBlur = 8; x.fillText(top, 128, 42); x.font = '900 40px Trebuchet MS,sans-serif'; x.fillStyle = '#ffe27a'; x.fillText(bottom, 128, 94); spr.material.map.needsUpdate = true; }
function addPad(x, z, name, cost, apply) {
  const g = new THREE.Group(); g.position.set(x, 0, z); scene.add(g);
  box(5.0, .16, 5.0, new THREE.MeshStandardMaterial({ color: 0xf2c63a, roughness: .6, emissive: 0x4a3a00, emissiveIntensity: .2 }), 0, .08, 0, g); // жёлтый въездной мат
  box(4.2, .2, 4.2, new THREE.MeshStandardMaterial({ color: 0x3a2f63, roughness: .85 }), 0, .12, 0, g);                                            // тёмная вставка
  box(4.8, 3.4, 1.1, new THREE.MeshStandardMaterial({ color: 0x6a4cc0, roughness: .5, emissive: 0x1e1050, emissiveIntensity: .4 }), 0, 1.7, 3.0, g); // задняя стойка
  obstacles.push({ x0: x - 2.4, x1: x + 2.4, z0: z + 3 - 0.6, z1: z + 3 + 0.6 });   // задняя стойка пада — твёрдая
  const GH = 3.0, BOT = 0.25;
  box(3.6, GH, .5, new THREE.MeshStandardMaterial({ color: 0x123040, transparent: true, opacity: .32, roughness: .4 }), 0, BOT + GH / 2, 2.25, g);  // рамка стекла
  const fill = new THREE.Mesh(new THREE.BoxGeometry(3.3, GH, .55), new THREE.MeshBasicMaterial({ color: 0x35d8e6, transparent: true, opacity: .82, blending: THREE.AdditiveBlending, depthWrite: false })); fill.position.set(0, BOT + 0.001, 2.3); fill.scale.y = 0.001; g.add(fill);
  const gm = new THREE.MeshStandardMaterial({ color: 0xffffff, transparent: true, opacity: .5, roughness: .6, emissive: 0x444444 }); const ghost = new THREE.Group(); // призрак награды
  box(1.4, .8, 1.9, gm, 0, 0, 0, ghost); box(1.0, .7, .9, gm, 0, .6, -.35, ghost); box(1.9, .55, .3, gm, 0, -.12, 1.05, ghost); ghost.position.set(0, 1.3, 2.15); g.add(ghost);
  const lbl = makeLabel(); lbl.position.set(0, 4.0, 2.45); lbl.rotation.y = Math.PI; g.add(lbl);
  const pad = { x, z, half: 2.4, name, cost, fill: 0, level: 0, grow: 1.8, apply, ghost, fillBar: fill, lbl, GH, BOT }; drawLabel(lbl, 'UPGRADE', name + ' ' + fmt(cost), '#fff'); pads.push(pad);
}

/* HUD */
const elBank = document.getElementById('bankNum'), elFx = document.getElementById('fx');
let _bankShown = 0;
function updateBank() { elBank.textContent = fmt(state.bank); if (state.bank > _bankShown) { _bankShown = state.bank; elBank.classList.remove('bump'); void elBank.offsetWidth; elBank.classList.add('bump'); } }
function popup(world, text, color) { const v = world.clone().project(camera); if (v.z > 1) return; const el = document.createElement('div'); el.className = 'pop'; el.textContent = text; el.style.color = color; el.style.left = ((v.x * .5 + .5) * innerWidth) + 'px'; el.style.top = ((-v.y * .5 + .5) * innerHeight) + 'px'; elFx.appendChild(el); setTimeout(() => el.remove(), 820); }

/* JUICE: частицы (пыль/искры) */
const ptTex = (function () { const c = document.createElement('canvas'); c.width = c.height = 64; const x = c.getContext('2d'); const gr = x.createRadialGradient(32, 32, 0, 32, 32, 32); gr.addColorStop(0, 'rgba(255,255,255,1)'); gr.addColorStop(.5, 'rgba(255,255,255,.5)'); gr.addColorStop(1, 'rgba(255,255,255,0)'); x.fillStyle = gr; x.fillRect(0, 0, 64, 64); return srgb(new THREE.CanvasTexture(c)); })();
const PT = []; for (let i = 0; i < 80; i++) { const s = new THREE.Sprite(new THREE.SpriteMaterial({ map: ptTex, transparent: true, depthWrite: false, opacity: 0 })); s.visible = false; scene.add(s); PT.push({ s, life: 0, max: 1, vx: 0, vy: 0, vz: 0, grav: 0, s0: 1, s1: 1, fade: 1 }); }
let ptHead = 0;
function emit(x, y, z, o) {
  const p = PT[ptHead]; ptHead = (ptHead + 1) % PT.length; p.life = p.max = o.life; p.vx = o.vx || 0; p.vy = o.vy || 0; p.vz = o.vz || 0; p.grav = o.grav || 0; p.s0 = o.size; p.s1 = o.size1 || o.size; p.fade = o.fade || 1;
  p.s.visible = true; p.s.position.set(x, y, z); p.s.material.color.setHex(o.color); p.s.material.opacity = o.fade; p.s.material.blending = o.add ? THREE.AdditiveBlending : THREE.NormalBlending; p.s.scale.setScalar(o.size);
}
function updateParticles(dt) { for (const p of PT) { if (p.life <= 0) continue; p.life -= dt; if (p.life <= 0) { p.s.visible = false; continue; } p.vy -= p.grav * dt; p.s.position.x += p.vx * dt; p.s.position.y += p.vy * dt; p.s.position.z += p.vz * dt; const t = p.life / p.max; p.s.material.opacity = t * p.fade; p.s.scale.setScalar(p.s0 + (p.s1 - p.s0) * (1 - t)); } }
function emitDust() { const f = Math.sin(state.heading), cf = Math.cos(state.heading); const bx = dozer.position.x - f * 1.6, bz = dozer.position.z - cf * 1.6; for (const sx of [-0.9, 0.9]) emit(bx + cf * sx + (rnd() - .5) * .3, .18, bz - f * sx + (rnd() - .5) * .3, { color: 0x9a92a8, life: .55, size: .5, size1: 1.3, vy: .5, grav: .4, vx: (rnd() - .5) * .6, vz: (rnd() - .5) * .6, fade: .32 }); }
function emitSparks(x, z, n) { for (let k = 0; k < n; k++) { const a = rnd() * 6.28, sp = 2 + rnd() * 3; emit(x + (rnd() - .5) * 1.5, .4, z + (rnd() - .5) * 1.5, { color: 0xffd86a, life: .4 + rnd() * .2, size: .45, size1: .1, add: true, vy: 2.5 + rnd() * 2, grav: 7, vx: Math.cos(a) * sp, vz: Math.sin(a) * sp, fade: 1 }); } }

function setupWorld() {   // монеты-тела создаются в bootPhysics (нужен phys); здесь — статичный мир
  addGate(0, 20, 0, 10, CFG.gate1cost); addGate(0, 40, 0, 100, CFG.gate2cost);
  addPad(0, 56, 'НОЖ', 120, () => { UP.bladeHalf += 0.5; blade.scale.x = UP.bladeHalf / 1.6; phys.rebuildBladeCollider(bladeHX(), 0.65, 0.14, CFG.bladeWing, CFG.bladeWingAng); });
  addPad(-18, 9, 'ЗАХВАТ', 150, () => { UP.reach += 0.6; });
  addPad(18, 9, 'ЦЕННОСТЬ', 180, () => { UP.mult *= 1.7; });
  updateBank();
}

/* INPUT */
const ray = new THREE.Raycaster(), ndc = new THREE.Vector2(); const plane = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0); const keys = {};
function setP(e) { ndc.x = (e.clientX / innerWidth) * 2 - 1; ndc.y = -(e.clientY / innerHeight) * 2 + 1; }
renderer.domElement.addEventListener('pointerdown', e => { if (state.phase === 'play') { state.driving = true; setP(e); } });
renderer.domElement.addEventListener('pointermove', e => { if (state.driving) setP(e); });
addEventListener('pointerup', () => state.driving = false);
addEventListener('keydown', e => keys[e.key.toLowerCase()] = true); addEventListener('keyup', e => keys[e.key.toLowerCase()] = false);

/* BLOOM (самодостаточный, под защитой; r184: без outputEncoding — RT линейный по умолчанию) */
let usePost = false, rtScene, rtA, rtB, qs, qc, quad, mBright, mBlur, mComp;
function initBloom() {
  try {
    const w = Math.floor(innerWidth * Math.min(devicePixelRatio, 2)), h = Math.floor(innerHeight * Math.min(devicePixelRatio, 2));
    const opt = { minFilter: THREE.LinearFilter, magFilter: THREE.LinearFilter, format: THREE.RGBAFormat };
    rtScene = new THREE.WebGLRenderTarget(w, h, opt); rtA = new THREE.WebGLRenderTarget(w >> 1, h >> 1, opt); rtB = new THREE.WebGLRenderTarget(w >> 1, h >> 1, opt);
    qs = new THREE.Scene(); qc = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1); quad = new THREE.Mesh(new THREE.PlaneGeometry(2, 2)); qs.add(quad);
    mBright = new THREE.ShaderMaterial({ toneMapped: false, uniforms: { tD: { value: null }, thr: { value: CFG.bloomThr } }, vertexShader: `varying vec2 v;void main(){v=uv;gl_Position=vec4(position.xy,0.,1.);}`, fragmentShader: `varying vec2 v;uniform sampler2D tD;uniform float thr;void main(){vec3 c=texture2D(tD,v).rgb;float l=dot(c,vec3(.299,.587,.114));float k=smoothstep(thr,thr+0.25,l);gl_FragColor=vec4(c*k,1.);}` });
    mBlur = new THREE.ShaderMaterial({ toneMapped: false, uniforms: { tD: { value: null }, dir: { value: new THREE.Vector2() } }, vertexShader: `varying vec2 v;void main(){v=uv;gl_Position=vec4(position.xy,0.,1.);}`, fragmentShader: `varying vec2 v;uniform sampler2D tD;uniform vec2 dir;void main(){vec3 s=texture2D(tD,v).rgb*0.227;s+=texture2D(tD,v+dir*1.38).rgb*0.316;s+=texture2D(tD,v-dir*1.38).rgb*0.316;s+=texture2D(tD,v+dir*3.23).rgb*0.070;s+=texture2D(tD,v-dir*3.23).rgb*0.070;gl_FragColor=vec4(s,1.);}` });
    mComp = new THREE.ShaderMaterial({ toneMapped: false, uniforms: { tS: { value: null }, tB: { value: null }, inten: { value: CFG.bloomInten } }, vertexShader: `varying vec2 v;void main(){v=uv;gl_Position=vec4(position.xy,0.,1.);}`, fragmentShader: `varying vec2 v;uniform sampler2D tS;uniform sampler2D tB;uniform float inten;void main(){vec3 c=texture2D(tS,v).rgb+texture2D(tB,v).rgb*inten;c=pow(c,vec3(1.0/2.2));gl_FragColor=vec4(c,1.);}` });
    usePost = true;
  } catch (e) { usePost = false; }
}
function blit(mat, t) { quad.material = mat; renderer.setRenderTarget(t || null); renderer.clear(); renderer.render(qs, qc); }
function renderPost() {
  renderer.setRenderTarget(rtScene); renderer.clear(); renderer.render(scene, camera);
  mBright.uniforms.tD.value = rtScene.texture; blit(mBright, rtA); const tx = 1 / rtA.width, ty = 1 / rtA.height;
  mBlur.uniforms.tD.value = rtA.texture; mBlur.uniforms.dir.value.set(tx, 0); blit(mBlur, rtB); mBlur.uniforms.tD.value = rtB.texture; mBlur.uniforms.dir.value.set(0, ty); blit(mBlur, rtA);
  mComp.uniforms.tS.value = rtScene.texture; mComp.uniforms.tB.value = rtA.texture; blit(mComp, null); renderer.setRenderTarget(null);
}

/* FLOW */
let phys = null;
async function bootPhysics() {
  phys = await initPhysics({
    count: N, thk: THK, rad: RAD, gravity: [0, CFG.gravityY, 0],
    density: CFG.coinDensity, friction: CFG.coinFriction, restitution: CFG.coinRestitution,
    linDamp: CFG.linDamp, angDamp: CFG.angDamp, contactThreshold: CFG.contactThr, maxv: CFG.coinMaxV,
    calmV: CFG.calmV, calmW: CFG.calmW, calmFrames: CFG.calmFrames, calmVy: CFG.calmVy, calmFlat: CFG.calmFlat, flattenK: CFG.flattenK, clinkV: CFG.clinkV,
  });
  for (let i = 0; i < N; i++) phys.addCoinBody(i, 0, -999, 0);              // пул тел — создать раз
  for (let i = 0; i < N; i++) { if (i < 420) placeAtSource(i); else { C[i].st = 'free'; free.push(i); phys.hideCoin(i); hideM(i); } }
  phys.addBlade(bladeHX(), 0.65, 0.14, CFG.bladeWing, CFG.bladeWingAng);
  phys.addChassis([{ hx: 1.4, hy: 0.5, hz: 0.75, cy: 0.5, cz: 0.75 }, { hx: 1.4, hy: 1.0, hz: 0.95, cy: 1.0, cz: -0.7 }]);   // фронт-низ (стык, не таранит) + кабина-высокая (монеты не на корпусе)
  phys.addWall(-CFG.laneHalf, 0.6, 31, 0.2, 0.6, 27); phys.addWall(CFG.laneHalf, 0.6, 31, 0.2, 0.6, 27);   // коридор z∈[4,58]: монеты в полосе
  syncCoins(); mesh.instanceMatrix.needsUpdate = true;
}
function start() { if (!TEST) audioInit(); document.getElementById('start').classList.add('hidden'); document.getElementById('bank').classList.remove('hidden'); document.getElementById('mute').classList.remove('hidden'); setupWorld(); state.phase = 'play'; }
async function bootAndStart() { start(); await bootPhysics(); window.__sim.ready = true; }   // ready ТОЛЬКО после WASM+тел
document.getElementById('startBtn').onclick = () => bootAndStart();
document.getElementById('mute').onclick = function () { const m = toggleMute(); this.textContent = m ? '🔇' : '🔊'; };

/* SIM STEP (детерминированный, отделён от rAF) */
const ctrl = { desired: null, moving: false };
let _target = null, simTime = 0;
function applyLiveInput() {
  ctrl.desired = null; ctrl.moving = false;
  if (state.driving) { ray.setFromCamera(ndc, camera); const hit = new THREE.Vector3(); if (ray.ray.intersectPlane(plane, hit)) { const dx = hit.x - dozer.position.x, dz = hit.z - dozer.position.z; if (dx * dx + dz * dz > 0.4) ctrl.desired = Math.atan2(dx, dz); } }
  let kx = 0, kz = 0; if (keys['w'] || keys['arrowup']) kz += 1; if (keys['s'] || keys['arrowdown']) kz -= 1; if (keys['a'] || keys['arrowleft']) kx += 1; if (keys['d'] || keys['arrowright']) kx -= 1; // лево-право инвертированы (под реф)
  if (kx || kz) { ctrl.desired = Math.atan2(kx, kz); ctrl.moving = true; } else if (ctrl.desired !== null) ctrl.moving = true;
}
function applyScriptInput() {
  ctrl.desired = null; ctrl.moving = false;
  if (_target) { const dx = _target.x - dozer.position.x, dz = _target.z - dozer.position.z; if (dx * dx + dz * dz > 0.25) { ctrl.desired = Math.atan2(dx, dz); ctrl.moving = true; } }
}
const DOZER_R = 1.6;
function resolveObstacles() {   // дозер-круг vs AABB-препятствия: выталкиваем (не проходит сквозь столбы/пады)
  for (const o of obstacles) {
    const cx = Math.max(o.x0, Math.min(dozer.position.x, o.x1)), cz = Math.max(o.z0, Math.min(dozer.position.z, o.z1));
    const dx = dozer.position.x - cx, dz = dozer.position.z - cz, d2 = dx * dx + dz * dz;
    if (d2 > 1e-6 && d2 < DOZER_R * DOZER_R) { const d = Math.sqrt(d2), p = (DOZER_R - d) / d; dozer.position.x += dx * p; dozer.position.z += dz * p; }
  }
}
let treadPhase = 0;
function animTracks(dt) {   // прокрутка протектора: вперёд → блоки бегут к корме и заворачиваются (иллюзия вращения)
  treadPhase += state.speedNow * dt;
  const ph = ((treadPhase % TREAD_SPAN) + TREAD_SPAN) % TREAD_SPAN;
  for (let i = 0; i < treads.length; i++) { const k = i % TREAD_N; treads[i].position.z = TREAD_MIN + (((k * TREAD_SP - ph) % TREAD_SPAN) + TREAD_SPAN) % TREAD_SPAN; }
}
function simStep(dt) {
  simTime += dt;
  if (ctrl.desired !== null) { let d = ctrl.desired - state.heading; d = Math.atan2(Math.sin(d), Math.cos(d)); state.heading += d * Math.min(1, dt * 7); }
  state.speedNow += ((ctrl.moving ? UP.move : 0) - state.speedNow) * Math.min(1, dt * 5);
  dozer.position.x += Math.sin(state.heading) * state.speedNow * dt; dozer.position.z += Math.cos(state.heading) * state.speedNow * dt;
  resolveObstacles();
  dozer.rotation.y = state.heading; dozer.position.y = Math.sin(simTime * 20) * 0.02 * Math.min(1, state.speedNow / 3);
  animTracks(dt);
  pumpEngine();
  stepPhysics(dt); stepEconomy(dt); pumpClinks(dt);
  if (state.speedNow > 3.5 && rnd() < 0.6) emitDust(); updateParticles(dt);
}
/* ФИЗИКА: фикс-шаг 1/60 (детерминизм) + синк инстансов из тел Rapier */
const FIXED = 1 / 60, MAX_SUB = 5; let _acc = 0;
function bladeHX() { return 1.3 * (UP.bladeHalf / 1.6); }        // полуширина коллайдера = визуальная ширина ножа
// Нож = вертикальная стенка ДО земли (коллайдер отвязан от наклонного визуала — плоские диски top y≈0.17,
// иначе нож проходит НАД ними). Едет через setNextKinematic* → Rapier выводит скорость и сгребает монеты импульсом.
const BLADE_FWD = 1.62;   // нож впереди дозера (local z визуала)
function setKinematicPoses() {
  if (!phys) return;
  const h = state.heading, sn = Math.sin(h), cs = Math.cos(h), h2 = h * 0.5;
  const qy = { x: 0, y: Math.sin(h2), z: 0, w: Math.cos(h2) };   // yaw-only
  phys.setBladePose(dozer.position.x + sn * BLADE_FWD, 0.5, dozer.position.z + cs * BLADE_FWD, qy);   // стенка y∈[-0.05,1.05]
  phys.setChassisPose(dozer.position.x, 0, dozer.position.z, qy);   // тело в основании (y=0); коллайдеры со своими офсетами
}
function syncCoins() { for (let i = 0; i < N; i++) { if (C[i].st === 'free') continue; setMfromBody(i); } mesh.instanceMatrix.needsUpdate = true; }
let lastContacts = 0;
function stepPhysics(dt) {
  if (!phys) return;
  let cl = 0; const drain = () => phys.drainContacts(() => cl++);   // контакт-форс события (спящие монеты не генерят → нет спама в покое)
  if (TEST) { setKinematicPoses(); phys.step(); drain(); }                          // dt всегда 1/60 → 1 шаг/вызов, fp-точно
  else { _acc += dt; let n = 0; while (_acc >= FIXED && n < MAX_SUB) { setKinematicPoses(); phys.step(); drain(); _acc -= FIXED; n++; } }
  lastContacts = cl;
  if (cl > 0) addClinks(Math.min(CFG.clinkCap, Math.ceil(cl * CFG.clinkScale)));    // удар монет → звон (pumpClinks лимитит 25Гц)
  syncCoins();
}
/* ЭКОНОМИКА на телах: ворота ×N (читают позиции тел), ссып в пад → банк, состояние ворот */
function stepEconomy(dt) {
  if (!phys) return;
  for (let i = 0; i < N; i++) {                                                    // ворота: умножение worth + копии
    const o = C[i]; if (o.st === 'free') continue;
    if (o.gateCd > 0) o.gateCd -= dt;
    if (o.gateCd > 0 || o.worth >= 300) continue;
    const t = phys.coinPos(i); if (!t || t.y < -100) continue;
    for (const g of gates) {
      if (!g.active) continue;
      const gx = t.x - g.x, gz = t.z - g.z, along = gx * g.n.x + gz * g.n.z, lat = gx * g.right.x + gz * g.right.z;
      if (Math.abs(along) < 0.7 && Math.abs(lat) < g.halfW) {
        o.worth *= g.mult; o.gateCd = 0.7;
        const sp = Math.min(g.mult - 1, 3);
        for (let k = 0; k < sp; k++) { const fi = free.pop(); if (fi === undefined) break; const f = C[fi]; f.worth = o.worth; f.gateCd = 0.7; f.st = 'rest'; phys.enableCoin(fi); phys.setCoinTransform(fi, t.x + (rnd() - .5), THK * 0.5 + 1 + rnd(), t.z + (rnd() - .5)); }
        chime('gate'); popup(new THREE.Vector3(g.x, 2.6, g.z), '×' + g.mult, '#7fe6ff'); state.shake += 0.12; break;
      }
    }
  }
  for (const p of pads) {                                                          // пады: ссып → банк + апгрейд
    let cnt = 0;
    for (let i = 0; i < N; i++) {
      const o = C[i]; if (o.st === 'free') continue;
      const t = phys.coinPos(i); if (!t || t.y < -100) continue;
      if (Math.abs(t.x - p.x) < p.half && Math.abs(t.z - p.z) < p.half) { const v = o.worth * UP.mult; p.fill += v; state.bank += v; cnt++; placeAtSource(i); }
    }
    if (cnt > 0) {
      addClinks(Math.min(6, cnt)); emitSparks(p.x, p.z, Math.min(8, cnt));
      if (p.fill >= p.cost) { p.fill = 0; p.level++; p.cost = Math.round(p.cost * p.grow); p.apply(); chime('upgrade'); state.shake += 0.34; emitSparks(p.x, p.z, 22); drawLabel(p.lbl, 'UPGRADE', p.name + ' ' + fmt(p.cost), '#aef0c0'); p.ghost.scale.setScalar(1 + p.level * 0.06); }
    }
    { const r = Math.max(0.001, Math.min(1, p.fill / p.cost)); p.fillBar.scale.y = r; p.fillBar.position.y = p.BOT + p.GH * r * 0.5; }
  }
  for (const g of gates) { const a = state.bank >= g.cost; if (a !== g.active) { g.active = a; g.red.visible = !a; g.white.visible = a; } }   // red=locked / white=active
  updateBank();
}
function updateCamera(dt) {
  shadow.position.set(dozer.position.x, 0.04, dozer.position.z);
  state.shake *= Math.pow(0.0001, dt); const sh = state.shake;
  const a = CFG.camYaw, ca = Math.cos(a), sa = Math.sin(a);
  const sp = Math.min(1, state.speedNow / UP.move), back = CFG.camBack + sp * 0.8, hgt = CFG.camHeight + sp * 0.5;
  const ox = back * sa, oz = -back * ca, lx = -CFG.lookAhead * sa, lz = CFG.lookAhead * ca;
  camera.position.set(dozer.position.x + ox + (rnd() - .5) * sh, hgt + (rnd() - .5) * sh, dozer.position.z + oz);
  camera.lookAt(dozer.position.x + lx, 0, dozer.position.z + lz);
}
function renderFrame() { if (usePost) renderPost(); else renderer.render(scene, camera); }

/* Харнесс-API (детерминированный прогон под Playwright) */
window.__sim = {
  ready: false,
  step(dt) { if (state.phase === 'play') { applyScriptInput(); simStep(dt); } },
  run(n, dt) { dt = dt || 1 / 60; for (let i = 0; i < n; i++) this.step(dt); },
  setTarget(t) { _target = t; },
  setInput(o) { o = o || {}; if (o.heading != null) ctrl.desired = o.heading; ctrl.moving = !!o.driving; if ('target' in o) _target = o.target; },
  setPose(p) { dozer.position.x = p.x; dozer.position.z = p.z; state.heading = p.heading || 0; dozer.rotation.y = state.heading; },
  render() { updateCamera(0); renderFrame(); },
  get state() { return { x: dozer.position.x, z: dozer.position.z, heading: state.heading, bank: state.bank, speed: state.speedNow }; },
  get coinSum() { if (!phys) return 0; let s = 0; for (let i = 0; i < N; i++) { const t = phys.coinBodies[i].translation(); s += t.x * 1.1 + t.y * 1.7 + t.z * 2.3; } return s; },   // DEBUG детерминизм
  get contacts() { return lastContacts; },   // DEBUG контакт-события за шаг
  get coinStats() {   // DEBUG: где монеты относительно дозера
    if (!phys) return null; let n = 0, maxy = -1e9, airborne = 0, ahead = 0, maxv = 0, awake = 0, edge = 0, maxw = 0, scattered = 0, onbody = 0;
    const dx = dozer.position.x, dz = dozer.position.z, h = state.heading, sn = Math.sin(h), cs = Math.cos(h); const _up = new THREE.Vector3();
    for (let i = 0; i < N; i++) { if (C[i].st === 'free') continue; const b = phys.coinBodies[i]; const t = b.translation(); if (t.y < -100) continue; n++; maxy = Math.max(maxy, t.y); if (t.y > 2) airborne++; const rx = t.x - dx, rz = t.z - dz; if (rz > 0.5 && rz < 4 && Math.abs(rx) < 2) ahead++; const v = b.linvel(); maxv = Math.max(maxv, Math.hypot(v.x, v.y, v.z)); if (!b.isSleeping()) awake++; const r = b.rotation(); _up.set(0, 1, 0).applyQuaternion(_q.set(r.x, r.y, r.z, r.w)); if (Math.abs(_up.y) < 0.5) edge++; maxw = Math.max(maxw, C[i].worth); if (t.z > 14 && t.z < 52) scattered++; const lx = rx * cs - rz * sn, lz = rx * sn + rz * cs; if (Math.abs(lx) < 1.5 && lz > -1.6 && lz < 1.5 && t.y > 0.35) onbody++; }   // монета внутри/на корпусе = застряла
    return { n, maxy: +maxy.toFixed(1), airborne, ahead, awake, edge, maxw, scattered, onbody, maxv: +maxv.toFixed(1) };
  },
};

/* LOOP */
let last = performance.now();
function tick(now) {
  const dt = Math.min(0.04, (now - last) / 1000); last = now;
  if (state.phase === 'play' && !TEST) { applyLiveInput(); simStep(dt); }
  updateCamera(TEST ? 0 : dt); renderFrame();
  requestAnimationFrame(tick);
}
function resize() {
  camera.aspect = innerWidth / innerHeight; camera.updateProjectionMatrix(); renderer.setSize(innerWidth, innerHeight);
  if (usePost) { const w = Math.floor(innerWidth * Math.min(devicePixelRatio, 2)), h = Math.floor(innerHeight * Math.min(devicePixelRatio, 2)); rtScene.setSize(w, h); rtA.setSize(w >> 1, h >> 1); rtB.setSize(w >> 1, h >> 1); }
}
initBloom(); addEventListener('resize', resize); resize();
if (TEST) bootAndStart();   // авто-старт без кнопки/звука; ready флипнётся после await bootPhysics
requestAnimationFrame(tick);
