class_name TrashPad
extends Node3D
## Трэш-пэд (утилизатор): монета в зоне сгорает — БЕЗ банка, тело в пул.
## Порт web addTrashPad (main.js:223-230) + экономика (:464-478).

const HALF := 2.4

var game: Node3D
var cd := 0.0   # троттл попапа-счётчика
var acc := 0


func setup(p_game: Node3D, def: EntityDef) -> void:
	game = p_game
	position = def.position
	rotation.y = def.rotation_y


func _ready() -> void:
	_box(Vector3(5.0, 0.16, 5.0), Gate._std(Color("c0392b"), 0.6, 0.0, Color("4a0e08"), 0.35),
		Vector3(0, 0.08, 0))
	_box(Vector3(4.2, 0.2, 4.2), Gate._std(Color("1a1026"), 0.95, 0.0, Color.BLACK, 0.0),
		Vector3(0, 0.12, 0))
	for k in [-1.0, 0.0, 1.0]:
		_box(Vector3(3.8, 0.16, 0.34), Gate._std(Color("3c2452"), 0.8, 0.0, Color.BLACK, 0.0),
			Vector3(0, 0.2, k * 1.2))
	var lbl := Label3D.new()
	lbl.text = "X УТИЛЬ\nсжигает"
	lbl.font_size = 110
	lbl.pixel_size = 0.01
	lbl.modulate = Color("ff6a5e")
	lbl.outline_size = 18
	lbl.outline_modulate = Color(0, 0, 0, 0.5)
	lbl.position = Vector3(0, 3.0, 0)
	lbl.rotation.y = PI
	add_child(lbl)
	game.lift_zones.append({"x": position.x, "z": position.z, "hx": 2.6, "hz": 2.6})


func step(dt: float) -> void:
	cd -= dt
	var cnt := 0
	for coin in game.pool.get_children():
		if coin.get_meta("in_pool", false):
			continue  # O3: dormant-монеты (статик, но в игре) тоже поллим
		var p: Vector3 = coin.global_position
		if absf(p.x - position.x) < HALF and absf(p.z - position.z) < HALF:
			game.pool.release(coin)  # сгорание: без банка, worth сбросит пул
			cnt += 1
			if cnt <= 5:
				game.fx.emit(p.x, 0.45, p.z, {
					"color": Color("ff5040"), "life": 0.5, "size": 0.55, "size1": 1.2,
					"add": true, "vy": 1.8, "grav": 2.5,
					"vx": (game.rndv() - 0.5) * 1.2, "vz": (game.rndv() - 0.5) * 1.2,
					"fade": 0.85})
	if cnt > 0:
		game.clinks.clink(global_position, 0.5)
		acc += cnt
		if cd <= 0.0:
			game.fx.popup(Vector3(position.x, 2.2, position.z), "-%d" % acc, Color("ff6a5e"))
			game.audio.chime("trash")
			cd = 0.6
			acc = 0


func _box(size: Vector3, mat: Material, pos: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi
