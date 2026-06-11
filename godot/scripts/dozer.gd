class_name Dozer
extends Node3D
## Дозер: визуал-миниатюра по рефу (web main.js:46-108) + кинематические тела
## (ковш 8 коллайдеров + шасси 2, web physics.js:87-115). Узел вращается
## heading'ом и двигается game.sim_step'ом в _physics_process — AnimatableBody3D
## с sync_to_physics получают скорость и сгребают монеты импульсом.

const BLADE_FWD := 1.6
const TREAD_N := 5
const TREAD_SP := 0.46
const TREAD_SPAN := TREAD_N * TREAD_SP
const TREAD_MIN := -1.15

var blade_visual: Node3D
var blade_body: AnimatableBody3D
var chassis_body: AnimatableBody3D

var _treads: Array[MeshInstance3D] = []
var _tread_phase := 0.0
var _blade_shapes: Array[CollisionShape3D] = []

# Материалы (web main.js:48-56)
var _chassis_m := _std(CFG.DOZER_COLOR, 0.5, 0.2)
var _deck_m := _std(Color("2c2a85"), 0.5, 0.2)
var _dark := _std(Color("140d30"), 0.8, 0.0)
var _tread_m := _std(Color("0c081e"), 0.85, 0.0)
var _steel := _std(Color("c8ccd6"), 0.35, 0.6)
var _scoop_m := _std(CFG.SCOOP_COLOR, 0.5, 0.3)
var _scoop_edge := _std(Color("c9dcea"), 0.4, 0.4)
var _wood := _std(Color("7a4a2e"), 0.8, 0.0)
var _skin := _std(Color("6fae3f"), 0.7, 0.0)
var _helmet := _std(Color("f2c01d"), 0.5, 0.0)


func _ready() -> void:
	_build_visual()
	_build_bodies(blade_hx())


func blade_hx() -> float:
	# полуширина ковша; растёт апгрейдом НОЖ (web main.js:381)
	var game := get_parent()
	var bh: float = game.up_blade_half if game != null and "up_blade_half" in game else CFG.UP_BLADE_HALF
	return 1.0 * (bh / 1.6)


# --- Визуал (порт main.js:57-107, все размеры/позиции дословно) ---

