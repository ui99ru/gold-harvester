extends Node3D
## Игровой цикл: построение сцены кодом, спавн монет, смоук-тесты.
## Сцены (.tscn) минимальны — вся геометрия создаётся здесь (см. бриф §2).

# --- Геометрия лотка (монета r=0.40, см. coin.gd) ---
const TRAY_TILT_DEG := 6.0   # наклон к обрыву (+z вниз)
const TRAY_W := 9.0          # внутренняя ширина
const TRAY_L := 9.0          # длина дна (короткий: волна от толкателя доходит до обрыва)
const WALL_H := 1.2
const WALL_T := 0.4
const FLOOR_T := 0.5

# Палитра web-версии (src/main.js)
const BG_COLOR := Color("7c6cb2")
const GROUND_COLOR := Color("9c8fc0")
const TRAY_COLOR := Color("4a4466")

const COIN_SCENE := preload("res://scenes/coin.tscn")
const PUSHER_SCENE := preload("res://scenes/pusher.tscn")
const SPAWN_HEIGHT := 3.0    # глобальная высота плоскости спавна по тапу
const AUDIO_POOL_SIZE := 8
const CLINK_MIN_INTERVAL_MS := 50
const KILL_Y := -6.0         # ниже — монета потеряна, возврат без счёта
const POOL_SIZE := 250

var tray: Node3D
var coins_root: Node3D
var camera: Camera3D
var score := 0

var _pool: Array[RigidBody3D] = []
var _score_label: Label

var _audio_players: Array[AudioStreamPlayer3D] = []
var _clink_streams: Array[AudioStream] = []
var _audio_idx := 0
var _last_clink_ms := 0

var _shot_path := ""
var _shot_frames_left := 0
var _smoke_mode := ""
var _smoke_ticks := 0
var _phys_time_accum := 0.0


func _ready() -> void:
	_build_environment()
	_build_tray()
	_build_pusher()
	_build_collect_zone()
	_build_camera()
	_build_audio()
	_build_score_ui()
	_build_hud()
	coins_root = Node3D.new()
	coins_root.name = "Coins"
	add_child(coins_root)
	_init_pool()
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
	_add_box(body, Vector3(TRAY_W + 2.0 * WALL_T, WALL_H * 2.2, WALL_T),
		Vector3(0, WALL_H * 1.1, -(half_l - WALL_T / 2.0)), mat)
	# «Капот»-скребок над толкателем: монеты, упавшие на его крышу, при отходе
	# толкателя упираются в кромку капота и ссыпаются на дно в зону подметания.
	# Низ капота 1.05 — чуть выше крыши толкателя (1.0), он скользит под капотом.
	var hood_z_from := -half_l
	var hood_z_to := -1.85
	_add_box(body, Vector3(TRAY_W, 0.55, hood_z_to - hood_z_from),
		Vector3(0, 1.05 + 0.275, (hood_z_from + hood_z_to) / 2.0), mat)
	# Передний край (z = +half_l) открыт — обрыв, зона сбора ниже (этап 3)


func _build_pusher() -> void:
	# В локальном (наклонном) пространстве лотка: скользит по дну у задней стенки
	# Ход фронта: z ∈ [-2.1, +1.5]; в крайнем заднем положении тыл вплотную к стенке
	var pusher := PUSHER_SCENE.instantiate()
	pusher.position = Vector3(0, 0.5, -1.3)
	tray.add_child(pusher)


func _build_collect_zone() -> void:
	# Под обрывом переднего края (глобальные координаты)
	var area := Area3D.new()
	area.name = "CollectZone"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(14.0, 2.0, 5.0)
	cs.shape = box
	area.add_child(cs)
	area.position = Vector3(0, -2.5, 6.3)
	area.body_entered.connect(_on_coin_collected)
	add_child(area)


func _build_score_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_score_label = Label.new()
	_score_label.position = Vector2(24, 16)
	_score_label.add_theme_font_size_override("font_size", 36)
	_score_label.text = "0"
	layer.add_child(_score_label)


func _build_hud() -> void:
	var hud := preload("res://scripts/performance_hud.gd").new()
	hud.spawn_50_cb = _spawn_stress_batch
	hud.pool_stats_cb = func() -> Vector2i:
		return Vector2i(active_coins(), _pool.size())
	add_child(hud)


