class_name Gate
extends Node3D
## Ворота: запертые поглощают монеты в мате (fill+bank) и открываются;
## открытые множат пересечение волной (этап 6). Порт web main.js:174-199, 405-450.
## Сущность уровня: строится из EntityDef {mult, cost}.

const PW := 4.6        # полу-разнос столбов
const HALF_W := 2.8    # полуширина створа (волна)
const GH := 2.4        # высота бара
const BOT := 0.3

var game: Node3D
var mult := 10
var cost := 10
var active := false
var fill := 0.0
var normal := Vector3(0, 0, 1)   # (sin rot, 0, cos rot)
var right := Vector3(1, 0, 0)    # (cos rot, 0, -sin rot)
var side := PackedInt32Array()   # эдж-триггер: -1/0/+1 на монету

var _red: Node3D
var _white: Node3D
var _fill_bar: MeshInstance3D
var _mat_node: Node3D
var _lift_zone: Dictionary


func setup(p_game: Node3D, def: EntityDef) -> void:
	game = p_game
	mult = def.params["mult"]
	cost = def.params["cost"]
	position = def.position
	rotation.y = def.rotation_y
	normal = Vector3(sin(def.rotation_y), 0, cos(def.rotation_y))
	right = Vector3(cos(def.rotation_y), 0, -sin(def.rotation_y))
	side.resize(CFG.COIN_N)
	side.fill(0)
	game.side_resetters.append(func(idx: int) -> void: side[idx] = 0)


func _ready() -> void:
	var body_m := _std(Color("4a47c0"), 0.4, 0.2, Color("191455"), 0.5)
	var copper_m := _std(Color("b5642a"), 0.6, 0.3, Color.BLACK, 0.0)
	var gem_m := _std(Color("6fe0ff"), 0.2, 0.3, Color("2aa0d0"), 0.7)

	for sx: float in [-1.0, 1.0]:
		_box(Vector3(1.1, 8.4, 1.1), body_m, Vector3(sx * PW, 4.2, 0))
		_box(Vector3(1.3, 0.8, 1.3), copper_m, Vector3(sx * PW, 2.3, 0))
		# Самоцвет-октаэдр: сфера с 4 сегментами = двойная пирамида
		var gem := MeshInstance3D.new()
		var sph := SphereMesh.new()
		sph.radius = 0.85
		sph.height = 1.7
		sph.radial_segments = 4
		sph.rings = 2
		gem.mesh = sph
		gem.material_override = gem_m
		gem.position = Vector3(sx * PW, 8.9, 0)
		add_child(gem)
		# Столб — твёрдое препятствие (блокирует и нож)
		var ox := position.x + sx * PW * cos(rotation.y)
		var oz := position.z - sx * PW * sin(rotation.y)
		game.obstacles.append({"x0": ox - 0.75, "x1": ox + 0.75,
			"z0": oz - 0.75, "z1": oz + 0.75, "post": true})

	_red = _curtain(true)
	_white = _curtain(false)
	_white.visible = false

	# Пад-мат перед воротами (копит монеты, исчезает при открытии)
	_mat_node = Node3D.new()
	_mat_node.position.z = -1.6
	add_child(_mat_node)
	_box(Vector3(10.8, 0.16, 3.4), _std(Color("f2c63a"), 0.6, 0.0, Color("4a3a00"), 0.2),
		Vector3(0, 0.08, 0), _mat_node)
	_box(Vector3(10.2, 0.2, 2.9), _std(Color("3a2f63"), 0.85, 0.0, Color.BLACK, 0.0),
		Vector3(0, 0.12, 0), _mat_node)
	_lift_zone = {"x": position.x - 1.6 * normal.x, "z": position.z - 1.6 * normal.z,
		"hx": 5.5, "hz": 1.8}
	game.lift_zones.append(_lift_zone)

	# Бар прогресса разблокировки
	var frame_m := _std(Color("123040"), 0.4, 0.0, Color.BLACK, 0.0)
	frame_m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	frame_m.albedo_color.a = 0.3
	_box(Vector3(7.2, GH, 0.4), frame_m, Vector3(0, BOT + GH / 2.0, 0.7))
	_fill_bar = _box(Vector3(6.9, GH, 0.46), _glow_material(Color("35d8e6"), 0.85),
		Vector3(0, BOT, 0.7))
	_fill_bar.scale.y = 0.001

	# Баннер цены
	var banner := _box(Vector3(4.6, 2.3, 0.05), _std(Color("5a3fb4"), 0.6, 0.0, Color.BLACK, 0.0),
		Vector3(0, 10.4, 0))
	var cost_lbl := _label(str(cost), 220, Color.WHITE)
	cost_lbl.position = Vector3(0, 10.4, -0.1)
	add_child(cost_lbl)


func _curtain(locked: bool) -> Node3D:
	var root := Node3D.new()
	root.position = Vector3(0, 4.4, 0)
	add_child(root)
	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(7.6, 7.0)
	mi.mesh = quad
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	if locked:
		m.albedo_texture = TexGen.gate_chevron()
		m.albedo_color = Color(1, 1, 1, 0.97)
	else:
		m.albedo_color = Color(CFG.GATE_CURTAIN, 0.35)
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mi.material_override = m
	root.add_child(mi)
	var lbl := _label("x" + str(mult), 320,
		Color.WHITE if locked else Color("f2ffff"))
	lbl.position = Vector3(0, 0.2, -0.06)
	if not locked:
		lbl.modulate = Color("ccf6ff")
	root.add_child(lbl)
	return root


func step(_dt: float) -> void:
	if active:
		_step_active()
		return
	var cnt := 0
	for coin in game.pool.get_children():
		if coin.freeze:
			continue
		var p: Vector3 = coin.global_position
		var gx: float = p.x - position.x
		var gz: float = p.z - position.z
		var along: float = gx * normal.x + gz * normal.z
		var lat: float = gx * right.x + gz * right.z
		# Зона = мат: выдвинут перед воротами, шире столбов (web :445)
		if absf(along + 1.6) < 1.7 and absf(lat) < 5.2:
			var v: float = coin.worth * game.up_mult
			fill += v
			game.bank += v
			cnt += 1
			game.place_at_source(coin)
	if cnt > 0:
		game.on_coins_absorbed(position, cnt)
	if fill >= cost:
		_unlock()
	else:
		_set_bar()


## Открытые ворота: множат ПЕРЕСЕЧЕНИЕ плоскости волной копий (web :408-438).
## Эдж-триггер с гистерезисом ±0.6: монета в створе сторону не меняет —
## самопроизвольного размножения нет. Сумма ценности точно x mult.
func _step_active() -> void:
	var crossed := 0
	for coin in game.pool.get_children():
		if coin.freeze:
			continue
		var p: Vector3 = coin.global_position
		var gx: float = p.x - position.x
		var gz: float = p.z - position.z
		var along: float = gx * normal.x + gz * normal.z
		var lat: float = gx * right.x + gz * right.z
		if absf(lat) >= HALF_W:
			continue
		var was := side[coin.idx]
		var now_s := -1 if along < -0.6 else (1 if along > 0.6 else 0)
		if now_s == 0 or now_s == was:
			continue
		side[coin.idx] = now_s
		# Только ВПЕРЁД (со стороны мата); первое наблюдение/назад — регистрация
		if was != -1 or now_s != 1 or coin.worth >= 300:
			continue
		var v: Vector3 = coin.linear_velocity
		if v.x * normal.x + v.z * normal.z < CFG.GATE_MIN_V:
			continue  # просачивание под давлением кучи (медленно) не множит
		var w: int = coin.worth
		var k: int = mini(mult - 1, mini(CFG.GATE_BURST, game.pool.free_count()))
		coin.worth = w * (mult - k)
		for c in k:
			var fz: float = 0.9 + game.rnd() * 0.9
			var sl: float = clampf(lat + (game.rnd() - 0.5) * 2.5,
				-CFG.LANE_HALF + 0.6, CFG.LANE_HALF - 0.6)
			var vf: float = now_s * (CFG.BURST_FWD + game.rnd() * 2.5)
			var vl: float = (game.rnd() - 0.5) * 3.0
			var copy: RigidBody3D = game.pool.spawn(Vector3(
				position.x + normal.x * now_s * fz + right.x * sl,
				0.5 + game.rnd() * 0.7,
				position.z + normal.z * now_s * fz + right.z * sl), false)
			if copy == null:
				break
			copy.worth = w
			for cb in game.side_resetters:
				cb.call(copy.idx)  # копия: чистая регистрация, без срабатывания
			copy.linear_velocity = Vector3(
				normal.x * vf + right.x * vl,
				CFG.BURST_UP + game.rnd() * 2.0,
				normal.z * vf + right.z * vl)
			copy.angular_velocity = Vector3(
				(game.rnd() - 0.5) * 14.0, 0, (game.rnd() - 0.5) * 14.0)
		crossed += 1
	if crossed > 0:
		game.on_gate_wave(self, crossed)  # ОДИН джус-залп на кадр, не 25 попапов


func _unlock() -> void:
	active = true
	_red.visible = false
	_white.visible = true
	_fill_bar.visible = false
	_mat_node.visible = false
	game.lift_zones.erase(_lift_zone)
	game.on_gate_unlocked(self)


func _set_bar() -> void:
	var r := clampf(fill / cost, 0.001, 1.0)
	_fill_bar.scale.y = r
	_fill_bar.position.y = BOT + GH * r * 0.5


# --- Утилиты ---

func _box(size: Vector3, mat: Material, pos: Vector3, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	(parent if parent else self).add_child(mi)
	return mi


func _label(text: String, px: int, color: Color) -> Label3D:
	var lbl := Label3D.new()
	lbl.text = text
	lbl.font_size = px
	lbl.pixel_size = 0.01
	lbl.modulate = color
	lbl.outline_size = 24
	lbl.outline_modulate = Color(0.1, 0.05, 0.05, 0.8)
	lbl.no_depth_test = false
	lbl.rotation.y = PI  # лицом к подъезду (-z), как web rotation.y = PI
	return lbl


static func _std(color: Color, rough: float, metal: float,
		emis: Color, emis_int: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	if emis_int > 0.0:
		m.emission_enabled = true
		m.emission = emis
		m.emission_energy_multiplier = emis_int
	return m


static func _glow_material(color: Color, opacity: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.albedo_color = Color(color, opacity)
	return m