func _build_visual() -> void:
	# Гусеницы: тонкие полосы по бокам + блоки протектора (прокручиваются)
	for sx in [-1.0, 1.0]:
		_box(Vector3(0.44, 0.58, 2.3), _dark, Vector3(sx * 0.7, 0.43, 0))
		_cyl(0.29, 0.46, _dark, Vector3(sx * 0.7, 0.43, 1.15), "x")
		_cyl(0.29, 0.46, _dark, Vector3(sx * 0.7, 0.43, -1.15), "x")
		_cyl(0.15, 0.5, _steel, Vector3(sx * 0.7, 0.43, 0), "x")
		for k in TREAD_N:
			_treads.append(_box(Vector3(0.5, 0.09, 0.32), _tread_m,
				Vector3(sx * 0.7, 0.75, TREAD_MIN + k * TREAD_SP)))

	# Платформа + капот + решётка
	_box(Vector3(1.3, 0.5, 1.5), _deck_m, Vector3(0, 0.82, -0.1))
	_box(Vector3(1.1, 0.36, 0.5), _deck_m, Vector3(0, 0.78, 0.75))
	_box(Vector3(0.9, 0.28, 0.06), _dark, Vector3(0, 0.74, 1.0))

	# Открытый ящик-кабина (деревянный короб)
	var by := 1.5
	var bz := -0.07
	var cw := 1.0
	var cd := 1.55
	var ch := 0.6
	var ct := 0.16
	_box(Vector3(cw, ct, cd), _wood, Vector3(0, by - ch / 2.0, bz))
	_box(Vector3(cw, ch, ct), _wood, Vector3(0, by, bz - cd / 2.0 + ct / 2.0))
	_box(Vector3(cw, ch, ct), _wood, Vector3(0, by, bz + cd / 2.0 - ct / 2.0))
	_box(Vector3(ct, ch, cd), _wood, Vector3(-cw / 2.0 + ct / 2.0, by, bz))
	_box(Vector3(ct, ch, cd), _wood, Vector3(cw / 2.0 - ct / 2.0, by, bz))

	# Гоблин-водитель: торс, голова, каска с козырьком, руки, кресло, рычаги
	_box(Vector3(0.4, 0.32, 0.34), _skin, Vector3(0, 1.74, -0.05))
	_box(Vector3(0.34, 0.24, 0.3), _skin, Vector3(0, 2.0, -0.05))
	_box(Vector3(0.42, 0.13, 0.38), _helmet, Vector3(0, 2.18, -0.05))
	_box(Vector3(0.42, 0.05, 0.17), _helmet, Vector3(0, 2.13, 0.16))
	_box(Vector3(0.1, 0.22, 0.1), _skin, Vector3(-0.23, 1.76, 0.11))
	_box(Vector3(0.1, 0.22, 0.1), _skin, Vector3(0.23, 1.76, 0.11))
	_box(Vector3(0.46, 0.1, 0.42), _dark, Vector3(0, 1.5, -0.07))
	_box(Vector3(0.46, 0.34, 0.1), _dark, Vector3(0, 1.7, -0.27))
	for s in [-1.0, 1.0]:
		var lv := _cyl(0.025, 0.26, _steel, Vector3(s * 0.18, 1.78, 0.33), "y")
		lv.rotation.x = 0.5
		_cyl(0.05, 0.05, _dark, Vector3(s * 0.18, 1.89, 0.39), "y")

	# Ковш-короб: непрерывный профиль (y,z), дно, кромка, зубья, борта
	blade_visual = Node3D.new()
	blade_visual.position = Vector3(0, 0, BLADE_FWD)
	add_child(blade_visual)

	var prof := [[0.04, 0.68], [0.30, 0.30], [0.70, 0.06], [1.05, 0.10], [1.27, 0.30]]
	for i in prof.size() - 1:
		var y0: float = prof[i][0]
		var z0: float = prof[i][1]
		var y1: float = prof[i + 1][0]
		var z1: float = prof[i + 1][1]
		var seg_len := Vector2(y1 - y0, z1 - z0).length()
		var seg := _box(Vector3(2.0, seg_len + 0.03, 0.12), _scoop_m,
			Vector3(0, (y0 + y1) / 2.0, (z0 + z1) / 2.0), blade_visual)
		seg.rotation.x = atan2(z1 - z0, y1 - y0)
	_box(Vector3(2.04, 0.09, 0.18), _scoop_edge, Vector3(0, 1.3, 0.33), blade_visual)
	_box(Vector3(2.0, 0.06, 0.84), _scoop_m, Vector3(0, 0.03, 1.05), blade_visual)
	var lip := _box(Vector3(2.04, 0.05, 0.42), _steel, Vector3(0, 0.035, 1.62), blade_visual)
	lip.rotation.x = 0.12
	for t in 6:
		var tooth := _box(Vector3(0.13, 0.06, 0.2), _steel,
			Vector3(-0.875 + 0.35 * t, 0.01, 1.84), blade_visual)
		tooth.rotation.x = 0.3
	for s in [-1.0, 1.0]:
		var sw := _box(Vector3(0.1, 1.2, 1.1), _scoop_m, Vector3(s * 1.02, 0.65, 0.35), blade_visual)
		sw.rotation.z = s * 0.05
		var se := _box(Vector3(0.12, 0.1, 1.15), _scoop_edge, Vector3(s * 1.05, 1.28, 0.35), blade_visual)
		se.rotation.z = s * 0.05
		var fc := _box(Vector3(0.1, 0.28, 0.85), _scoop_m, Vector3(s * 1.04, 0.18, 1.2), blade_visual)
		fc.rotation.x = -0.22
	# «Шпалы»: балки с внешней стороны траков к ковшу
	for s in [-1.0, 1.0]:
		_box(Vector3(0.12, 0.14, 1.7), _dark, Vector3(s * 1.0, 0.45, 0.9))


