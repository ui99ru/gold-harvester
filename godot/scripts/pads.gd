class_name UpgradePad
extends Node3D
## Апгрейд-пад «НОЖ»: ссып монет -> fill+bank -> апгрейд ковша -> пад исчезает.
## Порт web addPad (main.js:203-219) + экономика (:452-462).

const HALF := 2.4
const GH := 3.0
const BOT := 0.25

var game: Node3D
var cost := 120
var fill := 0.0
var done := false

var _fill_bar: MeshInstance3D
var _obstacle: Dictionary
var _lift_zone: Dictionary


func setup(p_game: Node3D, def: EntityDef) -> void:
	game = p_game
	cost = def.params["cost"]
	position = def.position
	rotation.y = def.rotation_y


func _ready() -> void:
	_box(Vector3(5.0, 0.16, 5.0), Gate._std(Color("f2c63a"), 0.6, 0.0, Color("4a3a00"), 0.2),
		Vector3(0, 0.08, 0))
	_box(Vector3(4.2, 0.2, 4.2), Gate._std(Color("3a2f63"), 0.85, 0.0, Color.BLACK, 0.0),
		Vector3(0, 0.12, 0))
	# Задняя стойка — твёрдое препятствие
	_box(Vector3(4.8, 3.4, 1.1), Gate._std(Color("6a4cc0"), 0.5, 0.0, Color("1e1050"), 0.4),
		Vector3(0, 1.7, 3.0))
	var ps := sin(rotation.y)
	var pc := cos(rotation.y)
	var px := position.x + 3.0 * ps
	var pz := position.z + 3.0 * pc
	var ohx := absf(2.4 * pc) + absf(0.6 * ps)
	var ohz := absf(2.4 * ps) + absf(0.6 * pc)
	_obstacle = {"x0": px - ohx, "x1": px + ohx, "z0": pz - ohz, "z1": pz + ohz, "post": false}
	game.obstacles.append(_obstacle)
	_lift_zone = {"x": position.x, "z": position.z, "hx": 2.6, "hz": 2.6}
	game.lift_zones.append(_lift_zone)

	# Бар прогресса
	var frame_m := Gate._std(Color("123040"), 0.4, 0.0, Color.BLACK, 0.0)
	frame_m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	frame_m.albedo_color.a = 0.32
	_box(Vector3(3.6, GH, 0.5), frame_m, Vector3(0, BOT + GH / 2.0, 2.25))
	_fill_bar = _box(Vector3(3.3, GH, 0.55), Gate._glow_material(Color("35d8e6"), 0.82),
		Vector3(0, BOT, 2.3))
	_fill_bar.scale.y = 0.001

	# Призрак награды (расширенный ковш)
	var gm := Gate._std(Color.WHITE, 0.6, 0.0, Color("444444"), 1.0)
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.albedo_color.a = 0.5
	var ghost := Node3D.new()
	ghost.position = Vector3(0, 1.3, 2.15)
	add_child(ghost)
	_box(Vector3(1.4, 0.8, 1.9), gm, Vector3.ZERO, ghost)
	_box(Vector3(1.0, 0.7, 0.9), gm, Vector3(0, 0.6, -0.35), ghost)
	_box(Vector3(1.9, 0.55, 0.3), gm, Vector3(0, -0.12, 1.05), ghost)

	var lbl := Label3D.new()
	lbl.text = "UPGRADE\nНОЖ %s" % Game.fmt(cost)
	lbl.font_size = 110
	lbl.pixel_size = 0.01
	lbl.outline_size = 18
	lbl.outline_modulate = Color(0, 0, 0, 0.5)
	lbl.position = Vector3(0, 4.0, 2.45)
	lbl.rotation.y = PI
	add_child(lbl)


func step(_dt: float) -> void:
	if done:
		return
	var cnt := 0
	for coin in game.pool.get_children():
		if coin.get_meta("in_pool", false):
			continue  # O3: dormant-монеты (статик, но в игре) тоже поллим
		var p: Vector3 = coin.global_position
		if absf(p.x - position.x) < HALF and absf(p.z - position.z) < HALF:
			var v: float = coin.worth * game.up_mult
			fill += v
			game.bank += v
			cnt += 1
			game.place_at_source(coin)
	if cnt > 0:
		game.on_coins_absorbed(position, cnt)
	if fill >= cost:
		done = true
		game.obstacles.erase(_obstacle)
		game.lift_zones.erase(_lift_zone)
		game.on_pad_upgraded(self)
		queue_free()
	else:
		var r := clampf(fill / cost, 0.001, 1.0)
		_fill_bar.scale.y = r
		_fill_bar.position.y = BOT + GH * r * 0.5


func _box(size: Vector3, mat: Material, pos: Vector3, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	(parent if parent else self).add_child(mi)
	return mi
