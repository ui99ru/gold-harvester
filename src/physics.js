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
  const calmV2 = (opt.calmV ?? 0.25) ** 2, calmW2 = (opt.calmW ?? 0.6) ** 2, calmFrames = opt.calmFrames ?? 22, calmVy = opt.calmVy ?? 0.4, calmFlat = opt.calmFlat ?? 0.45, flattenK = opt.flattenK ?? 8;
  const calmFlatG = opt.calmFlatG ?? calmFlat, calmGY = opt.calmGroundY ?? 0.6;   // нижний слой (без опоры кучи): порог «плашмя» жёстче — наклонную у земли валим, в куче разрешаем спать

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
  // recycle (респаун в источник / ссып в пад / волна из ворот): телепорт + скорости (по умолч. ноль) + разбудить.
  function setCoinTransform(i, x, y, z, q, vel, ang) {
    const b = coinBodies[i]; if (!b) return;
    b.setTranslation({ x, y, z }, true);
    if (q) b.setRotation(q, true);
    b.setLinvel(vel || { x: 0, y: 0, z: 0 }, true);
    b.setAngvel(ang || { x: 0, y: 0, z: 0 }, true);
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
  function coinVel(i) { const b = coinBodies[i]; return b ? b.linvel() : null; }
  function isEnabled(i) { const b = coinBodies[i]; return b ? b.isEnabled() : false; }

  // Стенка-коллайдер (fixed): коридор удерживает монеты в полосе ворот (дозер кинематический → проходит сквозь).
  function addWall(cx, cy, cz, hx, hy, hz) {
    const b = world.createRigidBody(RAPIER.RigidBodyDesc.fixed().setTranslation(cx, cy, cz));
    world.createCollider(RAPIER.ColliderDesc.cuboid(hx, hy, hz).setFriction(0.3).setRestitution(0), b);
  }

  // ── Кинематика: ковш-совок + шасси ───────────────────────────────────────
  let bladeBody = null, bladeColliders = [], chassisBody = null;
  const xquat = (a) => ({ x: Math.sin(a / 2), y: 0, z: 0, w: Math.cos(a / 2) });
  // Ковш-корыто (C-профиль): дно сегментами дуги загибается в высокую вогнутую спинку, сплошные щёки,
  // передняя кромка до земли (монеты заезжают внутрь). Тело на y=0, офсеты в коллайдерах.
  function buildPlow(hx) {
    const mk = (cd) => bladeColliders.push(world.createCollider(cd.setFriction(0.8).setRestitution(0.05), bladeBody));
    // профиль чаши = 2 хорды по визуальной цепочке: U-низ (дно→стенка) + верх (стенка→козырёк)
    mk(RAPIER.ColliderDesc.cuboid(hx, 0.47, 0.06).setTranslation(0, 0.37, 0.37).setRotation(xquat(-0.755)));
    mk(RAPIER.ColliderDesc.cuboid(hx, 0.32, 0.06).setTranslation(0, 0.985, 0.18).setRotation(xquat(0.398)));
    mk(RAPIER.ColliderDesc.cuboid(hx + 0.05, 0.03, 0.42).setTranslation(0, 0.03, 1.05));                            // дно (верх ~0.06)
    mk(RAPIER.ColliderDesc.cuboid(hx + 0.05, 0.02, 0.20).setTranslation(0, 0.012, 1.62).setRotation(xquat(0.12)));  // кромка до земли
    for (const s of [-1, 1]) {                                                                                       // боковые стенки полной высоты (реф-ковш) + передний низкий сегмент
      mk(RAPIER.ColliderDesc.cuboid(0.05, 0.60, 0.55).setTranslation(s * (hx + 0.03), 0.65, 0.35));
      mk(RAPIER.ColliderDesc.cuboid(0.05, 0.16, 0.45).setTranslation(s * (hx + 0.03), 0.16, 1.2));
    }
  }
  function addBlade(hx) {
    bladeBody = world.createRigidBody(RAPIER.RigidBodyDesc.kinematicPositionBased().setTranslation(0, -50, 0));
    buildPlow(hx);
  }
  function rebuildBladeCollider(hx) {   // апгрейд «НОЖ»: редко → destroy/recreate ок
    if (!bladeBody) return;
    for (const c of bladeColliders) world.removeCollider(c, false);
    bladeColliders = []; buildPlow(hx);
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
  const clinkV2 = (opt.clinkV ?? 0.6) ** 2;
  function bodySpeed2(handle) { const c = world.getCollider(handle); const b = c && c.parent(); if (!b) return 0; const v = b.linvel(); return v.x * v.x + v.y * v.y + v.z * v.z; }
  function step() {
    world.step(eventQueue);
    for (let i = 0; i < count; i++) {
      const b = coinBodies[i]; if (!b || !b.isEnabled() || b.isSleeping()) { still[i] = 0; continue; }
      const v = b.linvel(); let s = v.x * v.x + v.y * v.y + v.z * v.z;
      if (maxv2 && s > maxv2) { const k = maxv / Math.sqrt(s); b.setLinvel({ x: v.x * k, y: v.y * k, z: v.z * k }, false); s = maxv2; }
      const w = b.angvel(); const sw = w.x * w.x + w.y * w.y + w.z * w.z;
      const r = b.rotation();   // ось монеты R·(0,1,0): плашмя ≈ |upy|→1, на ребре ≈ upy→0
      const upx = 2 * (r.x * r.y - r.w * r.z), upy = 1 - 2 * (r.x * r.x + r.z * r.z), upz = 2 * (r.y * r.z + r.w * r.x);
      if (s < calmV2 && sw < calmW2 && Math.abs(v.y) < calmVy) {
        const flatThr = b.translation().y < calmGY ? calmFlatG : calmFlat;   // у земли «на ребре под углом» не бывает — валим
        if (Math.abs(upy) > flatThr) {             // лежит плашмя → заморозить (деадзона + сон)
          b.setLinvel(_ZERO, false); b.setAngvel(_ZERO, false);
          if (++still[i] >= calmFrames) { b.sleep(); still[i] = 0; }
        } else {                                   // почти стоит на ребре → активный «завал»: угл.скорость к мировому верху (up × Y)
          still[i] = 0; b.setAngvel({ x: -flattenK * upz, y: 0, z: flattenK * upx }, true);
        }
      } else still[i] = 0;
    }
  }
  // cb() на удар, где хотя бы одно тело реально движется (>clinkV). Покоящийся вес кучи (v=0 от деадзоны) — НЕ звенит.
  function drainContacts(cb) { eventQueue.drainContactForceEvents(e => { if (Math.max(bodySpeed2(e.collider1()), bodySpeed2(e.collider2())) > clinkV2) cb(); }); }

  return {
    addCoinBody, setCoinTransform, hideCoin, enableCoin, readCoin, coinPos, coinVel, isEnabled,
    addWall, addBlade, rebuildBladeCollider, addChassis, setBladePose, setChassisPose,
    step, drainContacts,
    world, coinBodies, RAPIER,
  };
}
