class_name Fx
extends Node3D
## Джус: пул 80 спрайтов-частиц (пыль/искры/всполохи) + текстовые попапы.
## Порт web main.js:238-248 (emit/updateParticles/emitSparks) и popup (:236).
## Случайность — из визуального потока game.rndv (не сдвигает сим).

const POOL := 80
const POPUP_LIFE := 0.82

var game: Node3D

var _parts: Array[Dictionary] = []
var _head := 0
var _pop_layer: CanvasLayer
var _popups: Array[Dictionary] = []

static var _sprite_tex: ImageTexture


func _ready() -> void:
	if _sprite_tex == null:
		_sprite_tex = _radial_sprite()
	for i in POOL:
		var mi := MeshInstance3D.new()
		var quad := QuadMesh.new()
		quad.size = Vector2.ONE
		mi.mesh = quad
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_texture = _sprite_tex
		m.no_depth_test = false
		mi.material_override = m
		mi.visible = false
		add_child(mi)
		_parts.append({"mi": mi, "life": 0.0, "max": 1.0,
			"vel": Vector3.ZERO, "grav": 0.0, "s0": 1.0, "s1": 1.0, "fade": 1.0})
	_pop_layer = CanvasLayer.new()
	add_child(_pop_layer)


## o: {color, life, size, size1, add, vy, grav, vx, vz, fade}
func emit(x: float, y: float, z: float, o: Dictionary) -> void:
	var p := _parts[_head]
	_head = (_head + 1) % POOL
	p.life = o.life
	p.max = o.life
	p.vel = Vector3(o.get("vx", 0.0), o.get("vy", 0.0), o.get("vz", 0.0))
	p.grav = o.get("grav", 0.0)
	p.s0 = o.size
	p.s1 = o.get("size1", o.size)
	p.fade = o.get("fade", 1.0)
	var mi: MeshInstance3D = p.mi
	mi.visible = true
	mi.position = Vector3(x, y, z)
	mi.scale = Vector3.ONE * p.s0
	var m: StandardMaterial3D = mi.material_override
	m.albedo_color = Color(o.color, p.fade)
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if o.get("add", false) \
		else BaseMaterial3D.BLEND_MODE_MIX


func sparks(x: float, z: float, n: int) -> void:
	# web emitSparks: оранжевые, веером вверх, гравитация 7
	for k in n:
		var a: float = game.rndv() * 6.28
		var sp: float = 2.0 + game.rndv() * 3.0
		emit(x + (game.rndv() - 0.5) * 1.5, 0.4, z + (game.rndv() - 0.5) * 1.5, {
			"color": Color("ffd86a"), "life": 0.4 + game.rndv() * 0.2,
			"size": 0.45, "size1": 0.1, "add": true,
			"vy": 2.5 + game.rndv() * 2.0, "grav": 7.0,
			"vx": cos(a) * sp, "vz": sin(a) * sp, "fade": 1.0})


func popup(world: Vector3, text: String, color: Color) -> void:
	var cam: Camera3D = game.camera
	if cam.is_position_behind(world):
		return
	var sp := cam.unproject_position(world)
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 30)
	lbl.add_theme_color_override("font_color", color)
	lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.55))
	lbl.add_theme_constant_override("outline_size", 6)
	lbl.position = sp - Vector2(40, 16)
	_pop_layer.add_child(lbl)
	_popups.append({"lbl": lbl, "t": POPUP_LIFE, "y0": lbl.position.y})


func _process(dt: float) -> void:
	for p in _parts:
		if p.life <= 0.0:
			continue
		p.life -= dt
		var mi: MeshInstance3D = p.mi
		if p.life <= 0.0:
			mi.visible = false
			continue
		p.vel.y -= p.grav * dt
		mi.position += p.vel * dt
		var t: float = p.life / p.max
		var m: StandardMaterial3D = mi.material_override
		m.albedo_color.a = t * p.fade
		mi.scale = Vector3.ONE * lerpf(p.s1, p.s0, t)

	for i in range(_popups.size() - 1, -1, -1):
		var pp := _popups[i]
		pp.t -= dt
		var lbl: Label = pp.lbl
		if pp.t <= 0.0:
			lbl.queue_free()
			_popups.remove_at(i)
			continue
		var k: float = 1.0 - pp.t / POPUP_LIFE
		lbl.position.y = pp.y0 - 36.0 * k  # всплытие как web .pop
		lbl.modulate.a = 1.0 - k * k


static func _radial_sprite() -> ImageTexture:
	# web ptTex: радиальный градиент белый -> прозрачный, 64x64
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for j in 64:
		for i in 64:
			var d := Vector2(i - 32, j - 32).length() / 32.0
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a * (3.0 - 2.0 * a)  # сглаживание как у градиента
			img.set_pixel(i, j, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)
