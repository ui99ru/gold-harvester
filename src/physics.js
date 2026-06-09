// Rapier-мир: тела монет (динамика), кинематические нож/шасси «грабли», контакты.
// Импортит ТОЛЬКО config (лист) — НЕ знает THREE/геймплея, отдаёт голые числа.
// main.js → physics.js (односторонняя стрелка, цикла нет).
import RAPIER from '@dimforge/rapier3d-compat';

// initPhysics({count,thk,rad,gravity,timestep, density,friction,restitution,linDamp,angDamp,contactThreshold})
// → Promise<PhysicsWorld> (методы замыкают мир Rapier).
export async function initPhysics(opt) {
  const { count, thk, rad } = opt;
  const gravity = opt.gravity || [0, -30, 0];
  const timestep = opt.timestep || 1 / 60;
  const dens = opt.density ?? 8.0, fric = opt.friction ?? 0.9, rest = opt.restitution ?? 0.08;
  const linDamp = opt.linDamp ?? 0.4, angDamp = opt.angDamp ?? 0.6, contactThr = opt.contactThreshold ?? 50;
  const maxv = opt.maxv ?? 0, maxv2 = maxv * maxv;   // потолок скорости монеты (тяжёлый диск не «улетает мячом»); 0=выкл
  // Принудительный сон почти-неподвижных: гасит «вечную качку» монеты на ребре (солвер-джиттер не даёт уснуть штатно).
  const calmV2 = (opt.calmV ?? 0.25) ** 2, calmW2 = (opt.calmW ?? 0.6) ** 2, calmFrames = opt.calmFrames ?? 22, calmVy = opt.calmVy ?? 0.4;

  await RAPIER.init();   // async WASM (base64 инлайн в -compat → без сети под file://)

  const world = new RAPIER.World({ x: gravity[0], y: gravity[1], z: gravity[2] });
  world.timestep = timestep;
  world.integrationParameters.numSolverIterations = opt.solverIters ?? 8;   // больше итераций → меньше остаточного джиттера в плотной куче
  const eventQueue = new RAPIER.EventQueue(true);

  // Земля: толстый фикс-куб, верх в y=0 (halfspace в 0.19 отсутствует).
  const groundBody = world.createRigidBody(RAPIER.RigidBodyDesc.fixed().setTranslation(0, -1, 0));
  world.createCollider(RAPIER.ColliderDesc.cuboid(300, 1, 300).setFriction(1.0).setRestitution(0), groundBody);

  const coinBodies = new Array(count).fill(null);   // ручки тел монет (НЕ в C[] main.js — держим C[] без THREE/физики)
  const still = new Int16Array(count);              // счётчик кадров «почти неподвижна» → принудительный сон
  const _ZERO = { x: 0, y: 0, z: 0 };

  // ── Монеты ───────────────────────────────────────────────────────────────
  // Создать раз, переиспользовать (пул). Цилиндр Rapier ось = local Y = ось CylinderGeometry → синк без смены базиса.
  function addCoinBody(i, x, y, z, q) {
    const bd = RAPIER.RigidBodyDesc.dynamic().setTranslation(x, y, z)
      .setLinearDamping(linDamp).setAngularDamping(angDamp).setCcdEnabled(false);
    if (q) bd.setRotation(q);
    const b = world.createRigidBody(bd);
    const cd = RAPIER.ColliderDesc.cylinder(thk / 2, rad)
      .setDensity(dens).setFriction(fric).setRestitution(rest)
      .setActiveEvents(RAPIER.ActiveEvents.CONTACT_FORCE_EVENTS)
      .setContactForceEventThreshold(contactThr);
    world.createCollider(cd, b);
    coinBodies[i] = b;
    return b;
  }
  // recycle (респаун в источник / ссып в пад): телепорт + обнулить скорости + разбудить.
  function setCoinTransform(i, x, y, z, q) {
    const b = coinBodies[i]; if (!b) return;
    b.setTranslation({ x, y, z }, true);
    if (q) b.setRotation(q, true);
    b.setLinvel({ x: 0, y: 0, z: 0 }, true);
    b.setAngvel({ x: 0, y: 0, z: 0 }, true);
    b.wakeUp();
  }
  function hideCoin(i) {   // пул: убрать из симуляции + припарковать вне поля
    const b = coinBodies[i]; if (!b) return;
    b.setLinvel({ x: 0, y: 0, z: 0 }, false); b.setAngvel({ x: 0, y: 0, z: 0 }, false);
    b.setTranslation({ x: 0, y: -999, z: 0 }, false);
    b.sleep(); b.setEnabled(false);
  }
  function enableCoin(i) { const b = coinBodies[i]; if (!b) return; b.setEnabled(true); b.wakeUp(); }
  // читать позу в переданные THREE-объекты (duck-typing .set — physics.js не импортит THREE).
  function readCoin(i, outPos, outQuat) {
    const b = coinBodies[i]; if (!b) return false;
    const t = b.translation(); outPos.set(t.x, t.y, t.z);
    const r = b.rotation(); outQuat.set(r.x, r.y, r.z, r.w);
    return true;
  }
  function coinPos(i) { const b = coinBodies[i]; return b ? b.translation() : null; }
  function isEnabled(i) { const b = coinBodies[i]; return b ? b.isEnabled() : false; }

  // Стенка-коллайдер (fixed): коридор удерживает монеты в полосе ворот (дозер кинематический → проходит сквозь).
  function addWall(cx, cy, cz, hx, hy, hz) {
    const b = world.createRigidBody(RAPIER.RigidBodyDesc.fixed().setTranslation(cx, cy, cz));
    world.createCollider(RAPIER.ColliderDesc.cuboid(hx, hy, hz).setFriction(0.3).setRestitution(0), b);
  }

  // ── Кинематика: нож-плуг + шасси «грабли» ────────────────────────────────
  let bladeBody = null, bladeColliders = [], chassisBody = null;
  const yquat = (a) => ({ x: 0, y: Math.sin(a / 2), z: 0, w: Math.cos(a / 2) });
  // Вогнутый отвал: центр-стенка + 2 крыла вперёд-внутрь (toe-in) → диски сходятся к центру, не брызгают вбок.
  function buildPlow(hx, hy, hz, wing, ang) {
    const mk = (cd) => bladeColliders.push(world.createCollider(cd.setFriction(0.8).setRestitution(0.05), bladeBody));
    mk(RAPIER.ColliderDesc.cuboid(hx, hy, hz));                                                                   // центр
    for (const s of [-1, 1]) mk(RAPIER.ColliderDesc.cuboid(hz, hy, wing).setTranslation(s * hx, 0, wing * 0.92).setRotation(yquat(-s * ang)));   // крылья
  }
  function addBlade(hx, hy, hz, wing, ang) {
    bladeBody = world.createRigidBody(RAPIER.RigidBodyDesc.kinematicPositionBased().setTranslation(0, -50, 0));
    buildPlow(hx, hy, hz, wing, ang);
  }
  function rebuildBladeCollider(hx, hy, hz, wing, ang) {   // апгрейд «НОЖ»: редко → destroy/recreate ок
    if (!bladeBody) return;
    for (const c of bladeColliders) world.removeCollider(c, false);
    bladeColliders = []; buildPlow(hx, hy, hz, wing, ang);
  }
  // boxes: [{hx,hy,hz, cx,cy,cz}] — несколько коллайдеров на одном кинематическом теле (тело в основании дозера, y=0).
  function addChassis(boxes) {
    chassisBody = world.createRigidBody(RAPIER.RigidBodyDesc.kinematicPositionBased().setTranslation(0, -50, 0));
    for (const b of boxes) { const cd = RAPIER.ColliderDesc.cuboid(b.hx, b.hy, b.hz).setFriction(0.5).setRestitution(0).setTranslation(b.cx || 0, b.cy || 0, b.cz || 0); world.createCollider(cd, chassisBody); }
  }
  // двигать через setNextKinematic* (НЕ setTranslation — иначе ноль импульса монетам → мёртвое сгребание).
  function setBladePose(x, y, z, q) { if (!bladeBody) return; bladeBody.setNextKinematicTranslation({ x, y, z }); if (q) bladeBody.setNextKinematicRotation(q); }
  function setChassisPose(x, y, z, q) { if (!chassisBody) return; chassisBody.setNextKinematicTranslation({ x, y, z }); if (q) chassisBody.setNextKinematicRotation(q); }

  // ── Шаг + контакты ───────────────────────────────────────────────────────
  function step() {
    world.step(eventQueue);
    for (let i = 0; i < count; i++) {
      const b = coinBodies[i]; if (!b || !b.isEnabled() || b.isSleeping()) { still[i] = 0; continue; }
      const v = b.linvel(); let s = v.x * v.x + v.y * v.y + v.z * v.z;
      if (maxv2 && s > maxv2) { const k = maxv / Math.sqrt(s); b.setLinvel({ x: v.x * k, y: v.y * k, z: v.z * k }, false); s = maxv2; }
      const w = b.angvel(); const sw = w.x * w.x + w.y * w.y + w.z * w.z;
      // Деадзона КАЖДЫЙ кадр для покоящихся (гасим качку прямо — island-сон не спасает, сосед будит).
      // |v.y|<calmVy отсекает ПАДАЮЩИЕ (у них v.y≈ g·dt), чтобы не заморозить в воздухе. Сон после calmFrames — экономия CPU.
      if (s < calmV2 && sw < calmW2 && Math.abs(v.y) < calmVy) {
        b.setLinvel(_ZERO, false); b.setAngvel(_ZERO, false);
        if (++still[i] >= calmFrames) { b.sleep(); still[i] = 0; }
      } else still[i] = 0;
    }
  }
  // cb(forceMagnitude) на каждый контакт-форс-эвент выше порога.
  function drainContacts(cb) { eventQueue.drainContactForceEvents(e => cb(e.totalForceMagnitude())); }

  return {
    addCoinBody, setCoinTransform, hideCoin, enableCoin, readCoin, coinPos, isEnabled,
    addWall, addBlade, rebuildBladeCollider, addChassis, setBladePose, setChassisPose,
    step, drainContacts,
    world, coinBodies, RAPIER,
  };
}
