class_name Game
extends Node3D
## Игра «Золотодозер»: оркестратор. Порт src/main.js на Godot.
## Порядок сим-шага повторяет web simStep: ввод → дозер → кинематик-позы →
## [физика движком] → экономика → клинки → частицы. Карта — данные (levels/*.tres).

const LEVEL := preload("res://levels/level_01.tres")
const DOZER_R := 1.6
const BLADE_R := 0.35

# --- Мутабельное состояние (web: src/state.js) ---
var up_blade_half := CFG.UP_BLADE_HALF
var up_reach := CFG.UP_REACH
var up_move := CFG.MOVE
var up_mult := CFG.UP_MULT

var phase := "start"     # start | play
var bank := 0

# B2: авто-адаптивный кэп активных тел (AIMD). Гидрация держит active≈cap, волна
# ворот множит под budget_left — так «изобилие» (декор) не утягивает физику. На
# слабом железе cap сам сожмётся (physics > target). --cap=N замораживает контроллер.
var cap := 0
var _phys_ema := 0.0
var _cap_frozen := false
var _cap_override := 0
var heading := 0.0
var driving := false
var speed_now := 0.0
var shake := 0.0
var cam_zoom := 1.0

# --- Два RNG-потока (web: rnd сим / rndv визуал) ---
var rng_sim := RandomNumberGenerator.new()
var rng_vis := RandomNumberGenerator.new()
var test_mode := false   # детерминированный прогон: камера без тряски

var level: LevelDef
var camera: Camera3D
var sun: DirectionalLight3D
var world_env: Environment
var shot: ShotTool
var dozer: Dozer
var dozer_shadow: MeshInstance3D
var pool: CoinPool
var clinks: ClinkAudio
var audio: GameAudio
var fx: Fx
var gates: Array[Gate] = []
var pads: Array[UpgradePad] = []
var trash_pads: Array[TrashPad] = []

# Сущности (ворота, этап 6) сбрасывают side-регистрацию телепортированной монеты
var side_resetters: Array[Callable] = []

var _bank_label: Label
var _bank_shown := 0.0
var _start_overlay: Control

# AABB-препятствия дозера: {x0,x1,z0,z1, post:bool}. Регистрируют сущности
# (столбы ворот post=true, стойки падов post=false); web main.js:340-353.
var obstacles: Array[Dictionary] = []
# Зоны подъёма (маты падов/запертых ворот, h=0.2): {x,z,hx,hz}; web :334-338.
var lift_zones: Array[Dictionary] = []

var sim_time := 0.0
var ground_lift := 0.0

# Ввод (web ctrl: desired-курс + движение)
var ctrl_desired := NAN
var ctrl_moving := false

var _joy: VirtualJoystick   # виртуальный джойстик (мобильное управление)
var _script_target := Vector3.INF   # сценарная цель (смоуки; web __sim.setTarget)
var _smoke_mode := ""
var _smoke_ticks := 0
var _smoke_violations := 0
var _phys_accum := 0.0
var _phys_max := 0.0
var _active_prev := 0
var _max_spawn_burst := 0
var _loop_dir := 1
var _loop_laps := 0
var _loop_nodes0 := 0
var _hydrate_total := 0   # B1: всего гидраций за прогон (диагностика + смоук)
var _hydrate_seeded := 0  # B1 smoke-hydrate: сколько dormant засеяно
var _smoke_gd_max := 0    # B1 smoke-evac: макс мкс GDScript-сима за тик (кап спайка)
var _pool_size_override := 0
var _probe := false        # авто-телеметрия (--probe): loop-автопилот + Telemetry
var _probe_s := 120.0      # длительность авто-прогона в РЕАЛЬНЫХ секундах (--probe-s=)
var _probe_seed := 0       # B1: засеять N dormant-монет в probe (изобилие; --probe-seed=N)
# B6: probe-оверрайды рендера для замера на телефоне. НЕ меняют дефолты (тени/MSAA
# уже однажды меняли «без согласования» и откатили) — только инструмент для A/B.
var _ovr_msaa := -1        # --no-msaa → 0 (MSAA off); -1 = дефолт проекта (2x)
var _ovr_shadow := -1      # --no-shadow → 0 (тень солнца off); -1 = дефолт (on)
var _ovr_scale := 0.0      # --render-scale=X → scaling_3d_scale; 0 = дефолт (нативное)
var _ovr_glow := -1        # --no-glow → 0 (bloom off); -1 = дефолт (on)
var _gd_accum := 0
var _sim_us_last := 0   # мкс GDScript-сима за последний физ-тик → split «jolt/gd» в HUD
var _coin_mm: MultiMeshInstance3D   # общий рендер монет (как web InstancedMesh), инстанс = coin.idx
var _dormant: CoinDormant   # B1: декор-слой монет без физ-тел (изобилие); гидра/дегидра у дозера
# Скрытый инстанс MultiMesh: крошечный масштаб + далеко (вырождается → не рисуется).
var _HIDDEN_XF := Transform3D(
	Basis(Vector3(0.0001, 0, 0), Vector3(0, 0.0001, 0), Vector3(0, 0, 0.0001)),
	Vector3(0, -9999, 0))

# Калибровка света по web-эталону (--cal=sun,ambient): множители энергий.
var _cal_sun := 1.0
var _cal_amb := 1.0

# Поза дозера на старте (--pose= может переопределить до постройки)
var dozer_pos := Vector3.ZERO


func _ready() -> void:
	level = LEVEL
	dozer_pos = level.dozer_start
	_parse_user_args()  # может переопределить позу (--pose=)
	_build_environment()
	_build_ground_and_rocks()
	_build_walls()
	_build_dozer()
	_build_camera()
	clinks = ClinkAudio.new()
	add_child(clinks)
	audio = GameAudio.new()
	add_child(audio)
	fx = Fx.new()
	fx.game = self
	add_child(fx)
	pool = CoinPool.new()
	pool.name = "Coins"
	add_child(pool)
	pool.setup(_pool_size_override if _pool_size_override > 0 else CFG.COIN_N, _on_coin_clink)
	pool.spawn_resetters = side_resetters  # spawn() чистит stale side[] (ворота добавят сброс ниже, та же ссылка)
	cap = mini(_cap_override if _cap_frozen else CFG.CAP_START, pool.size)  # B2: кэп ≤ размер пула (иначе нож-призрак при --cap>пул)
	_build_coin_multimesh()  # общий рендер всех монет одним MultiMesh
	_build_dormant_field()   # B1: декор-слой dormant-монет (изобилие без физ-тел)
	_build_entities()
	_build_bank_ui()
	for i in level.start_coins:
		place_at_source(pool.spawn(Vector3.ZERO, false))
	shot = ShotTool.new()
	shot.info_cb = func() -> String:
		return "bank=%d dozer=%s heading=%.2f zoom=%.2f coins=%d" % [
			bank, dozer.position, heading, cam_zoom, pool.active_count()]
	add_child(shot)
	_build_hud_and_menu()
	# Авто-старт в харнесс-режимах; иначе — стартовый экран
	if test_mode or not OS.get_cmdline_user_args().is_empty():
		phase = "play"
		_start_overlay.visible = false
	_setup_smoke()
	_apply_render_overrides()  # B6 probe: viewport MSAA/render-scale (после HUD; дефолты не тронуты)
	if _probe:
		_start_probe()
	_update_camera(0.0)


## B6 probe-only: применить оверрайды рендера для A/B-замера на телефоне. Дефолты
## проекта (MSAA 2x, нативный скейл) не меняем — это лишь инструмент измерения вклада
## каждой полноэкранной/доппроходной статьи в кадр. Тень — в _build_environment.
func _apply_render_overrides() -> void:
	var vp := get_viewport()
	if _ovr_msaa == 0:
		vp.msaa_3d = Viewport.MSAA_DISABLED
	if _ovr_scale > 0.0:
		vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
		vp.scaling_3d_scale = _ovr_scale


## Респаун монеты в источнике: у земли + радиальный разлёт «волной». Монеты
## расплываются тонким слоем, НЕ складываются в плотную башню. Прежний вариант
## (узкий радиус 0.8 + падение с 6 м) давал колонну в ~250 слоёв с глубоким
## взаимопроникновением → взрыв контактов в ковше (jolt 500+ мс). Трение/демпф
## быстро тормозят разлёт; некомпланарный наклон держит солвер стабильным.
func place_at_source(coin: RigidBody3D) -> void:
	if coin == null:
		return
	coin.make_active()  # O3: ссыпанная/респавненная монета снова dynamic (если была dormant)
	var a := rnd() * TAU
	var r := sqrt(rnd()) * level.source_radius
	var y := CFG.COIN_THK * 0.5 + rnd() * 0.5   # у земли (было *6.0 — башня/проникновение)
	var dir := Vector3(cos(a), 0.0, sin(a))
	coin.worth = 1
	for cb in side_resetters:
		cb.call(coin.idx)  # телепорт != пересечение ворот
	coin.transform = Transform3D(
		Basis.from_euler(Vector3(rnd() * TAU, rnd() * TAU, rnd() * TAU)),  # некомпланарно
		level.source_pos + dir * r + Vector3(0, y, 0))
	coin.linear_velocity = dir * (CFG.SOURCE_SPREAD_V * (0.6 + rnd() * 0.8))  # «волна» наружу
	coin.angular_velocity = Vector3((rnd() - 0.5) * 6.0, (rnd() - 0.5) * 6.0, (rnd() - 0.5) * 6.0)


func _on_coin_clink(pos: Vector3, strength: float) -> void:
	# Web: контакты -> очередь клинков <=6, памп ~18 Гц (audio.js:81-83).
	# ClinkAudio троттлит 50 мс (20 Гц) — эквивалент; позиционность — бонус Godot.
	clinks.clink(pos, strength)


