extends Node3D
## Игра «Золотодозер»: оркестратор. Порт src/main.js на Godot.
## Порядок сим-шага повторяет web simStep: ввод → дозер → кинематик-позы →
## [физика движком] → экономика → клинки → частицы. Карта — данные (levels/*.tres).

const LEVEL := preload("res://levels/level_01.tres")

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

# Калибровка света по web-эталону (--cal=sun,ambient): множители энергий.
# Откалиброванные значения вшиваются в _build_environment после фита.
var _cal_sun := 1.0
var _cal_amb := 1.0

# Поза дозера (этап 3 заменит на dozer.gd; пока статичная цель камеры)
var dozer_pos := Vector3.ZERO


func _ready() -> void:
	level = LEVEL
	dozer_pos = level.dozer_start
	_parse_user_args()  # может переопределить позу (--pose=)
	_build_environment()
	_build_ground_and_rocks()
	_build_walls()
	_build_camera()
	shot = ShotTool.new()
	shot.info_cb = func() -> String:
		return "bank=%d dozer=%s zoom=%.2f" % [bank, dozer_pos, cam_zoom]
	add_child(shot)
	_update_camera(0.0)


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
			test_mode = true
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
	camera.position = Vector3(
		dozer_pos.x + back * sa + jx, hgt + jy, dozer_pos.z - back * ca)
	camera.look_at(Vector3(dozer_pos.x - la * sa, 0, dozer_pos.z + la * ca), Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	# Зум колесом (web: ×1.08 за щелчок, клэмп 0.45..2.2)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			cam_zoom = clampf(cam_zoom * 1.08, CFG.CAM_ZOOM_MIN, CFG.CAM_ZOOM_MAX)
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			cam_zoom = clampf(cam_zoom / 1.08, CFG.CAM_ZOOM_MIN, CFG.CAM_ZOOM_MAX)


func _process(delta: float) -> void:
	_update_camera(delta)
