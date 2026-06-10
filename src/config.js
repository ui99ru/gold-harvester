// Детерминизм + конфиг. Override: window.__cfg или ?exposure=0.7 в URL.
export const QS = new URLSearchParams(location.search);
export const TEST = QS.has('test');

function mulberry32(a) {
  return function () {
    a |= 0; a = a + 0x6D2B79F5 | 0;
    let t = Math.imul(a ^ a >>> 15, 1 | a);
    t = t + Math.imul(t ^ t >>> 7, 61 | t) ^ t;
    return ((t ^ t >>> 14) >>> 0) / 4294967296;
  };
}
const _seed = TEST ? (Number(QS.get('seed')) || 1) : 0;
const _rng = _seed ? mulberry32(_seed) : Math.random;
export function rnd() { return _rng(); }   // СИМ-поток: только геймплей-значимое (respawn, копии). Seeded в ?test
const _rngv = _seed ? mulberry32(_seed ^ 0x9e3779b9) : Math.random;
export function rndv() { return _rngv(); }   // ВИЗУАЛ-поток: камера-шейк/пыль/искры — дёргается и в рендере (rAF), не должен сдвигать сим-поток

// Все «магические числа», которые крутит цикл сравнения (реф > ТЗ: лавандовый грунт, насыщенное золото).
export const CFG = {
  exposure: 0.92, bgColor: 0x7c6cb2, groundColor: 0x9c8fc0, fogNear: 120, fogFar: 360,
  fov: 40.5, camHeight: 45, camBack: 24.5, lookAhead: 11, camYaw: 0.66, gateRot: 0,   // КАЛИБРОВКА по рефу (tools/_calib.py, 42 кадра): pitch 51.7°, yaw 37.8°, roll≈0, ворота ⊥ коридору
  sunInt: 1.5, hemiInt: 1.15,   // ярче, насыщеннее — «праздник», не пасмурно
  coinColor: 0xffb42e, coinMetal: 0.42, coinRough: 0.36, coinEmissive: 0xc06a00, coinEmInt: 0.27,   // золото: меньше металл/envMap → чистый оранж (не синит от пурпурной среды)
  dozerColor: 0x1c1748, scoopColor: 0x2a5070,   // реф: тёмный индиго-корпус, стально-голубой ковш (тюн по пиксель-сэмплам f_0260)
  gateCurtain: 0x5ac8ff, gateGlow: 0x39c8ff,
  bloomThr: 0.86, bloomInten: 0.38,
  // Физика монет (Rapier) — главные регуляторы «ощущения тяжёлого металла», все скаляры → свип через ?key=.
  gravityY: -30, coinDensity: 9.0, coinFriction: 0.95, coinRestitution: 0.02, linDamp: 0.8, angDamp: 0.9, contactThr: 50, coinMaxV: 12,
  clinkCap: 3, clinkScale: 0.05, clinkV: 3.0,   // звон: макс дзынь/кадр, масштаб, порог «удара» (выше → скольжение/оседание молчит)
  calmV: 1.2, calmW: 6.0, calmFrames: 18, calmVy: 0.4, calmFlat: 0.45, flattenK: 8,   // деадзона + активный «завал» монеты с ребра (угл.скорость к плашмя)
  gate1cost: 10, gate2cost: 600, upgradeCost: 120, startCoins: 5,   // разблок ворот накоплением / старт 5 монет
  laneHalf: 2.8, srcR: 0.8,          // перенос: полуширина коридора-стенок / радиус источника (узкий → нож ловит все)
  move: 10,   // скорость дозера (она же цель апгрейда); низкая → монеты успевают сгрестись, не разлетаются
};
const _o = window.__cfg || {};
for (const k in _o) if (k in CFG) CFG[k] = _o[k];
for (const [k, v] of QS) { if (k in CFG) { const n = Number(v); if (!Number.isNaN(n)) CFG[k] = n; } }