func _build_entities() -> void:
	for e in level.entities:
		match e.type:
			"gate":
				var gt := Gate.new()
				gt.setup(self, e)
				add_child(gt)
				gates.append(gt)
			"pad_knife":
				var pd := UpgradePad.new()
				pd.setup(self, e)
				add_child(pd)
				pads.append(pd)
			"trash":
				var tp := TrashPad.new()
				tp.setup(self, e)
				add_child(tp)
				trash_pads.append(tp)


func _build_bank_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_bank_label = Label.new()
	_bank_label.text = "0"
	_bank_label.add_theme_font_size_override("font_size", 44)
	_bank_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.4))
	_bank_label.add_theme_constant_override("outline_size", 8)
	_bank_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_bank_label.offset_top = 12
	_bank_label.pivot_offset = Vector2(40, 30)
	layer.add_child(_bank_label)


func _update_bank_ui() -> void:
	_bank_label.text = fmt(bank)
	if bank > _bank_shown:
		_bank_shown = bank
		var tw := create_tween()  # bump как web CSS-класс
		_bank_label.scale = Vector2(1.35, 1.35)
		tw.tween_property(_bank_label, "scale", Vector2.ONE, 0.18)


func _build_hud_and_menu() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 2
	add_child(layer)

	# Стартовый экран (web #start)
	_start_overlay = ColorRect.new()
	_start_overlay.color = Color(0.18, 0.13, 0.3, 0.75)
	_start_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_start_overlay)
	var title := Label.new()
	title.text = "ЗОЛОТОДОЗЕР"
	title.add_theme_font_size_override("font_size", 64)
	title.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	title.offset_top = -140
	title.offset_left = -240
	_start_overlay.add_child(title)
	var btn := Button.new()
	btn.text = "СТАРТ"
	btn.add_theme_font_size_override("font_size", 40)
	btn.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	btn.offset_left = -110
	btn.offset_right = 110
	btn.offset_top = -10
	btn.offset_bottom = 80
	btn.pressed.connect(func() -> void:
		phase = "play"
		_start_overlay.visible = false)
	_start_overlay.add_child(btn)

	# Mute (web #mute)
	var mute := Button.new()
	mute.text = "🔊"
	mute.add_theme_font_size_override("font_size", 28)
	mute.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	mute.offset_left = -76
	mute.offset_top = 12
	mute.offset_right = -16
	mute.offset_bottom = 72
	mute.pressed.connect(func() -> void:
		mute.text = "🔇" if audio.toggle_mute() else "🔊")
	layer.add_child(mute)

	# B1: кнопка засеять dormant-монеты (декор без физики) — изобилие на экране.
	# Гидрируются в тела по подъезду дозера; на телефоне смотрим FPS/draw_calls.
	var gold_btn := Button.new()
	gold_btn.text = "+2000 золота"
	gold_btn.add_theme_font_size_override("font_size", 26)
	gold_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	gold_btn.offset_left = -250
	gold_btn.offset_top = 84
	gold_btn.offset_right = -16
	gold_btn.offset_bottom = 144
	gold_btn.pressed.connect(func() -> void:
		seed_dormant(2000))
	layer.add_child(gold_btn)

	# Performance HUD + тумблеры тюнинга (петля «десктоп + прокси телефона»)
	var hud := preload("res://scripts/performance_hud.gd").new()
	hud.pool_stats_cb = func() -> Vector4i:
		return Vector4i(pool.active_count(), pool.free_count(), _dormant.count() if _dormant else 0, cap)
	hud.spawn_50_cb = func() -> void:
		for i in 50:
			place_at_source(pool.spawn(Vector3.ZERO, false))
	hud.gd_time_cb = func() -> float:
		return _sim_us_last / 1000.0  # мс GDScript-сима за последний физ-тик
	hud.toggles = [
		["Тени", true, func(on: bool) -> void:
			sun.shadow_enabled = on],
		["Тики 50", false, func(on: bool) -> void:
			Engine.physics_ticks_per_second = 50 if on else 60],
		["MSAA 2x", true, func(on: bool) -> void:
			get_viewport().msaa_3d = Viewport.MSAA_2X if on else Viewport.MSAA_DISABLED],
		["Glow", true, func(on: bool) -> void:
			world_env.glow_enabled = on],
		["Звон", true, func(on: bool) -> void:
			clinks.enabled = on
			for coin in pool.get_children():
				coin.set_clink_wanted(on)],
		["Завал плашмя", true, func(on: bool) -> void:
			for coin in pool.get_children():
				coin.calm_flatten = on],
	]
	add_child(hud)

	# Виртуальный джойстик (мобильное управление) — на своём слое под меню (layer 2),
	# чтобы кнопки/HUD были сверху и ловили касания первыми.
	var joy_layer := CanvasLayer.new()
	joy_layer.layer = 1
	add_child(joy_layer)
	_joy = VirtualJoystick.new()
	joy_layer.add_child(_joy)


static func fmt(n: float) -> String:
	# web state.js fmt: k/M/B
	n = roundf(n)
	if n >= 1e9:
		return "%.2fB" % (n / 1e9)
	if n >= 1e6:
		return "%.2fM" % (n / 1e6)
	if n >= 1e3:
		return "%.1fk" % (n / 1e3)
	return str(int(n))


# --- Джус-колбэки сущностей ---

func on_coins_absorbed(pos: Vector3, cnt: int) -> void:
	clinks.clink(pos, 0.6)
	fx.sparks(pos.x, pos.z, mini(8, cnt))


func on_gate_wave(g: Gate, crossed: int) -> void:
	shake = minf(0.45, shake + 0.1 + crossed * 0.02)
	fx.popup(Vector3(g.position.x, 2.6, g.position.z), "x%d" % g.mult, Color("7fe6ff"))
	audio.chime("gate")


func on_gate_unlocked(g: Gate) -> void:
	shake += 0.3
	fx.sparks(g.position.x, g.position.z, 22)
	fx.popup(Vector3(g.position.x, 3, g.position.z), "ОТКРЫТО x%d" % g.mult, Color("aef0c0"))
	audio.chime("upgrade")


func on_pad_upgraded(pd: UpgradePad) -> void:
	# Апгрейд НОЖ: шире ковш (web apply, main.js:253)
	up_blade_half += 0.5
	dozer.rebuild_blade(dozer.blade_hx())
	pads.erase(pd)
	shake += 0.34
	fx.sparks(pd.position.x, pd.position.z, 22)
	audio.chime("upgrade")


func _build_dozer() -> void:
	dozer = Dozer.new()
	dozer.name = "Dozer"
	dozer.position = dozer_pos
	dozer.rotation.y = heading
	add_child(dozer)
	# Тень-диск (web main.js:109)
	dozer_shadow = MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 1.7
	disc.bottom_radius = 1.7
	disc.height = 0.01
	disc.radial_segments = 24
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = Color(0, 0, 0, 0.25)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	dozer_shadow.mesh = disc
	dozer_shadow.material_override = m
	dozer_shadow.position = Vector3(dozer_pos.x, 0.04, dozer_pos.z)
	add_child(dozer_shadow)


# --- Аргументы харнесса ---

func _parse_user_args() -> void:
	rng_sim.seed = 1
	rng_vis.seed = 1 ^ 0x9e3779b9
	# Десктоп отдаёт харнесс-флаги через ++ в get_cmdline_user_args(); Android
	# (запечённый command_line/extra_args) — в get_cmdline_args(). Берём оба и
	# фильтруем по нашим специфичным префиксам (--probe/--smoke-/--seed=/...).
	var _args := OS.get_cmdline_user_args()
	_args.append_array(OS.get_cmdline_args())
	var seeded := false
	for arg in _args:
		if arg.begins_with("--seed="):
			var s := int(arg.get_slice("=", 1))
			rng_sim.seed = s
			rng_vis.seed = s ^ 0x9e3779b9
			test_mode = true
			seeded = true
		elif arg.begins_with("--coins="):
			_pool_size_override = int(arg.get_slice("=", 1))  # свип размера пула
		elif arg == "--coin-convex":
			Coin.force_convex = true  # A/B формы коллайдера (до pool.setup → до _ensure_shared)
		elif arg.begins_with("--smoke-"):
			_smoke_mode = arg.trim_prefix("--smoke-")
			test_mode = true
			rng_sim.seed = 7
			rng_vis.seed = 7 ^ 0x9e3779b9
		elif arg == "--probe" or arg.begins_with("--probe-s="):
			# Авто-прогон телеметрии: реалистичный loop-автопилот + Telemetry.
			# Seed по умолчанию 7 (детерминизм), но --seed= раньше в строке побеждает.
			_probe = true
			_smoke_mode = "loop"
			test_mode = true
			if not seeded:
				rng_sim.seed = 7
				rng_vis.seed = 7 ^ 0x9e3779b9
			if arg.begins_with("--probe-s="):
				_probe_s = float(arg.get_slice("=", 1))  # реальные секунды (не тики)
		elif arg.begins_with("--probe-coins="):
			_pool_size_override = int(arg.get_slice("=", 1))
		elif arg.begins_with("--probe-seed="):
			_probe_seed = int(arg.get_slice("=", 1))  # B1: засев dormant-изобилия
		elif arg.begins_with("--cap="):
			_cap_override = int(arg.get_slice("=", 1))  # B2: заморозить AIMD-кэп (детерминизм)
			_cap_frozen = true
		elif arg.begins_with("--dormant-segs="):
			Coin.dormant_lod_segs = int(arg.get_slice("=", 1))  # B6 A/B: сегменты LOD-меша декора
		elif arg == "--dormant-hi":
			Coin.dormant_mat_cheap = false  # B6 A/B: полный PBR на декоре (бейслайн замера рендера)
		elif arg == "--no-msaa":
			_ovr_msaa = 0   # B6 A/B: замер вклада MSAA в кадр на телефоне
		elif arg == "--no-shadow":
			_ovr_shadow = 0  # B6 A/B: замер вклада теней солнца
		elif arg == "--no-glow":
			_ovr_glow = 0    # B6 A/B: замер вклада bloom (работает и на Android — baked args)
		elif arg.begins_with("--render-scale="):
			_ovr_scale = float(arg.get_slice("=", 1))  # B6 A/B: рендер-скейл 3D (fill-rate)
		elif arg.begins_with("--cal="):
			var c := arg.get_slice("=", 1).split(",")
			_cal_sun = float(c[0])
			_cal_amb = float(c[1])
		elif arg.begins_with("--pose="):
			# Поза дозера для сверочных кадров с web: --pose=x,z[,heading]
			var p := arg.get_slice("=", 1).split(",")
			dozer_pos = Vector3(float(p[0]), 0, float(p[1]))
			if p.size() > 2:
				heading = float(p[2])
			test_mode = true
	if not test_mode and not seeded:
		rng_sim.randomize()
		rng_vis.randomize()

	# --shot= обрабатывается после создания ShotTool в _ready
	for arg in _args:
		if arg.begins_with("--shot="):
			call_deferred("_request_shot", arg.trim_prefix("--shot="))


