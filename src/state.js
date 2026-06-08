// Общие мутабельные синглтоны игры.
export const UP = { bladeHalf: 1.6, reach: 2.7, move: 10, mult: 1 };   // апгрейды
export const state = { phase: 'start', bank: 0, heading: 0, driving: false, speedNow: 0, shake: 0 };

export function fmt(n) {
  n = Math.round(n);
  if (n >= 1e9) return (n / 1e9).toFixed(2) + 'B';
  if (n >= 1e6) return (n / 1e6).toFixed(2) + 'M';
  if (n >= 1e3) return (n / 1e3).toFixed(1) + 'k';
  return '' + n;
}