# --- Кинематические тела (порт physics.js:87-115) ---

func _build_bodies(hx: float) -> void:
	var pm := PhysicsMaterial.new()
	pm.friction = 0.8
	pm.bounce = 0.05
	blade_body = AnimatableBody3D.new()
	blade_body.name = "BladeBody"
	blade_body.sync_to_physics = true
	blade_body.physics_material_override = pm
	blade_body.position = Vector3(0, 0, BLADE_FWD)
	add_child(blade_body)
	_build_blade_shapes(hx)

	var pm2 := PhysicsMaterial.new()
	pm2.friction = 0.5
	pm2.bounce = 0.0
	chassis_body = AnimatableBody3D.new()
	chassis_body.name = "ChassisBody"
	chassis_body.sync_to_physics = true
	chassis_body.physics_material_override = pm2
	add_child(chassis_body)
	# web main.js:303: фронт-низ (стык до ковша) + короб-высокий
	_add_shape(chassis_body, Vector3(2.0, 1.0, 1.0), Vector3(0, 0.5, 0.5), 0.0)
	_add_shape(chassis_body, Vector3(1.7, 2.4, 1.8), Vector3(0, 1.2, 0), 0.0)


func _build_blade_shapes(hx: float) -> void:
	# Чаша: U-низ + U-верх (хорды профиля), дно, кромка, 2 стенки, 2 скоса
	_blade_shapes.append(_add_shape(blade_body, Vector3(hx * 2, 0.94, 0.12), Vector3(0, 0.37, 0.37), -0.755))
	_blade_shapes.append(_add_shape(blade_body, Vector3(hx * 2, 0.64, 0.12), Vector3(0, 0.985, 0.18), 0.398))
	_blade_shapes.append(_add_shape(blade_body, Vector3(hx * 2 + 0.1, 0.06, 0.84), Vector3(0, 0.03, 1.05), 0.0))
	_blade_shapes.append(_add_shape(blade_body, Vector3(hx * 2 + 0.1, 0.04, 0.40), Vector3(0, 0.012, 1.62), 0.12))
	for s in [-1.0, 1.0]:
		_blade_shapes.append(_add_shape(blade_body, Vector3(0.1, 1.2, 1.1), Vector3(s * (hx + 0.03), 0.65, 0.35), 0.0))
		_blade_shapes.append(_add_shape(blade_body, Vector3(0.1, 0.32, 0.9), Vector3(s * (hx + 0.03), 0.16, 1.2), 0.0))


func rebuild_blade(hx: float) -> void:
	# Апгрейд НОЖ: пересоздать коллайдеры (шейпы уникальны, не шарятся) + растянуть визуал
	for cs in _blade_shapes:
		cs.queue_free()
	_blade_shapes.clear()
	_build_blade_shapes(hx)
	blade_visual.scale.x = hx / 1.0


func anim_tracks(dt: float, speed_now: float) -> void:
	# Прокрутка протектора (web main.js:355-358)
	_tread_phase += speed_now * dt
	var ph := fposmod(_tread_phase, TREAD_SPAN)
	for i in _treads.size():
		var k := i % TREAD_N
		_treads[i].position.z = TREAD_MIN + fposmod(k * TREAD_SP - ph, TREAD_SPAN)


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


func _cyl(r: float, h: float, mat: Material, pos: Vector3, axis: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := CylinderMesh.new()
	mesh.top_radius = r
	mesh.bottom_radius = r
	mesh.height = h
	mesh.radial_segments = 16
	mi.mesh = mesh
	mi.position = pos
	if axis == "x":
		mi.rotation.z = PI / 2
	elif axis == "z":
		mi.rotation.x = PI / 2
	mi.material_override = mat
	add_child(mi)
	return mi


static func _std(color: Color, rough: float, metal: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = rough
	m.metallic = metal
	return m


static func _add_shape(body: PhysicsBody3D, size: Vector3, pos: Vector3, rot_x: float) -> CollisionShape3D:
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	cs.shape = box
	cs.position = pos
	cs.rotation.x = rot_x
	body.add_child(cs)
	return cs