func _spawn_stress_batch() -> void:
	for i in 50:
		spawn_coin(Vector3(randf_range(-3.5, 3.5),
			2.0 + 0.3 * (i % 5), randf_range(-1.0, 4.0)))


func _on_coin_collected(body: Node3D) -> void:
	# Сигнал приходит во время flush физики — деактивация отложенно
	if body is RigidBody3D and not body.get_meta("dead", true):
		body.set_meta("dead", true)
		score += 1
		_score_label.text = str(score)
		_finish_release.call_deferred(body)


func _finish_release(coin: RigidBody3D) -> void:
	_deactivate(coin)
	_pool.append(coin)


func _build_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 45.0
	camera.position = Vector3(0, 13.0, 12.0)
	camera.look_at_from_position(camera.position, Vector3(0, 0, 0.5), Vector3.UP)
	add_child(camera)


func _build_audio() -> void:
	for i in 4:
		_clink_streams.append(load("res://assets/audio/clink_%d.wav" % (i + 1)))
	for i in AUDIO_POOL_SIZE:
		var p := AudioStreamPlayer3D.new()
		p.max_polyphony = 1
		add_child(p)
		_audio_players.append(p)


# --- Пул монет (бриф §4: предсоздать, неактивные выключены) ---

func _init_pool() -> void:
	for i in POOL_SIZE:
		var coin: RigidBody3D = COIN_SCENE.instantiate()
		coin.clink_cb = _on_coin_clink
		coins_root.add_child(coin)
		_deactivate(coin)
		_pool.append(coin)


func _deactivate(coin: RigidBody3D) -> void:
	coin.set_meta("dead", true)
	coin.freeze = true
	coin.visible = false
	# Слои обязательно в 0: замороженное тело — статик и иначе коллайдит
	coin.collision_layer = 0
	coin.collision_mask = 0
	coin.position = Vector3(0, -100, 0)


func spawn_coin(pos: Vector3, random_tilt := true) -> RigidBody3D:
	if _pool.is_empty():
		return null
	var coin: RigidBody3D = _pool.pop_back()
	coin.set_meta("dead", false)
	coin.transform = Transform3D(Basis(), pos)
	if random_tilt:
		coin.rotation = Vector3(
			randf_range(-0.3, 0.3), randf_range(0, TAU), randf_range(-0.3, 0.3))
	coin.collision_layer = 1
	coin.collision_mask = 1
	coin.visible = true
	coin.freeze = false
	coin.linear_velocity = Vector3.ZERO
	coin.angular_velocity = Vector3.ZERO
	return coin


func active_coins() -> int:
	return POOL_SIZE - _pool.size()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventScreenTouch and event.pressed:
		_spawn_at_tap(event.position)


func _spawn_at_tap(screen_pos: Vector2) -> void:
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	if dir.y >= -0.01:
		return
	var t := (SPAWN_HEIGHT - origin.y) / dir.y
	var hit := origin + dir * t
	hit.x = clampf(hit.x, -TRAY_W / 2.0 + 0.5, TRAY_W / 2.0 - 0.5)
	# Не спавнить в щель за толкателем — там монеты зажимает между ним и стенкой
	hit.z = clampf(hit.z, -1.0, TRAY_L / 2.0 - 0.2)
	spawn_coin(hit)


func _on_coin_clink(pos: Vector3, strength: float) -> void:
	var now := Time.get_ticks_msec()
	if now - _last_clink_ms < CLINK_MIN_INTERVAL_MS:
		return
	_last_clink_ms = now
	var p := _audio_players[_audio_idx]
	_audio_idx = (_audio_idx + 1) % AUDIO_POOL_SIZE
	p.stream = _clink_streams[randi() % _clink_streams.size()]
	p.global_position = pos
	p.pitch_scale = randf_range(0.9, 1.1)
	p.volume_db = linear_to_db(clampf(strength, 0.15, 1.0))
	p.play()


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
# Headless: godot --headless --path godot ++ --smoke-stack

