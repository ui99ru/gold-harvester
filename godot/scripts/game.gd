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
var shot: ShotTool
var dozer: Dozer
var dozer_shadow: MeshInstance3D
var pool: CoinPool
var clinks: ClinkAudio
var fx: Fx
var gates: Array[Gate] = []

# Сущности (ворота, этап 6) сбрасывают side-регистрацию телепортированной монеты
var side_resetters: Array[Callable] = []

var _bank_label: Label
var _bank_shown := 0.0

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
	fx = Fx.new()
	fx.game = self
	add_child(fx)
	pool = CoinPool.new()
	pool.name = "Coins"
	add_child(pool)
	pool.setup(CFG.COIN_N, _on_coin_clink)
	_build_entities()
	_build_bank_ui()
	for i in level.start_coins:
		place_at_source(pool.spawn(Vector3.ZERO, false))
	shot = ShotTool.new()
	shot.info_cb = func() -> String:
		return "bank=%d dozer=%s heading=%.2f zoom=%.2f coins=%d" % [
			bank, dozer.position, heading, cam_zoom, pool.active_count()]
	add_child(shot)
	phase = "play"  # стартовый экран — этап 9
	_setup_smoke()
	_update_camera(0.0)


## Респаун монеты в источнике (web main.js:151): seeded-разброс + падение
## с высоты — оседают в кучу некопланарно, солвер стабилен.
func place_at_source(coin: RigidBody3D) -> void:
	if coin == null:
		return
	var a := rnd() * 6.28
	var r := sqrt(rnd()) * level.source_radius
	var y := CFG.COIN_THK * 0.5 + rnd() * 6.0
	coin.worth = 1
	for cb in side_resetters:
		cb.call(coin.idx)  # телепорт != пересечение ворот
	coin.transform = Transform3D(Basis(),
		level.source_pos + Vector3(cos(a) * r, y, sin(a) * r))
	coin.linear_velocity = Vector3.ZERO
	coin.angular_velocity = Vector3.ZERO


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
			# pad_knife / trash — этап 7


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


func on_gate_unlocked(g: Gate) -> void:
	shake += 0.3
	fx.sparks(g.position.x, g.position.z, 22)
	fx.popup(Vector3(g.position.x, 3, g.position.z), "ОТКРЫТО x%d" % g.mult, Color("aef0c0"))
	# chime('upgrade') — этап 8


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

	# 50 камней-додекаэдров по кругу (main.js:43-44, rnd-поток)
	var rock_mat := StandardMaterial3D.new()
	rock_mat.albedo_color = Color("8f72c8")
	rock_mat.roughness = 1.0
	for i in 50:
		var a := rnd() * 6.28
		var r := 70.0 + rnd() * 35.0
		var s := 3.0 + rnd() * 5.0
		var m := MeshInstance3D.new()
		var sph := SphereMesh.new()     # low-poly аналог DodecahedronGeometry
		sph.radius = s
		sph.height = s * 2.0
		sph.radial_segments = 6
		sph.rings = 3
		m.mesh = sph
		m.material_override = rock_mat
		m.position = Vector3(cos(a) * r, s * 0.5 - 0.5, sin(a) * r)
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
		return
	if _script_target != Vector3.INF:
		_apply_script_input()
	else:
		_apply_live_input()
	sim_step(delta)
	_smoke_tick()


func sim_step(dt: float) -> void:
	sim_time += dt
	if not is_nan(ctrl_desired):
		var d := wrapf(ctrl_desired - heading, -PI, PI)
		heading += d * minf(1.0, dt * CFG.HEADING_LERP)
	speed_now += ((up_move if ctrl_moving else 0.0) - speed_now) * minf(1.0, dt * CFG.SPEED_LERP)
	dozer.position.x += sin(heading) * speed_now * dt
	dozer.position.z += cos(heading) * speed_now * dt
	_resolve_obstacles()
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
	dozer_pos = dozer.position
	dozer_shadow.position = Vector3(dozer.position.x, 0.04, dozer.position.z)
	# Экономика (web stepEconomy; физика монет шагает движком после)
	for gt in gates:
		gt.step(dt)
	_update_bank_ui()


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
		for i in 40:
			pool.spawn(Vector3.ZERO, false)
		var n := 0
		for coin in pool.get_children():
			if coin.freeze:
				continue
			coin.position = Vector3(
				-1.5 + 0.75 * (n % 5),
				0.1 + 0.15 * floorf(n / 20.0),
				11.0 + 0.8 * (floori(n / 5.0) % 4))
			n += 1
		_script_target = Vector3(0, 0, 20)
	elif _smoke_mode == "gatefill":
		# 12 монет узкой кучей (в ширину ковша) перед матом ворот-1 —
		# дозер вталкивает, fill>=10 -> разблок
		for i in 12:
			pool.spawn(Vector3(-0.6 + 0.6 * (i % 3), 0.1, 15.4 + 0.55 * floorf(i / 3.0)), false)
		dozer.position = Vector3(0, 0, 12)
		_script_target = Vector3(0, 0, 19.5)


func _smoke_tick() -> void:
	if _smoke_mode == "":
		return
	_smoke_ticks += 1
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
	elif _smoke_mode == "push":
		if _smoke_ticks >= 600:  # 10 c
			var fallen := 0
			var tunneled := 0
			var plowed := 0
			var inv := dozer.global_transform.affine_inverse()
			for coin in pool.get_children():
				if coin.freeze:
					continue
				var p: Vector3 = coin.global_position
				if p.y < -0.5:
					fallen += 1
				if p.z > 14.5:
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
