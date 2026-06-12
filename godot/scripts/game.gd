class_name Game
extends Node3D
## Игра «Золотодозер»: оркестратор. Порт src/main.js на Godot.
## Порядок сим-шага повторяет web simStep: ввод → дозер → кинематик-позы →
## [физика движком] → экономика → клинки → частицы. Карта — данные (levels/*.tres).

const LEVEL := preload("res://levels/level_01.tres")
const DOZER_R := 1.6
const BLADE_R := 0.35
const GRIP_LANE := 0.7   # O3b: ширина полосы захвата (≈ диаметр монеты)
const GRIP_CAP := 8      # O3b: высота стопки в полосе до перелива обратно в физику

# --- Мутабельное состояние (web: src/state.js) ---
var up_blade_half := CFG.UP_BLADE_HALF
var up_reach := CFG.UP_REACH
var up_move := CFG.MOVE
var up_mult := CFG.UP_MULT

var phase := "start"     # start | play
var bank := 0
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

var _drag_pos := Vector2.ZERO
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
var _pool_size_override := 0
var _gd_accum := 0
var _sim_us_last := 0   # мкс GDScript-сима за последний физ-тик → split «jolt/gd» в HUD
var _grip_lanes := {}   # O3b: счётчик стопки на полосу (переиспользуется каждый кадр)

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
	_update_camera(0.0)


## Респаун монеты в источнике: у земли + радиальный разлёт «волной». Монеты
## расплываются тонким слоем, НЕ складываются в плотную башню. Прежний вариант
## (узкий радиус 0.8 + падение с 6 м) давал колонну в ~250 слоёв с глубоким
## взаимопроникновением → взрыв контактов в ковше (jolt 500+ мс). Трение/демпф
## быстро тормозят разлёт; некомпланарный наклон держит солвер стабильным.
func place_at_source(coin: RigidBody3D) -> void:
	if coin == null:
		return
	coin.ungrip()       # O3b: снять из ковша (если была gripped)
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

	# Performance HUD + тумблеры тюнинга (петля «десктоп + прокси телефона»)
	var hud := preload("res://scripts/performance_hud.gd").new()
	hud.pool_stats_cb = func() -> Vector2i:
		return Vector2i(pool.active_count(), pool.free_count())
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
	var seeded := false
	for arg in OS.get_cmdline_user_args():
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
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			call_deferred("_request_shot", arg.trim_prefix("--shot="))


func _request_shot(path: String) -> void:
	shot.request(path, 30)


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
	env.glow_enabled = not OS.get_cmdline_user_args().has("--no-glow")
	env.glow_hdr_threshold = CFG.BLOOM_THR
	env.glow_intensity = CFG.BLOOM_INTEN

	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	world_env = env

	sun = DirectionalLight3D.new()
	sun.light_color = Color("fff4de")
	sun.light_energy = CFG.SUN_INT * 0.30 * _cal_sun  # калибровка по web-эталону
	sun.shadow_enabled = true
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

	# Кольцо скал — граница сцены (правка по рефу): плотная стена камней по
	# окружности уровня + невидимый StaticBody-многоугольник держит монеты.
	# Дозер клэмпится радиально в sim_step. Вне кольца — редкие дальние камни.
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color("8f72c8")
	rock_mat.roughness = 1.0
	var rc := level.ring_center
	var rr := level.ring_radius
	if rr > 0.0:
		for i in 80:  # плотное кольцо: ~0.08 рад между камнями, перекрываются
			var a := (i / 80.0) * TAU + (rnd() - 0.5) * 0.05
			var r := rr + 1.5 + rnd() * 3.0  # чуть снаружи барьера
			# Южная дуга (между камерой и сценой) — низкий бордюр, не загораживает
			var south := clampf(-sin(a), 0.0, 1.0)  # 1 на юге, 0 на севере
			var s := lerpf(2.5 + rnd() * 4.0, 1.0 + rnd() * 0.8, south)
			_add_rock(rock_mat, Vector3(rc.x + cos(a) * r, s * 0.4 - 0.5, rc.z + sin(a) * r), s)
		# Невидимый барьер: 32 box-сегмента по хорде окружности
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
	# Дальние декоративные камни (как web, реже)
	for i in 24:
		var a := rnd() * 6.28
		var r := 70.0 + rnd() * 35.0
		var s := 3.0 + rnd() * 5.0
		_add_rock(rock_mat, Vector3(cos(a) * r, s * 0.5 - 0.5, sin(a) * r), s)


