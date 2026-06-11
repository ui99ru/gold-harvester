extends Node3D
## Лоток-полигон (тест-сцена физики, НЕ игра): толкатель, обрыв, смоук-тесты.
## Вся геометрия создаётся кодом; пул/звон/скриншоты — общие модули
## (coin_pool.gd, clink_audio.gd, shot_tool.gd), их же использует игра.

# --- Геометрия лотка (монета r=0.40, см. coin.gd) ---
const TRAY_TILT_DEG := 6.0   # наклон к обрыву (+z вниз)
const TRAY_W := 9.0          # внутренняя ширина
const TRAY_L := 9.0          # длина дна (короткий: волна от толкателя доходит до обрыва)
const WALL_H := 1.2
const WALL_T := 0.4
const FLOOR_T := 0.5

const TRAY_COLOR := Color("4a4466")

const PUSHER_SCENE := preload("res://scenes/pusher.tscn")
const SPAWN_HEIGHT := 3.0    # глобальная высота плоскости спавна по тапу
const KILL_Y := -6.0         # ниже — монета потеряна, возврат без счёта
const POOL_SIZE := 250

var tray: Node3D
var pool: CoinPool
var clinks: ClinkAudio
var shot: ShotTool
var camera: Camera3D
var sun: DirectionalLight3D
var score := 0

var _score_label: Label
var _smoke_mode := ""
var _smoke_ticks := 0
var _phys_time_accum := 0.0


func _ready() -> void:
	_build_environment()
	_build_tray()
	_build_pusher()
	_build_collect_zone()
	_build_camera()
	_build_score_ui()
	_build_hud()
	clinks = ClinkAudio.new()
	add_child(clinks)
	shot = ShotTool.new()
	shot.info_cb = func() -> String:
		return "score=%d active=%d pool=%d | shadows=%s ticks=%d msaa=%d" % [
			score, pool.active_count(), pool.free_count(),
			sun.shadow_enabled, Engine.physics_ticks_per_second, get_viewport().msaa_3d]
	add_child(shot)
	pool = CoinPool.new()
	pool.name = "Coins"
	add_child(pool)
	pool.setup(POOL_SIZE, _on_coin_clink)
	_parse_user_args()


# --- Построение сцены ---

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = CFG.BG_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.85, 1.0)
	env.ambient_light_energy = 0.35
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
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
	ground.material_override = _flat_material(CFG.GROUND_COLOR)
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
	var hood_z_to := -1.2
	_add_box(body, Vector3(TRAY_W, 0.55, hood_z_to - hood_z_from),
		Vector3(0, 1.05 + 0.275, (hood_z_from + hood_z_to) / 2.0), mat)
	# Передний край (z = +half_l) открыт — обрыв, зона сбора ниже


func _build_pusher() -> void:
	# В локальном (наклонном) пространстве лотка: скользит по дну у задней стенки
	# Ход фронта: z ∈ [-1.1, +2.5] — ближе к обрыву, свободная зона ~2 м:
	# куча не находит статического равновесия, излишек сваливается
	var pusher := PUSHER_SCENE.instantiate()
	pusher.position = Vector3(0, 0.5, -0.3)
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
		return Vector2i(pool.active_count(), pool.free_count())
	# Тумблеры тюнинга (бриф §7): A/B на устройстве без пересборки
	hud.toggles = [
		["Тени", true, func(on: bool) -> void:
			sun.shadow_enabled = on],
		["Тики 50", false, func(on: bool) -> void:
			Engine.physics_ticks_per_second = 50 if on else 60],
		["MSAA 2x", true, func(on: bool) -> void:
			get_viewport().msaa_3d = Viewport.MSAA_2X if on else Viewport.MSAA_DISABLED],
		["Звон", true, func(on: bool) -> void:
			clinks.enabled = on
			for coin in pool.get_children():
				coin.contact_monitor = on],
	]
	add_child(hud)


func _spawn_stress_batch() -> void:
	for i in 50:
		pool.spawn(Vector3(randf_range(-3.5, 3.5),
			2.0 + 0.3 * (i % 5), randf_range(-1.0, 4.0)))


func _on_coin_collected(body: Node3D) -> void:
	# Сигнал приходит во время flush физики — деактивация отложенно
	if body is RigidBody3D and not body.get_meta("dead", true):
		body.set_meta("dead", true)
		score += 1
		_score_label.text = str(score)
		pool.release.call_deferred(body)