func _request_shot(path: String) -> void:
	shot.request(path, 30)


## Авто-телеметрия (--probe): проводим провайдеры в Telemetry (как HUD-колбэки) и
## стартуем прогон. Пер-тик gd_ms — O(1); dormant — O(N), берётся раз в окно.
func _start_probe() -> void:
	Telemetry.tick_cb = func() -> float:
		return _sim_us_last / 1000.0
	Telemetry.sample_cb = func() -> Dictionary:
		var dorm := 0
		for coin in pool.get_children():
			if coin.dormant:
				dorm += 1
		return {
			"active": pool.active_count(),
			"free": pool.free_count(),
			"dormant": dorm,
			"vis_gold": _dormant.count() if _dormant else 0,  # декор-монеты dormant-слоя
			"cap": cap,  # B2: текущий AIMD-кэп активных тел
		}
	if _probe_seed > 0:
		seed_dormant(_probe_seed)  # B1: изобилие на экране для замера гидра/рендера
	Telemetry.begin("loop", int(rng_sim.seed), _probe_s)


func rnd() -> float:
	return rng_sim.randf()


func rndv() -> float:
	return rng_vis.randf()


# --- Окружение (web: main.js:12-44) ---

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = CFG.BG_COLOR

	# Небо-градиент: НЕ фон (фон — сплошной цвет), а источник рефлексов золота
	var sky_mat := PanoramaSkyMaterial.new()
	sky_mat.panorama = TexGen.sky_panorama()
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env.sky = sky
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY

	# HemisphereLight(#cfe0f5, #5a4a40, 1.15) -> ambient смесью неба и грунта
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	# Hemisphere: грунт смотрит вверх -> получает в основном цвет неба.
	# Энергии откалиброваны по web-эталону (shot_establish, патч грунта):
	# web (135,125,162) vs godot (139,123,162) — web рендерит без color
	# management, прямой перенос энергий дал бы 3-кратный пересвет.
	env.ambient_light_color = Color("cfe0f5").lerp(Color("5a4a40"), 0.25)
	env.ambient_light_energy = CFG.HEMI_INT * 0.237 * _cal_amb   # 0.55*0.43

	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = CFG.EXPOSURE

	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = CFG.BG_COLOR
	env.fog_depth_begin = CFG.FOG_NEAR
	env.fog_depth_end = CFG.FOG_FAR

	# Bloom web-пайплайна (bright-pass 0.86 + compose 0.38)
	env.glow_enabled = _ovr_glow != 0  # --no-glow (через парсер: и user-args, и baked Android)
	env.glow_hdr_threshold = CFG.BLOOM_THR
	env.glow_intensity = CFG.BLOOM_INTEN

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	world_env = env

	sun = DirectionalLight3D.new()
	sun.light_color = Color("fff4de")
	sun.light_energy = CFG.SUN_INT * 0.30 * _cal_sun  # калибровка по web-эталону
	sun.shadow_enabled = _ovr_shadow != 0   # B6 probe: --no-shadow → off (замер)
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	# web: позиция (10,22,6), смотрит в origin
	sun.look_at_from_position(Vector3(10, 22, 6), Vector3.ZERO, Vector3.UP)
	add_child(sun)


func _build_ground_and_rocks() -> void:
	# Грунт-диск R=150 с детерминированной фактурой (main.js:41-42)
	var gmat := StandardMaterial3D.new()
	var albedo := TexGen.ground_albedo()
	gmat.albedo_texture = albedo
	gmat.normal_enabled = true
	gmat.normal_texture = TexGen.ground_normal()
	gmat.roughness = 1.0
	gmat.uv1_scale = Vector3(14, 14, 1)  # web repeat 14x14

	var ground := MeshInstance3D.new()
	var disc := CylinderMesh.new()      # тонкий диск вместо CircleGeometry
	disc.top_radius = 150.0
	disc.bottom_radius = 150.0
	disc.height = 0.02
	disc.radial_segments = 48
	ground.mesh = disc
	ground.material_override = gmat
	ground.position = Vector3(0, -0.01, 0)
	add_child(ground)

	# Земля-коллайдер: толстый бокс, верх в y=0 (web physics.js:27-28)
	var gbody := StaticBody3D.new()
	gbody.name = "Ground"
	var pm := PhysicsMaterial.new()
	pm.friction = 1.0
	pm.bounce = 0.0
	gbody.physics_material_override = pm
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600, 2, 600)
	cs.shape = box
	cs.position = Vector3(0, -1, 0)
	gbody.add_child(cs)
	add_child(gbody)

	# Граница сцены: один полигональный «забор» (1 draw-call вместо ~100 скал) +
	# невидимая стена-коллайдер держит монеты; дозер клэмпится радиально в sim_step.
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color("8f72c8")
	rock_mat.roughness = 1.0
	rock_mat.cull_mode = BaseMaterial3D.CULL_DISABLED  # стена видна изнутри арены
	var rc := level.ring_center
	var rr := level.ring_radius
	if rr > 0.0:
		# Визуал — открытый цилиндр-многоугольник (32 грани) на радиусе кольца.
		var fence := MeshInstance3D.new()
		fence.name = "Fence"
		var fmesh := CylinderMesh.new()
		fmesh.top_radius = rr + 1.0
		fmesh.bottom_radius = rr + 1.0
		fmesh.height = 5.0
		fmesh.radial_segments = 32
		fmesh.cap_top = false
		fmesh.cap_bottom = false
		fence.mesh = fmesh
		fence.material_override = rock_mat
		fence.position = Vector3(rc.x, 2.0, rc.z)
		add_child(fence)
		# Невидимый барьер: 32 box-сегмента по хорде окружности (держит монеты)
		var wall := StaticBody3D.new()
		wall.name = "RingWall"
		var pm_ring := PhysicsMaterial.new()
		pm_ring.friction = 0.3
		pm_ring.bounce = 0.0
		wall.physics_material_override = pm_ring
		add_child(wall)
		var seg_len := TAU * rr / 32.0 + 0.8  # нахлёст против щелей
		for i in 32:
			var a := (i + 0.5) / 32.0 * TAU
			var seg := CollisionShape3D.new()
			var seg_box := BoxShape3D.new()
			seg_box.size = Vector3(seg_len, 6.0, 1.0)
			seg.shape = seg_box
			seg.position = Vector3(rc.x + cos(a) * rr, 1.5, rc.z + sin(a) * rr)
			seg.rotation.y = -a + PI / 2.0  # хорда перпендикулярна радиусу
			wall.add_child(seg)


func _build_walls() -> void:
	# Стены коридора/карманов из уровня (web physics.js addWall: fr 0.3, невидимые;
	# здесь дублируем тонким видимым мешем — web их не рисует, но реф читается без них)
	var body := StaticBody3D.new()
	body.name = "Walls"
	var pm := PhysicsMaterial.new()
	pm.friction = 0.3
	pm.bounce = 0.0
	body.physics_material_override = pm
	add_child(body)
	for e in level.entities:
		if e.type != "wall":
			continue
		var half: Vector3 = e.params["half"]
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = half * 2.0
		cs.shape = box
		cs.position = e.position
		body.add_child(cs)


# --- Камера (web: main.js:481-490, дословный порт формул) ---

func _build_camera() -> void:
	camera = Camera3D.new()
	camera.fov = CFG.FOV
	camera.near = 0.1
	camera.far = 400.0
	add_child(camera)