func _add_rock(mat: Material, pos: Vector3, s: float) -> void:
	var m := MeshInstance3D.new()
	var sph := SphereMesh.new()     # low-poly аналог DodecahedronGeometry
	sph.radius = s
	sph.height = s * 2.0
	sph.radial_segments = 6
	sph.rings = 3
	m.mesh = sph
	m.material_override = mat
	m.position = pos
	m.rotation = Vector3(rnd() * 3, rnd() * 3, rnd() * 3)
	add_child(m)


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
	# Драг по земле = руль (web pointerdown/move/up; мышь эмулирует тач)
	elif event is InputEventScreenTouch:
		driving = event.pressed
		_drag_pos = event.position
	elif event is InputEventScreenDrag and driving:
		_drag_pos = event.position


# --- Ввод -> ctrl (web applyLiveInput/applyScriptInput :322-331) ---

func _apply_live_input() -> void:
	ctrl_desired = NAN
	ctrl_moving = false
	if driving:
		var origin := camera.project_ray_origin(_drag_pos)
		var dir := camera.project_ray_normal(_drag_pos)
		if absf(dir.y) > 0.0001:
			var t := -origin.y / dir.y
			if t > 0.0:
				var hit := origin + dir * t
				var dx := hit.x - dozer.position.x
				var dz := hit.z - dozer.position.z
				if dx * dx + dz * dz > 0.4:
					ctrl_desired = atan2(dx, dz)
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
	_update_blade_grip()       # O3b: монеты в зоне ножа — позиционные (не грузят солвер)
	audio.pump_engine(minf(1.0, speed_now / up_move), phase == "play")
	# Пыль из-под траков (web :377, :247)
	if speed_now > 3.5 and rndv() < 0.6:
		_emit_dust()
	dozer_pos = dozer.position
	dozer_shadow.position = Vector3(dozer.position.x, 0.04, dozer.position.z)
	# Активный пузырь (O3 «физический LOD»): осевшие дальние монеты выводим из
	# dynamic-симуляции (make_dormant: freeze=статик — вне островов/солвера Jolt,
	# но коллайдер и видима), а при подъезде дозера возвращаем (make_active). В
	# Jolt-«динамике» остаются лишь монеты у ножа → снимается остаток ~45 мс/тик
	# от 1000 спящих тел. Гистерезис: спим >8 м, будим <6 м (дозер reach ~2 м —
	# монета успевает стать коллайдером до касания).
	var _gd0 := Time.get_ticks_usec() if _smoke_mode == "stress" else 0
	if Engine.get_physics_frames() % 10 == 0:
		var dz := dozer.position
		for coin in pool.get_children():
			if coin.get_meta("in_pool", false):
				continue  # запаркованные пулом
			var p: Vector3 = coin.global_position
			var dx := p.x - dz.x
			var dzz := p.z - dz.z
			var d2 := dx * dx + dzz * dzz
			if coin.dormant:
				if d2 < 36.0:
					coin.make_active()
			elif d2 > 64.0 and p.y < 0.6 \
					and coin.linear_velocity.length_squared() < 1.0:
				coin.make_dormant()
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


