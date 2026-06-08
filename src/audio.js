// Процедурный звук: двигатель (тарахтенье / опц. луп-сэмпл), звон монет, джинглы.
import { state, UP } from './state.js';

let AC = null, master = null, engineGain = null, engineBed = null, engineBedOsc = null, muted = false;
let engineSrc = null, engineLoopGain = null, engineLoopReady = false;

export function audioInit() {
  if (AC) { if (AC.state === 'suspended') AC.resume(); return; }
  AC = new (window.AudioContext || window.webkitAudioContext)();
  master = AC.createGain(); master.gain.value = 0.5; master.connect(AC.destination);
  engineGain = AC.createGain(); engineGain.gain.value = 0.85; engineGain.connect(master);   // шина двигателя
  // непрерывный НЧ-«корпус» мотора — сливает импульсы в двигатель, а не в барабанную дробь
  const bed = AC.createOscillator(); bed.type = 'sawtooth'; bed.frequency.value = 78;
  const blp = AC.createBiquadFilter(); blp.type = 'lowpass'; blp.frequency.value = 240;
  engineBed = AC.createGain(); engineBed.gain.value = 0; bed.connect(blp); blp.connect(engineBed); engineBed.connect(engineGain); bed.start(); engineBedOsc = bed;
  if (window.__ENGINE_LOOP) {                                  // опц. локальный луп двигателя (приоритет над синтезом)
    engineLoopGain = AC.createGain(); engineLoopGain.gain.value = 0; engineLoopGain.connect(engineGain);
    fetch(window.__ENGINE_LOOP).then(r => r.arrayBuffer()).then(b => AC.decodeAudioData(b)).then(buf => {
      engineSrc = AC.createBufferSource(); engineSrc.buffer = buf; engineSrc.loop = true; engineSrc.connect(engineLoopGain); engineSrc.start(); engineLoopReady = true;
    }).catch(() => { engineLoopReady = false; });
  }
}

// одиночный «туп» зажигания (замер рефа: фундамент ~78, яркий клаттер ~2200, ВЧ ~13к)
function putt(t, pitch, amp) {
  const o = AC.createOscillator(); o.type = 'square'; o.frequency.value = pitch;
  const lp = AC.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 700;
  const g = AC.createGain(); g.gain.setValueAtTime(0.0001, t); g.gain.exponentialRampToValueAtTime(amp * 0.9, t + 0.004); g.gain.exponentialRampToValueAtTime(0.0006, t + 0.07);
  o.connect(lp); lp.connect(g); g.connect(engineGain); o.start(t); o.stop(t + 0.1);
  const L = 900, nb = AC.createBuffer(1, L, AC.sampleRate), dd = nb.getChannelData(0); for (let i = 0; i < L; i++) dd[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / L, 3);
  const ns = AC.createBufferSource(); ns.buffer = nb; const bp = AC.createBiquadFilter(); bp.type = 'bandpass'; bp.frequency.value = 2200; bp.Q.value = 0.8;
  const ng = AC.createGain(); ng.gain.value = amp * 0.5; ns.connect(bp); bp.connect(ng); ng.connect(engineGain); ns.start(t);
  const L2 = 200, n2 = AC.createBuffer(1, L2, AC.sampleRate), d2 = n2.getChannelData(0); for (let i = 0; i < L2; i++) d2[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / L2, 4);
  const s2 = AC.createBufferSource(); s2.buffer = n2; const hp = AC.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 9000;
  const g2 = AC.createGain(); g2.gain.value = amp * 0.18; s2.connect(hp); hp.connect(g2); g2.connect(engineGain); s2.start(t);
}
let enginePuttNext = 0;
export function pumpEngine() {   // тарахтенье: неровный темп 6..10/с, скорость = питч + «корпус»
  if (!AC || muted || state.phase !== 'play') return;
  const tnow = AC.currentTime, look = 0.14, sp = Math.min(1, state.speedNow / UP.move);
  if (engineLoopReady) { engineLoopGain.gain.value = 0.55 + sp * 0.45; engineSrc.playbackRate.value = 0.9 + sp * 0.5; if (engineBed) engineBed.gain.value = 0; return; }
  const rate = 6 + sp * 4, pitch = 74 + sp * 16, amp = 0.5 + sp * 0.4;
  if (engineBed) { engineBed.gain.value = 0.05 + sp * 0.14; if (engineBedOsc) engineBedOsc.frequency.value = 74 + sp * 16; }
  if (enginePuttNext < tnow) enginePuttNext = tnow;
  while (enginePuttNext < tnow + look) { putt(enginePuttNext, pitch + (Math.random() - .5) * 3, amp * (0.8 + Math.random() * 0.4)); enginePuttNext += (1 / rate) * (0.82 + Math.random() * 0.36); }
}

function clink() {
  if (!AC || muted) return; const t = AC.currentTime, base = 2100 + Math.random() * 900;
  [[1, .5], [1.5, .22], [2.3, .14], [3.4, .08]].forEach(([r, a]) => {
    const o = AC.createOscillator(); o.type = 'triangle'; o.frequency.value = base * r;
    const g = AC.createGain(); const amp = a * (0.5 + Math.random() * 0.5); g.gain.setValueAtTime(0, t); g.gain.linearRampToValueAtTime(amp, t + 0.002);
    g.gain.exponentialRampToValueAtTime(0.0004, t + 0.06 + Math.random() * 0.06); o.connect(g); g.connect(master); o.start(t); o.stop(t + 0.16);
  });
  const tg = AC.createOscillator(); tg.type = 'sine'; tg.frequency.value = 9000 + Math.random() * 3000; const tgg = AC.createGain();
  tgg.gain.setValueAtTime(0.14, t); tgg.gain.exponentialRampToValueAtTime(0.0003, t + 0.05); tg.connect(tgg); tgg.connect(master); tg.start(t); tg.stop(t + 0.07);
  const len = 240, nb = AC.createBuffer(1, len, AC.sampleRate), d = nb.getChannelData(0); for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * Math.pow(1 - i / len, 3);
  const ns = AC.createBufferSource(); ns.buffer = nb; const hp = AC.createBiquadFilter(); hp.type = 'highpass'; hp.frequency.value = 4500;
  const ng = AC.createGain(); ng.gain.value = 0.16; ns.connect(hp); hp.connect(ng); ng.connect(master); ns.start(t);
}
export function chime(kind) {
  if (!AC || muted) return; const t = AC.currentTime; const notes = kind === 'gate' ? [660, 990, 1320] : [523, 659, 784, 1047];
  notes.forEach((f, i) => {
    const o = AC.createOscillator(); o.type = 'triangle'; o.frequency.value = f; const g = AC.createGain(); const st = t + i * 0.05;
    g.gain.setValueAtTime(0, st); g.gain.linearRampToValueAtTime(0.26, st + 0.01); g.gain.exponentialRampToValueAtTime(0.0004, st + 0.32); o.connect(g); g.connect(master); o.start(st); o.stop(st + 0.36);
  });
}
let pendingClinks = 0, clinkAcc = 0;
export function addClinks(n) { pendingClinks = Math.min(20, pendingClinks + n); }
export function pumpClinks(dt) { clinkAcc += dt; while (pendingClinks > 0 && clinkAcc >= 0.04) { clinkAcc -= 0.04; pendingClinks--; clink(); } }
export function toggleMute() { muted = !muted; if (engineGain) engineGain.gain.value = muted ? 0 : 0.85; return muted; }