func _update_camera(dt: float) -> void:
	shake *= pow(0.0001, dt)
	var sh := 0.0 if test_mode else shake
	var sa := sin(CFG.CAM_YAW)
	var ca := cos(CFG.CAM_YAW)
	var sp := minf(1.0, speed_now / up_move)
	var back := (CFG.CAM_BACK + sp * 0.8) * cam_zoom
	var hgt := (CFG.CAM_HEIGHT + sp * 0.5) * cam_zoom
	var la := CFG.LOOK_AHEAD * cam_zoom
	var jx := (rndv() - 0.5) * sh if sh > 0.0 else 0.0
	var jy := (rndv() - 0.5) * sh if sh > 0.0 else 0.0
	var dp := dozer.position if dozer else dozer_pos
	camera.position = Vector3(
		dp.x + back * sa + jx, hgt + jy, dp.z - back * ca)
	camera.look_at(Vector3(dp.x - la * sa, 0, dp.z + la * ca), Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	# Зум колесом (web: ×1.08 за щелчок, клэмп 0.45..2.2)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_zoom = clampf(cam_zoom * 1.08, CFG.CAM_ZOOM_MIN, CFG.CAM_ZOOM_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_zoom = clampf(cam_zoom / 1.08, CFG.CAM_ZOOM_MIN, CFG.CAM_ZOOM_MAX)
	# Фиксированный джойстик (правый нижний угол): касание в его зоне → ведём драг.
	elif event is InputEventScreenTouch:
		if event.pressed:
			driving = _joy.press(event.position)
		else:
			if driving:
				_joy.release()
			driving = false
	elif event is InputEventScreenDrag and driving:
		_joy.move_knob(event.position)


# --- Ввод -> ctrl (web applyLiveInput/applyScriptInput :322-331) ---

func _apply_live_input() -> void:
	ctrl_desired = NAN
	ctrl_moving = false
	if driving:
		# Курс из джойстика с учётом наклона камеры: экран-вверх = «от камеры».
		var off := _joy.offset()
		if off.length() > VirtualJoystick.DEADZONE:
			var sa := sin(CFG.CAM_YAW)
			var ca := cos(CFG.CAM_YAW)
			var up_amt := -off.y   # экран: ось y вниз → «вверх» отрицателен
			var rx := -off.x       # инверсия лево/право (по фидбэку)
			var wx := up_amt * (-sa) + rx * ca
			var wz := up_amt * ca + rx * sa
			ctrl_desired = atan2(wx, wz)
	var kx := 0.0
	var kz := 0.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		kz += 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		kz -= 1.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		kx += 1.0  # лево-право инвертированы (под реф, web :325)
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		kx -= 1.0
	if kx != 0.0 or kz != 0.0:
		ctrl_desired = atan2(kx, kz)
		ctrl_moving = true
	elif not is_nan(ctrl_desired):
		ctrl_moving = true


func _apply_script_input() -> void:
	ctrl_desired = NAN
	ctrl_moving = false
	if _script_target != Vector3.INF:
		var dx := _script_target.x - dozer.position.x
		var dz := _script_target.z - dozer.position.z
		if dx * dx + dz * dz > 0.25:
			ctrl_desired = atan2(dx, dz)
			ctrl_moving = true


# --- Сим-шаг (web simStep :360-378, порядок сохранён) ---

func _physics_process(delta: float) -> void:
	if phase != "play":
		_sim_us_last = 0
		return
	# Чистое время GDScript-сима за тик. TIME_PHYSICS_PROCESS включает и шаг
	# физ-сервера, и эти колбэки → в HUD «jolt» = physics − gd (см. O1, BACKLOG).
	var t0 := Time.get_ticks_usec()
	if _script_target != Vector3.INF:
		_apply_script_input()
	else:
		_apply_live_input()
	sim_step(delta)
	_smoke_tick()
	_sim_us_last = Time.get_ticks_usec() - t0


func sim_step(dt: float) -> void:
	sim_time += dt
	if not is_nan(ctrl_desired):
		var d := wrapf(ctrl_desired - heading, -PI, PI)
		heading += d * minf(1.0, dt * CFG.HEADING_LERP)
	speed_now += ((up_move if ctrl_moving else 0.0) - speed_now) * minf(1.0, dt * CFG.SPEED_LERP)
	dozer.position.x += sin(heading) * speed_now * dt
	dozer.position.z += cos(heading) * speed_now * dt
	_resolve_obstacles()
	# Кольцо скал: дозер не выезжает за границу сцены (радиальный клэмп)
	if level.ring_radius > 0.0:
		var off := Vector2(dozer.position.x - level.ring_center.x,
			dozer.position.z - level.ring_center.z)
		var max_r := level.ring_radius - DOZER_R - 0.5
		if off.length_squared() > max_r * max_r:
			off = off.normalized() * max_r
			dozer.position.x = level.ring_center.x + off.x
			dozer.position.z = level.ring_center.z + off.y
	dozer.rotation.y = heading
	# Высота опоры: max по центру/носу + упреждение; вверх быстро, вниз плавно
	var sn := sin(heading)
	var cs := cos(heading)
	var ahead := speed_now * 0.25
	var gy := 0.0
	for d: float in [0.0, 1.5, 2.9 + ahead]:
		gy = maxf(gy, ground_y_under(dozer.position.x + sn * d, dozer.position.z + cs * d))
	ground_lift += (gy - ground_lift) * minf(1.0, dt * (25.0 if gy > ground_lift else 6.0))
	dozer.position.y = ground_lift + sin(sim_time * 20.0) * 0.02 * minf(1.0, speed_now / 3.0)
	dozer.anim_tracks(dt, speed_now)
	dozer.update_body_poses()  # кинематика ковша/шасси (web setKinematicPoses)
	audio.pump_engine(minf(1.0, speed_now / up_move), phase == "play")
	# Пыль из-под траков (web :377, :247)
	if speed_now > 3.5 and rndv() < 0.6:
		_emit_dust()
	dozer_pos = dozer.position
	dozer_shadow.position = Vector3(dozer.position.x, 0.04, dozer.position.z)
	# O3 «умный dormant»: монета физическая только в РАБОЧЕЙ ЗОНЕ перед ножом
	# (её вот-вот сгребём). Всё осевшее в стороне/позади усыпляем (make_dormant:
	# sleeping + слои 0 — нет пар/интеграции), даже близкое; будим, когда монета
	# заходит в зону (подъезд/поворот). Так «стою в большой куче» не грузит солвер —
	# активны только монеты на пути ножа. Внешняя граница шире внутренней (гистерезис
	# против мерцания); зона направленная (вращается с курсом). reach ножа ~2 м,
	# зона вперёд 6 м → монета оживает задолго до касания.
	var _gd0 := Time.get_ticks_usec() if _smoke_mode == "stress" else 0
	if Engine.get_physics_frames() % 10 == 0:
		var dz := dozer.position
		var sn2 := sin(heading)
		var cs2 := cos(heading)
		var bw := dozer.blade_hx()
		var rr := level.ring_radius
		var ring_lim2 := (rr - 0.8) * (rr - 0.8) if rr > 0.0 else 0.0
		var rcx := level.ring_center.x
		var rcz := level.ring_center.z
		var r_out := CFG.HYDRATE_R + CFG.DEHYDRATE_MARGIN
		var r_out2 := r_out * r_out          # дальше R_out спящее тело → dormant-слой
		var dehy_budget := CFG.DEHYDRATE_PASS_BUDGET
		for coin in pool.get_children():
			if coin.get_meta("in_pool", false):
				continue  # запаркованные пулом
			var p: Vector3 = coin.global_position
			# Доехала до границы — возврат в источник (не «выковыривать» у стены)
			if ring_lim2 > 0.0:
				var ex := p.x - rcx
				var ez := p.z - rcz
				if ex * ex + ez * ez > ring_lim2:
					place_at_source(coin)
					continue
			var dx := p.x - dz.x
			var dzz := p.z - dz.z
			# B1 ДЕГИДРАЦИЯ: осевшее (sleeping) тело дальше R_out → запись в dormant-
			# слой, тело освобождается в пул. Только sleeping → поза восстановится
			# побитово при гидрации (без «вздрагивания»). add()=-1 при полном слое —
			# worth слит в соседа, тело всё равно убираем (изобилие не теряет ценность).
			if dehy_budget > 0 and coin.sleeping and dx * dx + dzz * dzz > r_out2:
				_dormant.add(coin.global_transform, coin.worth)
				pool.release(coin)
				dehy_budget -= 1
				continue
			var lz := dx * sn2 + dzz * cs2   # вдоль курса (вперёд +)
			var lat := dx * cs2 - dzz * sn2  # вбок
			if coin.dormant:
				if lz > -3.0 and lz < 6.0 and absf(lat) < bw + 1.6:
					coin.make_active()       # зашла в рабочую зону → в физику
			elif p.y < 0.6 and coin.linear_velocity.length_squared() < 1.0:
				if lz < -4.5 or lz > 7.5 or absf(lat) > bw + 3.2:
					coin.make_dormant()      # осела вне зоны (с запасом) → спим
	# B2 авто-бюджет активных тел (AIMD) → B1 гидрация держит active≈cap
	_budget_tick()
	# B1 ГИДРАЦИЯ (каждый тик, анти нож-призрак): dormant-записи у дозера → тела
	_hydrate_pass()
	# Экономика (web stepEconomy; физика монет шагает движком после)
	for gt in gates:
		gt.step(dt)
	for pd in pads:
		pd.step(dt)
	for tp in trash_pads:
		tp.step(dt)
	_update_bank_ui()
	if _smoke_mode == "stress":
		_gd_accum += Time.get_ticks_usec() - _gd0  # GDScript-цена циклов O(N)/тик


func _emit_dust() -> void:
	var f := sin(heading)
	var cf := cos(heading)
	var bx := dozer.position.x - f * 1.6
	var bz := dozer.position.z - cf * 1.6
	for sx: float in [-0.9, 0.9]:
		fx.emit(bx + cf * sx + (rndv() - 0.5) * 0.3, 0.18,
			bz - f * sx + (rndv() - 0.5) * 0.3, {
			"color": Color("9a92a8"), "life": 0.55, "size": 0.5, "size1": 1.3,
			"vy": 0.5, "grav": 0.4,
			"vx": (rndv() - 0.5) * 0.6, "vz": (rndv() - 0.5) * 0.6, "fade": 0.32})


func ground_y_under(x: float, z: float) -> float:
	for zn in lift_zones:
		if absf(x - zn.x) < zn.hx and absf(z - zn.z) < zn.hz:
			return 0.2
	return 0.0


func _push_out(px: float, pz: float, r2: float, posts_only: bool) -> bool:
	for o in obstacles:
		if posts_only and not o.post:
			continue
		var cx := clampf(px, o.x0, o.x1)
		var cz := clampf(pz, o.z0, o.z1)
		var dx := px - cx
		var dz := pz - cz
		var d2 := dx * dx + dz * dz
		if d2 > 0.000001 and d2 < r2:
			var d := sqrt(d2)
			var k := (sqrt(r2) - d) / d
			dozer.position.x += dx * k
			dozer.position.z += dz * k
			return true
	return false


func _resolve_obstacles() -> void:
	_push_out(dozer.position.x, dozer.position.z, DOZER_R * DOZER_R, false)
	var sn := sin(heading)
	var cs := cos(heading)
	var bw := dozer.blade_hx() + 0.15
	var bf := Dozer.BLADE_FWD + 1.3  # передние углы ковша (губа ~+1.26)
	for s: float in [-1.0, 1.0]:
		_push_out(dozer.position.x + sn * bf + cs * s * bw,
			dozer.position.z + cs * bf - sn * s * bw, BLADE_R * BLADE_R, true)


# --- Смоуки игровой сцены ---

func _setup_smoke() -> void:
	if _smoke_mode == "drive":
		# Реальные столбы ворот-1 (x=±4.6, z=20). Фаза 1: таран столба —
		# выталкивание держит (web pushout — слайд, не объезд).
		# Фаза 2: проезд в створ до z=30.
		_script_target = Vector3(4.6, 0, 20)
	elif _smoke_mode == "push":
		# Плотная куча на пути — дозер прёт сквозь на полной скорости.
		# Ассерты: ничего не туннелировало в корпус, не провалилось, сгребается.
		# Маршрут заканчивается ДО мата ворот (z<16.7) — чистый тест сгребания.
		for i in 40:
			pool.spawn(Vector3.ZERO, false)
		var n := 0
		for coin in pool.get_children():
			if coin.freeze:
				continue
			coin.position = Vector3(
				-1.5 + 0.75 * (n % 5),
				0.1 + 0.15 * floorf(n / 20.0),
				8.0 + 0.8 * (floori(n / 5.0) % 4))
			n += 1
		_script_target = Vector3(0, 0, 13.5)
	elif _smoke_mode == "gatefill":
		# 12 монет узкой кучей (в ширину ковша) перед матом ворот-1 —
		# дозер вталкивает, fill>=10 -> разблок
		for i in 12:
			pool.spawn(Vector3(-0.6 + 0.6 * (i % 3), 0.1, 15.4 + 0.55 * floorf(i / 3.0)), false)
		dozer.position = Vector3(0, 0, 12)
		_script_target = Vector3(0, 0, 19.5)
	elif _smoke_mode == "knife":
		# 12 монет worth=10 прямо в зоне пада (итого 120 = cost) -> апгрейд
		for i in 12:
			var c := pool.spawn(Vector3(-9.6 + 0.6 * (i % 3), 0.3 + 0.2 * floorf(i / 3.0), 29.5), false)
			c.worth = 10
	elif _smoke_mode == "trash":
		# 8 монет worth=5 в зоне трэша -> сгорают: банк 0, пул сходится
		for i in 8:
			var c := pool.spawn(Vector3(8.6 + 0.4 * (i % 3), 0.3 + 0.2 * floorf(i / 3.0), 29.7), false)
			c.worth = 5
	elif _smoke_mode == "stress":
		# Worst-case: весь пул 1000 по коридору, дозер месит кучу —
		# замер физики + прокси телефона (×8) против бюджета 16.7 мс
		var n := 0
		while pool.free_count() > 0:
			var c := pool.spawn(Vector3.ZERO, false)
			c.position = Vector3(
				-2.2 + 0.55 * (n % 9),
				0.1 + 0.3 * floorf(n / 99.0),
				6.0 + 0.45 * (floori(n / 9.0) % 11))
			n += 1
		_script_target = Vector3(0, 0, 16)
	elif _smoke_mode == "wave":
		# Ворота-1 принудительно открыты; монета worth=1 катится сквозь.
		# Инвариант: сумма worth активных монет после волны ровно x10.
		# Стартовые 5 монет источника убираем — чистый учёт.
		for coin in pool.get_children():
			if not coin.freeze:
				pool.release(coin)
		gates[0].active = true
		var c := pool.spawn(Vector3(0, 0.15, 18.6), false)
		c.linear_velocity = Vector3(0, 0, 12.0)  # трение тормозит ~28 м/с²
		dozer.position = Vector3(0, 0, 5)  # дозер в стороне от створа
	elif _smoke_mode == "spike":
		# Замер ПИКА (фриз), не среднего: дозер проталкивает кучу сквозь
		# открытые ворота-2 ×100 — реальный триггер каскада. Каждая пересёкшая
		# монета плодит до 9 копий; при mult=100 поток копий из свободного пула
		# огромен. Ищем max single-tick ms и всплеск спавнов/тик.
		for coin in pool.get_children():
			if not coin.freeze:
				pool.release(coin)
		gates[1].active = true  # ворота-2 z=40, mult=100
		for row in 10:
			for lane in 7:
				var cc := pool.spawn(Vector3(
					-2.55 + 0.85 * lane, 0.15, 38.6 - 0.7 * row), false)
				cc.worth = 2
		dozer.position = Vector3(0, 0, 31)  # позади кучи, толкает к воротам
		_script_target = Vector3(0, 0, 45)
	elif _smoke_mode == "loop":
		# Реалистичный игровой цикл (точно по ТЗ пользователя): дозер-челнок
		# гоняет по всему коридору через обе ворота. 5 стартовых монет × 2
		# прохода -> fill ворот-1 = 10 -> разблок. Дальше умножение ×10 копит
		# до ворот-2 (cost 600) -> разблок ×100. Потом круги с максимумом.
		# Стартовые 5 монет уже заспавнены в _ready. Дозер у источника.
		# Мягче скорость: монеты не разлетаются к краям, стопаются в зоне мата.
		up_move = 6.0
		dozer.position = Vector3(0, 0, 6)
		_loop_dir = 1
		_script_target = Vector3(0, 0, 18)
	elif _smoke_mode == "freeze":
		# Прямой тест механизма фриза: 800 монет ПЛОТНО внахлёст (шаг 0.3 <<
		# 2·radius=0.8) в малом объёме -> глубокое проникновение -> взрыв
		# контактов. Проверяем: пробивает ли буфер 40960 -> fallback-аллокатор
		# Jolt (hard-столл) и какой при этом пик тика.
		# Куча СБОКУ (x≈20, открытый грунт внутри кольца, без стен), дозер рядом
		# (в рабочей зоне) — иначе B1-дегидрация усыпит далёкую кучу в dormant и
		# тест контактов выродится (active=0). Рядом, но с зазором — не толкает.
		var n := 0
		for i in 800:
			var cc := pool.spawn(Vector3(
				18.8 + 0.3 * (n % 9),
				0.1 + 0.3 * floorf(n / 90.0),
				8.0 + 0.3 * (floori(n / 9.0) % 10)), false)
			n += 1
		dozer.position = Vector3(20, 0, 4)  # рядом с кучей → монеты не дегидрируют
	elif _smoke_mode == "bucket":
		# Чистое репро лага «монеты в ковше» (БЕЗ ворот): куча у источника,
		# дозер возит её челноком в зоне z∈[4,14], не доезжая до мата ворот
		# (z≈16.7). Изолирует стоимость сжатой массы в чаше от каскада волны.
		var n := 0
		for i in 150:
			var c := pool.spawn(Vector3.ZERO, false)
			c.position = Vector3(
				-2.0 + 0.5 * (n % 9),
				0.1 + 0.3 * floorf(n / 135.0),
				7.0 + 0.5 * (floori(n / 9.0) % 6))
			n += 1
		dozer.position = Vector3(0, 0, 4)
		_script_target = Vector3(0, 0, 13)
	elif _smoke_mode == "hydrate":
		# B1: куча dormant-монет; дозер проезжает сквозь — записи гидрируются в тела.
		# Проверяем гидрацию, СОХРАНЕНИЕ worth и отсутствие dormant в следе ножа.
		# Сцена СБОКУ (x≈20, внутри кольца r=32), вдали от ворот/падов/стен (центр
		# z=20/40, x≈0) — чистая изоляция от экономики (иначе ворота множат worth).
		for coin in pool.get_children():
			if not coin.freeze:
				pool.release(coin)  # убрать 5 стартовых — чистый учёт worth
		_hydrate_seeded = 0
		for i in 150:
			var bx := 17.5 + 0.5 * (i % 11)
			var bz := 8.0 + 0.5 * floorf(i / 11.0)
			if _dormant.add(Transform3D(Basis(), Vector3(bx, 0.1, bz)), 1) >= 0:
				_hydrate_seeded += 1
		dozer.position = Vector3(20, 0, 6)
		_script_target = Vector3(20, 0, 16)
	elif _smoke_mode == "evac":
		# B1: пул НАСЫЩЕН дальними спящими телами (x≈-20), а dormant-куча В ЯДРЕ у
		# дозера (x≈20) требует тел при пустом пуле → путь эвакуации. Проверяем
		# сохранение worth и ОТСУТСТВИЕ спайка (раньше эвакуация была O(pool)/кандидат).
		for coin in pool.get_children():
			if not coin.freeze:
				pool.release(coin)
		var far := pool.free_count()  # забить пул целиком дальними телами
		for i in far:
			pool.spawn(Vector3(-24.0 + 0.5 * (i % 20), 0.1, 28.0 + 0.5 * floorf(i / 20.0)), false)
		_hydrate_seeded = 0
		for i in 250:  # плотная dormant-куча в ядре (> бюджета и пула рядом)
			var bx := 18.0 + 0.4 * (i % 10)
			var bz := 7.0 + 0.4 * floorf(i / 10.0)
			if _dormant.add(Transform3D(Basis(), Vector3(bx, 0.1, bz)), 1) >= 0:
				_hydrate_seeded += 1
		_smoke_gd_max = 0
		dozer.position = Vector3(20, 0, 5)
		_script_target = Vector3(20, 0, 13)
	elif _smoke_mode == "abundance":
		# B2: изобилие (3000 dormant) + дозер-змейка СБОКУ (x≈18, вне ворот/падов) 30 с
		# под ЗАМОРОЖЕННЫМ кэпом 150. Проверяем: active держится у кэпа, worth
		# константа (нет умножения вне ворот), узлы не текут. Кэп-сжатие — на телефоне.
		for coin in pool.get_children():
			if not coin.freeze:
				pool.release(coin)
		_cap_frozen = true
		_cap_override = 150
		cap = 150
		seed_dormant(3000)
		_hydrate_seeded = _dormant.count()
		_active_prev = 0
		dozer.position = Vector3(16, 0, 10)
		_loop_dir = 1
		_script_target = Vector3(16, 0, 18)


func _descendants(n: Node) -> int:
	var c := n.get_child_count()
	for ch in n.get_children():
		c += _descendants(ch)
	return c


## Гистограмма видимых VisualInstance3D по классу в поддереве (гард draw-calls в смоуках).
func _count_visuals(n: Node, hist: Dictionary) -> void:
	if n is VisualInstance3D and n.visible:
		var k: String = n.get_class()
		hist[k] = hist.get(k, 0) + 1
	for ch in n.get_children():
		_count_visuals(ch, hist)


func _smoke_tick() -> void:
	if _smoke_mode == "":
		return
	_smoke_ticks += 1
	# Пик физики: max времени ОДНОГО физ-тика = кандидат во фриз (не среднее)
	var pm := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	if pm > _phys_max:
		_phys_max = pm
	if _smoke_mode == "lod":
		# B6 регресс: декор на дешёвом LOD-меше/материале, активный слой — полный.
		# Структурная проверка (один тик): не даём рефактору молча вернуть полный PBR.
		var dmesh := _dormant.multimesh.mesh
		var dsegs := (dmesh as CylinderMesh).radial_segments if dmesh is CylinderMesh else -1
		var amesh := _coin_mm.multimesh.mesh
		var asegs := (amesh as CylinderMesh).radial_segments if amesh is CylinderMesh else -1
		var cheap_mat: bool = _dormant.material_override == Coin._material_lod \
			and Coin._material_lod != null and Coin._material_lod != Coin._material
		var shadow_off: bool = _dormant.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# B6 батч дозера: после слияния под дозером должно остаться мало MeshInstance3D
		# (Merged корпус + Merged ковш; треды — MultiMesh). Гард от регресса (был ~59).
		var hist := {}
		_count_visuals(dozer, hist)
		var dozer_mi: int = hist.get("MeshInstance3D", 0)
		var ok := dsegs == CFG.DORMANT_LOD_SEGS and asegs == Coin._mesh.radial_segments \
			and cheap_mat and shadow_off and dozer_mi <= 6
		print("SMOKE lod: %s dormant_segs=%d active_segs=%d cheap_mat=%s shadow_off=%s dozer_meshes=%d" % [
			"OK" if ok else "FAIL", dsegs, asegs, cheap_mat, shadow_off, dozer_mi])
		get_tree().quit(0 if ok else 1)
		return
	if _smoke_mode == "idle":
		# Сцена «как на телефоне»: старт (5 монет, 995 в пуле), дозер стоит.
		# Замер физики для сопоставления CI↔телефон (как HUD: physics/jolt/gd).
		if _smoke_ticks > 60:
			_phys_accum += pm
			_gd_accum += _sim_us_last
		if _smoke_ticks >= 360:  # 6 c
			var phys := 1000.0 * _phys_accum / 300.0
			var gd := 0.001 * _gd_accum / 300.0
			print("SMOKE idle: coins=%d/%d physics=%.2f jolt=%.2f gd=%.2f ms" % [
				pool.active_count(), pool.free_count(), phys, phys - gd, gd])
			get_tree().quit(0)
		return
	if _smoke_mode == "loop":
		# Фазовый челнок: цель спереди зависит от прогресса. Фаза 1 (ворота-1
		# заперты): толкаем монеты на мат ворот-1 (z18, стоп В зоне). Фаза 2
		# (ворота-1 открыты): гоним сквозь них на мат ворот-2 (z38). Фаза 3
		# (обе открыты): полный прогон до z45. Назад всегда к источнику (z6).
		var fwd_z := 18.0
		if gates[1].active:
			fwd_z = 45.0
		elif gates[0].active:
			fwd_z = 38.0
		# Змейка по x: ковш ~2 м, коридор 5.6 м — собираем монеты с краёв.
		var weave := 1.9 * sin(_smoke_ticks * 0.06)
		if _loop_dir == 1 and dozer.position.z > fwd_z - 1.5:
			_loop_dir = -1
			_script_target = Vector3(weave, 0, 6)
		elif _loop_dir == -1 and dozer.position.z < 7.5:
			_loop_dir = 1
			_loop_laps += 1
			_script_target = Vector3(weave, 0, fwd_z)
		else:
			_script_target = Vector3(weave, 0, 6.0 if _loop_dir == -1 else fwd_z)
		# Засечь моменты разблокировки
		# Регресс на утечку узлов (баг: создание коллайдеров в per-tick пути).
		# Дозер непрерывно ездит ~60 c; число узлов и пик тика обязаны быть плоскими.
		if _smoke_ticks == 120:
			_loop_nodes0 = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
			_phys_max = 0.0  # сбросить пик после стартового спайка спавна
		if not _probe and _smoke_ticks >= 3600:  # 60 c (в probe — терминацию ведёт Telemetry)
			var nodes_now := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
			var leaked := nodes_now - _loop_nodes0
			# Допуск: пул/частицы могут колебаться на десятки; утечка была +2/тик (~7000)
			var ok := leaked < 200 and _phys_max < 0.040
			print("SMOKE loop: %s nodes_t120=%d nodes_end=%d leaked=%d peak_after_warmup=%.1f ms laps=%d" %
				["OK" if ok else "FAIL", _loop_nodes0, nodes_now, leaked, 1000.0 * _phys_max, _loop_laps])
			get_tree().quit(0 if ok else 1)
		return
	if _smoke_mode == "spike" or _smoke_mode == "freeze":
		var act := pool.active_count()
		var burst := act - _active_prev   # сколько монет добавлено за этот тик (спавн волны)
		if burst > _max_spawn_burst:
			_max_spawn_burst = burst
		_active_prev = act
		_phys_accum += pm
		if _smoke_ticks % 20 == 0:
			print("%s t=%d active=%d tick_ms=%.1f peak_ms=%.1f" %
				[_smoke_mode, _smoke_ticks, act, 1000.0 * pm, 1000.0 * _phys_max])
		if _smoke_ticks >= 300:  # 5 c
			# Порог пика ловит регресс класса утечки (она гнала пик 20->66+ мс).
			# spike (каскад) ~19 мс, freeze (плотный нахлёст) ~27 мс — кэп 60.
			var ok := _phys_max < 0.060
			print("SMOKE %s: %s PEAK_tick=%.1f ms avg=%.2f ms max_spawn_burst=%d active=%d" %
				[_smoke_mode, "OK" if ok else "FAIL", 1000.0 * _phys_max,
				1000.0 * _phys_accum / 300.0, _max_spawn_burst, pool.active_count()])
			get_tree().quit(0 if ok else 1)
	if _smoke_mode == "drive":
		# Инвариант web: центр дозера никогда не ВНУТРИ AABB (сквозь столб
		# не проходит). Клиренс < R транзиентно бывает и в web (двойное
		# выталкивание корпус+ковш) — это не нарушение.
		for o in obstacles:
			if dozer.position.x > o.x0 and dozer.position.x < o.x1 \
					and dozer.position.z > o.z0 and dozer.position.z < o.z1:
				_smoke_violations += 1
		if _smoke_ticks == 300:    # 5 c тарана -> отъехать (из клина web сам не выходит)
			_script_target = Vector3(0, 0, 10)
		elif _smoke_ticks == 600:  # -> в створ между столбами
			_script_target = Vector3(0, 0, 30)
		elif _smoke_ticks >= 1200:  # 20 c всего
			var reached := dozer.position.z > 28.0 and absf(dozer.position.x) < 2.0
			var ok := reached and _smoke_violations == 0
			print("SMOKE %s: dozer=%s heading=%.2f violations=%d" %
				["OK" if ok else "FAIL", dozer.position, heading, _smoke_violations])
			get_tree().quit(0 if ok else 1)
	elif _smoke_mode == "gatefill":
		if _smoke_ticks >= 900:  # 15 c
			var g := gates[0]
			var books := pool.active_count() + pool.free_count() == pool.size
			var ok: bool = g.active and bank >= 10.0 and books
			print("SMOKE %s: gate1_active=%s fill=%.0f bank=%.0f active=%d books=%s" %
				["OK" if ok else "FAIL", g.active, g.fill, bank, pool.active_count(), books])
			get_tree().quit(0 if ok else 1)
	elif _smoke_mode == "bucket":
		_phys_accum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
		if _smoke_ticks % 60 == 0:
			# Считаем монеты в чаше ковша (локальные координаты blade_body)
			var inv := dozer.blade_body.global_transform.affine_inverse()
			var in_bucket := 0
			var awake := 0
			var max_pen := 0.0
			for coin in pool.get_children():
				if coin.freeze:
					continue
				if not coin.sleeping:
					awake += 1
				var lp: Vector3 = inv * coin.global_position
				if absf(lp.x) < 1.2 and lp.z > -0.6 and lp.z < 1.7 and lp.y < 1.4:
					in_bucket += 1
			var ms := 1000.0 * _phys_accum / _smoke_ticks
			print("bucket t=%d dozer_z=%.1f in_bucket=%d awake=%d max_pen=%.3f avg_ms=%.2f" %
				[_smoke_ticks, dozer.position.z, in_bucket, awake, max_pen, ms])
		# Челнок: вперёд до 13, назад до 5, повтор — монеты остаются в ковше
		if _smoke_ticks == 180:
			_script_target = Vector3(0, 0, 5)
		elif _smoke_ticks == 360:
			_script_target = Vector3(0, 0, 13)
		elif _smoke_ticks == 540:
			_script_target = Vector3(0, 0, 5)
		if _smoke_ticks >= 720:  # 12 c
			var avg_ms := 1000.0 * _phys_accum / 600.0
			print("SMOKE bucket: avg_physics=%.2f ms (≈телефон %.1f ms)" % [avg_ms, avg_ms * 8.0])
			get_tree().quit(0)
	elif _smoke_mode == "hydrate":
		# Каждый тик в зоне кучи: dormant в следе ножа = нож-призрак (гидрация
		# упреждающая → должно быть ~0). Копим тики-нарушения.
		if dozer.position.z > 5.0 and dozer.position.z < 16.0:
			var fwd := Vector3(sin(heading), 0, cos(heading))
			var bc := dozer.position + fwd * up_reach
			if _dormant.query_circle(bc, dozer.blade_hx() + 0.3).size() > 0:
				_smoke_violations += 1
		if _smoke_ticks >= 480:  # 8 c
			var active_worth := 0
			for coin in pool.get_children():
				if not coin.get_meta("in_pool", false):
					active_worth += coin.worth
			# Инвариант: ничего не потеряно/задвоено через гидра/дегидра+swap-remove
			var worth_ok := active_worth + _dormant.total_worth() == _hydrate_seeded
			var ok := _hydrate_total > 0 and worth_ok and _smoke_violations <= 2
			print("SMOKE hydrate: %s hydrated=%d seeded=%d worth=%d+%d=%d ghost_ticks=%d" %
				["OK" if ok else "FAIL", _hydrate_total, _hydrate_seeded, active_worth,
				_dormant.total_worth(), active_worth + _dormant.total_worth(), _smoke_violations])
			get_tree().quit(0 if ok else 1)
		return
	elif _smoke_mode == "evac":
		if _sim_us_last > _smoke_gd_max:
			_smoke_gd_max = _sim_us_last  # макс GDScript-сим/тик (ловит O(pool)-спайк эвакуации)
		if _smoke_ticks >= 300:  # 5 c (дальние тела успели уснуть → эвакуируемы)
			var active_worth := 0
			for coin in pool.get_children():
				if not coin.get_meta("in_pool", false):
					active_worth += coin.worth
			var total := active_worth + _dormant.total_worth()
			var expect := pool.size + _hydrate_seeded  # дальние тела + засев в ядре
			var gd_ms := _smoke_gd_max / 1000.0
			# worth сохранён сквозь эвакуацию; спайк ограничен (раньше O(pool)/кандидат)
			var ok := total == expect and _hydrate_total > 0 and gd_ms < 15.0
			print("SMOKE evac: %s total=%d expect=%d hydrated=%d max_gd=%.1f ms" %
				["OK" if ok else "FAIL", total, expect, _hydrate_total, gd_ms])
			get_tree().quit(0 if ok else 1)
		return
	elif _smoke_mode == "abundance":
		# Змейка x≈16, z 10-18 — зона СВОБОДНА от сущностей (ворота x≈0; пады/трэш
		# x=±9,z=30; стены) и внутри кольца. Так worth не уходит в банк/сжигание —
		# чистая проверка инварианта гидра/дегидра под кэпом.
		var weave := 16.0 + 3.0 * sin(_smoke_ticks * 0.05)
		if _loop_dir == 1 and dozer.position.z > 16.5:
			_loop_dir = -1
			_script_target = Vector3(weave, 0, 10)
		elif _loop_dir == -1 and dozer.position.z < 11.5:
			_loop_dir = 1
			_script_target = Vector3(weave, 0, 18)
		else:
			_script_target = Vector3(weave, 0, 10.0 if _loop_dir == -1 else 18.0)
		if _smoke_ticks == 120:
			_loop_nodes0 = Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
		if _smoke_ticks > 120 and pool.active_count() > _active_prev:
			_active_prev = pool.active_count()  # пик активных за прогон
		if _smoke_ticks >= 1800:  # 30 c
			var aw := 0
			for coin in pool.get_children():
				if not coin.get_meta("in_pool", false):
					aw += coin.worth
			var total := aw + _dormant.total_worth()
			var leaked := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)) - _loop_nodes0
			# active держится у кэпа (не сверх cap+burst), worth константа, узлы плоские
			var ok := total == _hydrate_seeded and _active_prev >= 50 \
				and _active_prev <= cap + CFG.GATE_BURST and leaked < 200
			print("SMOKE abundance: %s worth=%d/%d max_active=%d cap=%d leaked=%d" %
				["OK" if ok else "FAIL", total, _hydrate_seeded, _active_prev, cap, leaked])
			get_tree().quit(0 if ok else 1)
		return
	elif _smoke_mode == "stress":
		# Замер ОСЕВШЕЙ кучи: усредняем только последние 5 c (ticks 600..900),
		# исключая взрыв спавна. Свип размера: ++ --coins=N --smoke-stress.
		if _smoke_ticks == 600:
			_phys_max = 0.0  # пик считаем по осевшей куче, не по взрыву спавна
			_gd_accum = 0
		if _smoke_ticks > 600:
			_phys_accum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
		if _smoke_ticks >= 900:  # 15 c (10 c осесть + 5 c замер)
			var n := pool.size
			var phys_ms := 1000.0 * _phys_accum / 300.0
			var gd_ms := 0.001 * _gd_accum / 300.0   # GDScript экономика+пузырь, мс/кадр
			var total := phys_ms + gd_ms
			print("SMOKE stress: N=%d phys=%.2f gd=%.2f total=%.2f ms (≈телефон %.0f ms) active=%d peak=%.1f" %
				[n, phys_ms, gd_ms, total, total * 8.0, pool.active_count(), 1000.0 * _phys_max])
			get_tree().quit(0)
	elif _smoke_mode == "knife":
		if _smoke_ticks >= 240:  # 4 c
			var bh_ok := absf(up_blade_half - 2.1) < 0.001
			var pad_gone := pads.is_empty()
			var stand_gone := true
			for o in obstacles:
				if not o.post:
					stand_gone = false
			var books := pool.active_count() + pool.free_count() == pool.size
			var ok := bh_ok and pad_gone and stand_gone and books and bank >= 120.0
			print("SMOKE %s: blade_half=%.1f pad_gone=%s stand_gone=%s bank=%.0f books=%s" %
				["OK" if ok else "FAIL", up_blade_half, pad_gone, stand_gone, bank, books])
			get_tree().quit(0 if ok else 1)
	elif _smoke_mode == "trash":
		if _smoke_ticks >= 240:  # 4 c
			var books := pool.active_count() + pool.free_count() == pool.size
			# 8 сгорели без банка; 5 стартовых целы (B1: часть могла уйти в dormant
			# вдали от дозера — считаем active+dormant).
			var survivors := pool.active_count() + _dormant.count()
			var ok := bank == 0.0 and survivors == 5 and books
			print("SMOKE %s: bank=%.0f active=%d dormant=%d survivors=%d books=%s" %
				["OK" if ok else "FAIL", bank, pool.active_count(), _dormant.count(), survivors, books])
			get_tree().quit(0 if ok else 1)
	elif _smoke_mode == "wave":
		if _smoke_ticks >= 360:  # 6 c: волна + парковка в створе (анти-фарм)
			# B1: копии у ворот (вдали от дозера) могут уйти в dormant — worth-
			# инвариант держим по active+dormant (сумма ценности ровно ×10).
			var total_worth := _dormant.total_worth()
			var n_total := _dormant.count()
			for coin in pool.get_children():
				if coin.get_meta("in_pool", false):
					continue
				total_worth += coin.worth
				n_total += 1
			var books := pool.active_count() + pool.free_count() == pool.size
			var ok := total_worth == 10 and n_total == 10 and books
			print("SMOKE %s: worth_sum=%d count(act+dorm)=%d books=%s" %
				["OK" if ok else "FAIL", total_worth, n_total, books])
			get_tree().quit(0 if ok else 1)
	elif _smoke_mode == "push":
		if _smoke_ticks >= 600:  # 10 c
			var fallen := 0
			var tunneled := 0
			var plowed := 0
			var inv := dozer.global_transform.affine_inverse()
			for coin in pool.get_children():
				if coin.get_meta("in_pool", false):
					continue  # O3: dormant-монеты (статик, но в игре) считаем
				var p: Vector3 = coin.global_position
				if p.y < -0.5:
					fallen += 1
				if p.z > 11.5:
					plowed += 1
				var lp: Vector3 = inv * p  # локальные координаты дозера
				if absf(lp.x) < 0.8 and lp.z > -1.2 and lp.z < 1.2 and lp.y < 2.0:
					tunneled += 1
			var ok := fallen == 0 and tunneled == 0 and plowed >= 10
			print("SMOKE %s: fallen=%d tunneled=%d plowed=%d active=%d" %
				["OK" if ok else "FAIL", fallen, tunneled, plowed, pool.active_count()])
			get_tree().quit(0 if ok else 1)


func _build_coin_multimesh() -> void:
	Coin._ensure_shared()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = Coin._mesh
	mm.instance_count = pool.size
	for i in pool.size:
		mm.set_instance_transform(i, _HIDDEN_XF)
	_coin_mm = MultiMeshInstance3D.new()
	_coin_mm.name = "CoinMultiMesh"
	_coin_mm.multimesh = mm
	_coin_mm.material_override = Coin._material
	add_child(_coin_mm)


## B1: dormant-слой — декор-монеты без физ-тел (изобилие). Пустой на старте;
## наполняется дегидрацией осевших дальних монет и кнопкой seed_dormant().
func _build_dormant_field() -> void:
	_dormant = CoinDormant.new()
	_dormant.name = "DormantField"
	# custom_aabb на весь уровень (кольцо + коридор до z≈72): без пересчёта AABB.
	var r: float = level.ring_radius if level.ring_radius > 0.0 else 60.0
	var ctr := level.ring_center
	var aabb := AABB(Vector3(ctr.x - r - 5, -2, ctr.z - r - 5),
		Vector3(2 * r + 10, 12, 2 * r + 90))
	add_child(_dormant)
	# B6: декор-слой на дешёвом LOD-меше/материале (fill-rate Mali на тысячах монет).
	var segs: int = Coin.dormant_lod_segs if Coin.dormant_lod_segs > 0 else CFG.DORMANT_LOD_SEGS
	Coin._ensure_lod(segs, Coin.dormant_mat_cheap)
	_dormant.setup(CFG.DORMANT_MAX, aabb, Coin._mesh_lod, Coin._material_lod)


## Засеять n декор-монет (worth=1) ковром по арене — изобилие на экране. Лежат
## плашмя у земли; гидрируются в тела по подъезду дозера. rndv → не трогает сим.
func seed_dormant(n: int) -> void:
	if _dormant == null:
		return
	var r_max: float = level.ring_radius * 0.9 if level.ring_radius > 0.0 else 40.0
	var ctr := level.ring_center
	for i in n:
		var a := rndv() * TAU
		var rr := sqrt(rndv()) * r_max
		var b := Basis.from_euler(Vector3((rndv() - 0.5) * 0.5, rndv() * TAU, (rndv() - 0.5) * 0.5))
		var xf := Transform3D(b, Vector3(
			ctr.x + cos(a) * rr, 0.03 + rndv() * 0.14, ctr.z + sin(a) * rr))
		if _dormant.add(xf, 1) < 0:
			break  # слой полон


## B2: сколько ещё тел можно поднять под кэп (может быть <0, если active > cap).
func budget_left() -> int:
	return cap - pool.active_count()


## B2 AIMD: держим physics-мс у цели подстройкой кэпа активных тел. EMA каждый
## тик; раз в 30 тиков шаг: перегруз → мультипликативное сжатие (×0.9), запас →
## аддитивный рост (+25). Деадбенд (0.7×target) против осцилляции. --cap=N замораживает.
func _budget_tick() -> void:
	# Заморозка: --cap=N; либо смоуки (детерминизм — AIMD читает реальный тайминг).
	# Probe (телефон) — адаптируем: показать само-сжатие кэпа это и есть цель.
	if _cap_frozen or (test_mode and not _probe):
		return
	var pm := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_phys_ema += (pm - _phys_ema) * CFG.BUDGET_EMA_K
	if Engine.get_physics_frames() % 30 != 0:
		return
	if _phys_ema > CFG.BUDGET_TARGET_MS:
		cap = maxi(100, int(cap * 0.9))
	elif _phys_ema < CFG.BUDGET_TARGET_MS * 0.7:
		cap = mini(pool.size, cap + 25)