## O3b «позиционный нож» (порт инсайта web §5.5): монеты в зоне ножа выводим из
## физики (grip: kinematic-freeze + слои 0) и каждый кадр снапаем к полосам/стопкам,
## едущим с дозером. Реальная физика — только у входящих/разлетающихся/осыпающихся.
## Так в Jolt-динамике остаётся горстка, а визуально — полный ковш золота.
func _update_blade_grip() -> void:
	var dpos := dozer.position
	var h := heading
	var fwd := Vector3(sin(h), 0.0, cos(h))
	var rgt := Vector3(cos(h), 0.0, -sin(h))
	var bhalf := dozer.blade_hx() + 0.2
	var front: float = Dozer.BLADE_FWD + 0.35
	var thk := CFG.COIN_THK
	var flat := Basis(Vector3.UP, h)
	_grip_lanes.clear()
	for coin in pool.get_children():
		if coin.get_meta("in_pool", false) or coin.dormant:
			continue
		var dx: float = coin.global_position.x - dpos.x
		var dz: float = coin.global_position.z - dpos.z
		var lz := dx * fwd.x + dz * fwd.z
		var lx := dx * rgt.x + dz * rgt.z
		if lz > 0.0 and lz < front + 0.7 and absf(lx) < bhalf:
			var lane := roundi(lx / GRIP_LANE)
			var cnt: int = _grip_lanes.get(lane, 0)
			if cnt >= GRIP_CAP:        # полоса полна → перелив: пусть валится физикой вбок
				if coin.gripped:
					coin.ungrip()
				continue
			_grip_lanes[lane] = cnt + 1
			coin.grip()
			var yy := thk * 0.5 + cnt * thk * 0.95
			coin.global_transform = Transform3D(flat,
				dpos + fwd * front + rgt * (lane * GRIP_LANE) + Vector3(0.0, yy, 0.0))
		elif coin.gripped:
			coin.ungrip()


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
		var n := 0
		for i in 800:
			var cc := pool.spawn(Vector3(
				-1.2 + 0.3 * (n % 9),
				0.1 + 0.3 * floorf(n / 90.0),
				8.0 + 0.3 * (floori(n / 9.0) % 10)), false)
			n += 1
		dozer.position = Vector3(20, 0, 30)  # дозер далеко, не мешает
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


func _descendants(n: Node) -> int:
	var c := n.get_child_count()
	for ch in n.get_children():
		c += _descendants(ch)
	return c


func _smoke_tick() -> void:
	if _smoke_mode == "":
		return
	_smoke_ticks += 1
	# Пик физики: max времени ОДНОГО физ-тика = кандидат во фриз (не среднее)
	var pm := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	if pm > _phys_max:
		_phys_max = pm
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
		if _smoke_ticks >= 3600:  # 60 c
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
			var books := pool.active_count() + pool.free_count() == CFG.COIN_N
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
			var books := pool.active_count() + pool.free_count() == CFG.COIN_N
			var ok := bh_ok and pad_gone and stand_gone and books and bank >= 120.0
			print("SMOKE %s: blade_half=%.1f pad_gone=%s stand_gone=%s bank=%.0f books=%s" %
				["OK" if ok else "FAIL", up_blade_half, pad_gone, stand_gone, bank, books])
			get_tree().quit(0 if ok else 1)
	elif _smoke_mode == "trash":
		if _smoke_ticks >= 240:  # 4 c
			var books := pool.active_count() + pool.free_count() == CFG.COIN_N
			# 8 сгорели без банка; активны только 5 стартовых у источника
			var ok := bank == 0.0 and pool.active_count() == 5 and books
			print("SMOKE %s: bank=%.0f active=%d books=%s" %
				["OK" if ok else "FAIL", bank, pool.active_count(), books])
			get_tree().quit(0 if ok else 1)
	elif _smoke_mode == "wave":
		if _smoke_ticks >= 360:  # 6 c: волна + парковка в створе (анти-фарм)
			var total_worth := 0
			var n_active := 0
			for coin in pool.get_children():
				if coin.get_meta("in_pool", false):
					continue  # O3: dormant-монеты (статик, но в игре) считаем
				total_worth += coin.worth
				n_active += 1
			var books := pool.active_count() + pool.free_count() == CFG.COIN_N
			var ok := total_worth == 10 and n_active == 10 and books
			print("SMOKE %s: worth_sum=%d active=%d books=%s" %
				["OK" if ok else "FAIL", total_worth, n_active, books])
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


func _process(delta: float) -> void:
	_update_camera(delta)
