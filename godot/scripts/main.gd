extends Node3D
## Игровой цикл: построение сцены кодом, спавн монет, смоук-тесты.
## Сцены (.tscn) минимальны — вся геометрия создаётся здесь (см. бриф §2).

# --- Геометрия лотка (монета r=0.40, см. coin.gd) ---
const TRAY_TILT_DEG := 6.0   # наклон к обрыву (+z вниз)
const TRAY_W := 9.0          # внутренняя ширина
const TRAY_L := 12.0         # длина дна
const WALL_H := 1.2
const WALL_T := 0.4
const FLOOR_T := 0.5

# Палитра web-версии (src/main.js)
const BG_COLOR := Color("7c6cb2")
const GROUND_COLOR := Color("9c8fc0")
const TRAY_COLOR := Color("4a4466")

var tray: Node3D

var _shot_path := ""
var _shot_frames_left := 0


func _ready() -> void:
	_build_environment()
	_build_tray()
	_build_camera()
	_parse_user_args()


# --- Построение сцены ---

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.85, 1.0)
	env.ambient_light_energy = 0.35
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.light_color = Color("fff4de")
	sun.light_energy = 1.4
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.rotation_degrees = Vector3(-52.0, 28.0, 0.0)
	add_child(sun)

	# Визуальный фон-грунт под лотком (без коллайдера)
	var ground := MeshInstance3D.new()
	var gmesh := PlaneMesh.new()
	gmesh.size = Vector2(120.0, 120.0)
	ground.mesh = gmesh
	ground.material_override = _flat_material(GROUND_COLOR)
	ground.position = Vector3(0, -4.0, 0)
	add_child(ground)


func _build_tray() -> void:
	tray = Node3D.new()
	tray.name = "Tray"
	tray.rotation_degrees.x = TRAY_TILT_DEG  # +z край ниже -> монеты ползут к обрыву
	add_child(tray)

	var body := StaticBody3D.new()
	body.name = "TrayBody"
	body.physics_material_override = _tray_phys_material()
	tray.add_child(body)

	var mat := _flat_material(TRAY_COLOR)
	var half_w := TRAY_W / 2.0
	var half_l := TRAY_L / 2.0

	# Дно: верхняя плоскость в локальном y=0
	_add_box(body, Vector3(TRAY_W + 2.0 * WALL_T, FLOOR_T, TRAY_L),
		Vector3(0, -FLOOR_T / 2.0, 0), mat)
	# Борта вдоль x = ±(half_w + WALL_T/2)
	for side in [-1.0, 1.0]:
		_add_box(body, Vector3(WALL_T, WALL_H, TRAY_L),
			Vector3(side * (half_w + WALL_T / 2.0), WALL_H / 2.0, 0), mat)
	# Задняя стенка (дальняя от обрыва, z = -half_l)
	_add_box(body, Vector3(TRAY_W + 2.0 * WALL_T, WALL_H, WALL_T),
		Vector3(0, WALL_H / 2.0, -(half_l - WALL_T / 2.0)), mat)
	# Передний край (z = +half_l) открыт — обрыв, зона сбора ниже (этап 3)


func _build_camera() -> void:
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.fov = 45.0
	cam.position = Vector3(0, 13.0, 12.0)
	cam.look_at_from_position(cam.position, Vector3(0, 0, 0.5), Vector3.UP)
	add_child(cam)


# --- Утилиты ---

func _add_box(parent: PhysicsBody3D, size: Vector3, pos: Vector3, mat: Material) -> void:
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	shape.shape = box
	shape.position = pos
	parent.add_child(shape)

	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)


func _flat_material(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.9
	return m


func _tray_phys_material() -> PhysicsMaterial:
	var pm := PhysicsMaterial.new()
	pm.friction = 0.8
	pm.bounce = 0.05
	return pm


# --- Смоук-тесты и скриншоты (запуск: godot --path godot ++ --shot=out/x.png) ---

func _parse_user_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot_path = arg.trim_prefix("--shot=")
			_shot_frames_left = 20  # дать кадрам отрисоваться


func _process(_delta: float) -> void:
	if _shot_path != "":
		_shot_frames_left -= 1
		if _shot_frames_left <= 0:
			_take_shot()


func _take_shot() -> void:
	var img := get_viewport().get_texture().get_image()
	var abs_path := _shot_path
	if abs_path.is_relative_path():
		abs_path = ProjectSettings.globalize_path("res://").path_join(_shot_path)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var err := img.save_png(abs_path)
	print("SHOT %s -> %s" % [("OK" if err == OK else "FAIL %d" % err), abs_path])
	_shot_path = ""
	get_tree().quit(0 if err == OK else 1)