## B1 ГИДРАЦИЯ: dormant-записи в радиусе HYDRATE_R вокруг смещённого центра →
## поднимаем тела из пула, бюджет HYDRATE_TICK_BUDGET/тик. Сортировка ближних-
## первыми (анти нож-призрак) — ТОЛЬКО при дефиците бюджета (иначе порядок неважен,
## экономим сортировку/аллокации на горячем пути). При пустом пуле ЯДРО (≤CORE_R)
## гидрируется безусловно за счёт эвакуации дальних спящих тел: список строим ОДИН
## раз/тик (не O(pool) на кандидата) + кап EVACUATE_TICK_BUDGET. Удаляем записи
## ПОСЛЕ всех чтений по убыванию индекса (swap-remove в CoinDormant двигает индексы).
func _hydrate_pass() -> void:
	if _dormant == null or _dormant.count() == 0:
		return
	var fwd := Vector3(sin(heading), 0, cos(heading))
	var center := dozer.position + fwd * (speed_now * 0.35)  # упреждение по движению
	var idxs := _dormant.query_circle(center, CFG.HYDRATE_R)
	var n := idxs.size()
	if n == 0:
		return
	# B2: нормальная гидрация — только под кэп (budget_left). Сверх кэпа поднимается
	# лишь ЯДРО (через эвакуацию дальних тел ниже) — анти нож-призрак важнее кэпа.
	var budget := mini(CFG.HYDRATE_TICK_BUDGET, maxi(0, budget_left()))
	var order := idxs
	if n > budget:  # порядок (ближние первыми) важен при дефиците бюджета/у кэпа
		var cand: Array = []
		cand.resize(n)
		for k in n:
			var i := idxs[k]
			var q: Vector3 = _dormant.get_xform(i).origin
			var dx := q.x - dozer.position.x
			var dz := q.z - dozer.position.z
			cand[k] = [dx * dx + dz * dz, i]
		cand.sort_custom(_cmp_pair)
		order = PackedInt32Array()
		order.resize(n)
		for k in n:
			order[k] = cand[k][1]
	var core_r2 := CFG.HYDRATE_CORE_R * CFG.HYDRATE_CORE_R
	var evac_budget := CFG.EVACUATE_TICK_BUDGET
	var evac: Array = []
	var evac_built := false
	var to_remove := PackedInt32Array()
	for k in order.size():
		var i := order[k]
		var xf := _dormant.get_xform(i)
		var dx := xf.origin.x - dozer.position.x
		var dz := xf.origin.z - dozer.position.z
		var is_core := dx * dx + dz * dz <= core_r2
		var c: RigidBody3D = null
		if budget > 0:
			c = pool.spawn(xf.origin, false)
			if c != null:
				budget -= 1
		if c == null:
			# Бюджет исчерпан (у кэпа) или пул физически полон. ЯДРО (у ножа) —
			# безусловно: эвакуируем дальнее тело (active не растёт сверх cap). Не-ядро
			# у кэпа — стоп (сортировка ближних-первыми → дальше только дальние).
			if not is_core or evac_budget <= 0:
				break
			if not evac_built:
				evac = _build_evac_list(center)
				evac_built = true
			c = _evac_pop(evac)
			if c == null:
				break
			evac_budget -= 1
		c.transform = xf
		c.worth = _dormant.get_worth(i)
		c.sleeping = true
		to_remove.append(i)
		_hydrate_total += 1
	to_remove.sort()  # нативный sort PackedInt32Array; удаляем с конца (по убыванию)
	var j := to_remove.size() - 1
	while j >= 0:
		_dormant.remove(to_remove[j])
		j -= 1