func _parse_user_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_shot_path = arg.trim_prefix("--shot=")
			_shot_frames_left = maxi(_shot_frames_left, 20)  # дать кадрам отрисоваться
		elif arg == "--drop-demo":
			# 50 монет для визуальной проверки (вместе с --shot)
			_shot_frames_left = 150
			for i in 50:
				spawn_coin(Vector3(randf_range(-3, 3), 1.6 + (i % 5) * 0.3,
					randf_range(-1.0, 4.0)))
		elif arg.begins_with("--smoke-"):
			_smoke_mode = arg.trim_prefix("--smoke-")
			seed(20260611)  # детерминированный прогон
			# НЕ ускорять Engine.time_scale: он растягивает эффективный шаг
			# физики, и монеты туннелируют сквозь дно. Смоук идёт в реальном времени.

	if _smoke_mode == "stack":
		# 10 столбиков по 5 монет — чистый тест стэкинга, толкатель убираем
		tray.get_node("Pusher").queue_free()
		for col in 10:
			var x := -3.0 + 1.5 * (col % 5)
			var z := 1.0 + 1.5 * floorf(col / 5.0)
			for row in 5:
				spawn_coin(Vector3(x, 1.0 + row * 0.25, z), false)
	elif _smoke_mode == "pusher":
		# Плотный слой перед толкателем — за 30 с волна должна дойти до зоны сбора
		for i in 120:
			spawn_coin(Vector3(randf_range(-3.8, 3.8),
				1.6 + 0.3 * (i % 4), randf_range(-1.0, 4.2)))
	elif _smoke_mode == "stress":
		# Весь пул на сцену (сетка 10x5x5) — базовый замер времени физики
		for i in POOL_SIZE:
			spawn_coin(Vector3(
				-3.6 + 0.8 * (i % 10),
				2.0 + 0.4 * floorf(i / 50.0),
				-0.6 + 1.1 * (floori(i / 10.0) % 5)))


func _physics_process(_delta: float) -> void:
	# Сметание потеряшек: ниже KILL_Y и мимо зоны сбора — возврат в пул без счёта
	if Engine.get_physics_frames() % 30 == 0 and coins_root != null:
		for coin in coins_root.get_children():
			if not coin.freeze and coin.global_position.y < KILL_Y:
				coin.set_meta("dead", true)
				_finish_release(coin)

	if _smoke_mode == "":
		return
	_smoke_ticks += 1
	if _smoke_mode == "stress":
		_phys_time_accum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	if _smoke_mode == "stack" and _smoke_ticks >= 360:  # 6 c симуляции
		_finish_smoke_stack()
	elif _smoke_mode == "pusher" and _smoke_ticks >= 1800:  # 30 c
		_finish_smoke_pusher()
	elif _smoke_mode == "stress" and _smoke_ticks >= 600:  # 10 c
		_finish_smoke_stress()


func _finish_smoke_stack() -> void:
	_smoke_mode = ""
	var total := 0
	var asleep := 0
	var fallen := 0
	for coin in coins_root.get_children():
		if coin.freeze:
			continue
		total += 1
		if coin.sleeping:
			asleep += 1
		if coin.global_position.y < -1.5:
			fallen += 1
	var ok := total == 50 and fallen == 0 and asleep >= total * 0.9
	print("SMOKE %s: coins=%d asleep=%d fallen=%d" %
		["OK" if ok else "FAIL", total, asleep, fallen])
	get_tree().quit(0 if ok else 1)


func _finish_smoke_pusher() -> void:
	_smoke_mode = ""
	var ok := score > 0 and active_coins() + _pool.size() == POOL_SIZE
	print("SMOKE %s: score=%d remaining=%d" %
		["OK" if ok else "FAIL", score, active_coins()])
	get_tree().quit(0 if ok else 1)


func _finish_smoke_stress() -> void:
	_smoke_mode = ""
	var avg_ms := 1000.0 * _phys_time_accum / 600.0
	var no_leak := active_coins() + _pool.size() == POOL_SIZE
	var ok := no_leak and active_coins() > 0
	print("SMOKE %s: avg_physics=%.2f ms active=%d pool_free=%d score=%d" %
		["OK" if ok else "FAIL", avg_ms, active_coins(), _pool.size(), score])
	get_tree().quit(0 if ok else 1)


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