func _build_camera() -> void:
	camera = Camera3D.new()
	camera.name = "Camera"
	camera.fov = 45.0
	camera.position = Vector3(0, 13.0, 12.0)
	camera.look_at_from_position(camera.position, Vector3(0, 0, 0.5), Vector3.UP)
	add_child(camera)


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
	pool.spawn(hit)


func _on_coin_clink(pos: Vector3, strength: float) -> void:
	clinks.clink(pos, strength)


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


# --- Смоук-тесты и скриншоты ---
# godot --headless --path godot res://scenes/pusher_lab.tscn ++ --smoke-stack

func _parse_user_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			shot.request(arg.trim_prefix("--shot="))
		elif arg.begins_with("--drop-demo"):
			# N монет для визуальной проверки (вместе с --shot): --drop-demo=240
			var n := 50
			if "=" in arg:
				n = int(arg.get_slice("=", 1))
			for i in n:
				pool.spawn(Vector3(randf_range(-3, 3), 1.6 + (i % 5) * 0.3,
					randf_range(-1.0, 4.0)))
			shot.delay(900 if n > 50 else 150)  # куче дать осесть; путь придёт из --shot
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
				pool.spawn(Vector3(x, 1.0 + row * 0.25, z), false)
	elif _smoke_mode == "pusher":
		# Плотный слой перед толкателем — за 30 с волна должна дойти до зоны сбора
		for i in 120:
			pool.spawn(Vector3(randf_range(-3.8, 3.8),
				1.6 + 0.3 * (i % 4), randf_range(-1.0, 4.2)))
	elif _smoke_mode == "stress":
		# Весь пул на сцену (сетка 10x5x5) — базовый замер времени физики
		for i in POOL_SIZE:
			pool.spawn(Vector3(
				-3.6 + 0.8 * (i % 10),
				2.0 + 0.4 * floorf(i / 50.0),
				-0.6 + 1.1 * (floori(i / 10.0) % 5)))
	elif _smoke_mode == "jam":
		# Сценарий «затор»: 240 монет, толкатель должен свалить излишек за 15 с
		for i in 240:
			pool.spawn(Vector3(randf_range(-3, 3), 1.6 + (i % 5) * 0.3,
				randf_range(-1.0, 4.0)))


func _physics_process(_delta: float) -> void:
	# Сметание потеряшек: ниже KILL_Y и мимо зоны сбора — возврат в пул без счёта
	if Engine.get_physics_frames() % 30 == 0 and pool != null:
		for coin in pool.get_children():
			if not coin.freeze and coin.global_position.y < KILL_Y:
				pool.release(coin)

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
	elif _smoke_mode == "jam" and _smoke_ticks >= 900:  # 15 c
		_finish_smoke_jam()


func _finish_smoke_stack() -> void:
	_smoke_mode = ""
	var total := 0
	var asleep := 0
	var fallen := 0
	for coin in pool.get_children():
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
	var ok := score > 0 and pool.active_count() + pool.free_count() == POOL_SIZE
	print("SMOKE %s: score=%d remaining=%d" %
		["OK" if ok else "FAIL", score, pool.active_count()])
	get_tree().quit(0 if ok else 1)


func _finish_smoke_jam() -> void:
	_smoke_mode = ""
	var dups := pool.duplicates()
	var books_ok := score + pool.active_count() == 240 \
		and pool.free_count() == POOL_SIZE - pool.active_count()
	var ok := dups == 0 and books_ok and score >= 40
	print("SMOKE %s: score=%d active=%d pool=%d dups=%d" %
		["OK" if ok else "FAIL", score, pool.active_count(), pool.free_count(), dups])
	get_tree().quit(0 if ok else 1)


func _finish_smoke_stress() -> void:
	_smoke_mode = ""
	var avg_ms := 1000.0 * _phys_time_accum / 600.0
	var no_leak := pool.active_count() + pool.free_count() == POOL_SIZE
	var ok := no_leak and pool.active_count() > 0
	# ~8x — измеренный прокси телефона, см. performance_hud.gd PHONE_FACTOR
	print("SMOKE %s: avg_physics=%.2f ms (≈телефон %.1f ms) active=%d pool_free=%d score=%d" %
		["OK" if ok else "FAIL", avg_ms, avg_ms * 8.0, pool.active_count(), pool.free_count(), score])
	get_tree().quit(0 if ok else 1)