static func _cmp_pair(a: Array, b: Array) -> bool:
	return a[0] < b[0]


## Дальние спящие тела ВНЕ HYDRATE_R от центра (анти-трэш: не выселяем тело внутри
## круга гидрации), по возрастанию d2 → pop_back = самое дальнее. Строим ОДИН раз/тик.
func _build_evac_list(center: Vector3) -> Array:
	var hr2 := CFG.HYDRATE_R * CFG.HYDRATE_R
	var lst: Array = []
	for coin in pool.get_children():
		if coin.get_meta("in_pool", false) or not coin.sleeping:
			continue
		var p: Vector3 = coin.global_position
		var dx := p.x - center.x
		var dz := p.z - center.z
		var d2 := dx * dx + dz * dz
		if d2 > hr2:
			lst.append([d2, coin])
	lst.sort_custom(_cmp_pair)
	return lst


## Снять дальнее спящее тело: дегидрировать (worth → слой) и вернуть свежеспавненным.
func _evac_pop(lst: Array) -> RigidBody3D:
	while not lst.is_empty():
		var pair: Array = lst.pop_back()  # самое дальнее
		var coin: RigidBody3D = pair[1]
		if coin.get_meta("in_pool", false):
			continue  # уже занято/освобождено — пропустить
		_dormant.add(coin.global_transform, coin.worth)
		pool.release(coin)
		return pool.spawn(Vector3.ZERO, false)
	return null


## Рендер всех монет одним MultiMesh (порт web syncCoins/InstancedMesh): каждый
## кадр пишем трансформ по coin.idx; запаркованные пулом — скрытый инстанс.
func _sync_coins_mm() -> void:
	if _coin_mm == null:
		return
	var mm := _coin_mm.multimesh
	for coin in pool.get_children():
		if coin.get_meta("in_pool", false):
			mm.set_instance_transform(coin.idx, _HIDDEN_XF)
		else:
			mm.set_instance_transform(coin.idx, coin.global_transform)


func _process(delta: float) -> void:
	_update_camera(delta)
	_sync_coins_mm()
