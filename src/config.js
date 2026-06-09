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
export function rnd() { return _rng(); }   // = Math.random в обычном режиме, seeded в ?test

// Все «магические числа», которые крутит цикл сравнения (реф > ТЗ: лавандовый грунт, насыщенное золото).
export const CFG = {
  exposure: 0.86, bgColor: 0x6a5aa0, groundColor: 0x7257ac, fogNear: 120, fogFar: 360,
  fov: 47, camHeight: 24, camBack: 17, lookAhead: 7, camYaw: -0.6,   // круче наклон → горизонта нет, площадка «завалена» на зрителя
  sunInt: 1.5, hemiInt: 1.15,   // ярче, насыщеннее — «праздник», не пасмурно
  coinColor: 0xffc63c, coinMetal: 0.55, coinRough: 0.30, coinEmissive: 0x9c5a00, coinEmInt: 0.10,   // яркое светлое золото (металл + блик), не латунь
  gateCurtain: 0x5ac8ff, gateGlow: 0x39c8ff,
  bloomThr: 0.82, bloomInten: 0.5,
  // Физика монет (Rapier) — главные регуляторы «ощущения тяжёлого металла», все скаляры → свип через ?key=.
  gravityY: -30, coinDensity: 9.0, coinFriction: 0.95, coinRestitution: 0.02, linDamp: 0.8, angDamp: 0.9, contactThr: 50, coinMaxV: 12,
  clinkCap: 4, clinkScale: 0.1, clinkV: 0.6,   // звон: макс дзынь/кадр, масштаб от числа ударов, порог скорости «удара»
  calmV: 1.2, calmW: 6.0, calmFrames: 18, calmVy: 0.4,   // деадзона покоящейся монеты: лин./угл. порог + |v.y| (отсекает падающие)
  gate1cost: 150, gate2cost: 2500,   // порог разблокировки ворот (для тестов/тюна)
  laneHalf: 2.8, srcR: 2.4,          // перенос: полуширина коридора-стенок / радиус разброса источника
  bladeWing: 0.5, bladeWingAng: 0.3,    // вогнутый отвал: длина крыла / угол toe-in (рад) — крылья меньше
  move: 10,   // скорость дозера (она же цель апгрейда); низкая → монеты успевают сгрестись, не разлетаются
};
const _o = window.__cfg || {};
for (const k in _o) if (k in CFG) CFG[k] = _o[k];
for (const [k, v] of QS) { if (k in CFG) { const n = Number(v); if (!Number.isNaN(n)) CFG[k] = n; } }
