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
var done := false   # B5: true = лестница на MAX (зона больше не поглощает; стойка остаётся)
var kind := "knife" # B5: knife | speed | value
var tier := 0       # B5: куплено апгрейдов (до CFG.PAD_MAX_TIER)

var _fill_bar: MeshInstance3D
var _label: Label3D
var _obstacle: Dictionary
var _lift_zone: Dictionary


func setup(p_game: Node3D, def: EntityDef) -> void:
	game = p_game
	cost = def.params["cost"]
	kind = def.params.get("kind", "knife")
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
	lbl.font_size = 110
	lbl.pixel_size = 0.01
	lbl.outline_size = 18
	lbl.outline_modulate = Color(0, 0, 0, 0.5)
	lbl.position = Vector3(0, 4.0, 2.45)
	lbl.rotation.y = PI
	add_child(lbl)
	_label = lbl
	_label.text = _label_text()


func step(_dt: float) -> void:
	if done:
		return
	var cnt := 0
	for coin in game.pool.live_snapshot():  # B6: только монеты «в игре», не все size()
		var p: Vector3 = coin.global_position
		if absf(p.x - position.x) < HALF and absf(p.z - position.z) < HALF:
			var v: float = coin.worth * game.up_mult
			fill += v
			game.bank += v
			cnt += 1
			game.place_at_source(coin)
	# B3: поглотить worth монет, осевших/уснувших прямо в зоне пада (dormant-слой).
	var dd: Dictionary = game.drain_dormant_rect(position, HALF, HALF)
	if int(dd["worth"]) > 0:
		var dv: float = float(dd["worth"]) * game.up_mult
		fill += dv
		game.bank += dv
		cnt += int(dd["n"])
	if cnt > 0:
		game.on_coins_absorbed(position, cnt)
	if fill >= cost:
		# B5 лестница: применить эффект, перезарядиться ×3 до кэпа, иначе уйти в MAX.
		game.apply_pad_effect(kind)
		tier += 1
		game.shake += 0.34
		game.fx.sparks(position.x, position.z, 22)
		game.audio.chime("upgrade")
		if tier >= CFG.PAD_MAX_TIER:
			_retire()
		else:
			fill = 0.0
			cost = int(cost * CFG.PAD_COST_MULT)
			_label.text = _label_text()
			_fill_bar.scale.y = 0.001
	else:
		var r := clampf(fill / cost, 0.001, 1.0)
		_fill_bar.scale.y = r
		_fill_bar.position.y = BOT + GH * r * 0.5


## B5: пад достиг MAX-тира — перестаёт поглощать (done), лейбл MAX, но стойка/препятствие
## остаётся в мире (визуальный «памятник» прокачке, web addPad не убирал столб).
func _retire() -> void:
	done = true
	_label.text = "%s\nMAX" % _kind_name()
	_fill_bar.scale.y = 1.0
	_fill_bar.position.y = BOT + GH * 0.5


func _kind_name() -> String:
	match kind:
		"speed": return "СКОРОСТЬ"
		"value": return "ЦЕННОСТЬ"
		_: return "НОЖ"


func _label_text() -> String:
	return "UPGRADE\n%s %s" % [_kind_name(), Game.fmt(cost)]


func _box(size: Vector3, mat: Material, pos: Vector3, parent: Node3D = null) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	(parent if parent else self).add_child(mi)
	return mi
