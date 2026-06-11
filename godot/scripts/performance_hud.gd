extends CanvasLayer
## Performance HUD (бриф §5): FPS, frame time, physics time, активные тела,
## состояние пула, кнопка стресс-теста «+50 монет».

var spawn_50_cb := Callable()
var pool_stats_cb := Callable()  # -> Vector2i(active, free)
var toggles: Array = []          # [[название, старт, Callable(bool)], ...]

var _label: Label
var _frame_accum := 0.0
var _phys_accum := 0.0
var _frames := 0


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(24, 72)
	_label.add_theme_font_size_override("font_size", 16)
	_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.92))
	add_child(_label)

	var box := VBoxContainer.new()
	box.position = Vector2(24, 210)
	add_child(box)
	for t in toggles:
		var cb := CheckButton.new()
		cb.text = t[0]
		cb.button_pressed = t[1]
		cb.add_theme_font_size_override("font_size", 18)
		cb.toggled.connect(t[2])
		box.add_child(cb)

	var btn := Button.new()
	btn.text = "+50 монет"
	btn.add_theme_font_size_override("font_size", 22)
	btn.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	btn.offset_left = 24
	btn.offset_bottom = -24
	btn.offset_top = -84
	btn.offset_right = 220
	btn.pressed.connect(func() -> void:
		if spawn_50_cb.is_valid():
			spawn_50_cb.call())
	add_child(btn)


func _process(delta: float) -> void:
	_frame_accum += delta
	_phys_accum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)
	_frames += 1
	if _frame_accum < 0.5:
		return
	var pool := Vector2i.ZERO
	if pool_stats_cb.is_valid():
		pool = pool_stats_cb.call()
	_label.text = "FPS %d  |  frame %.2f ms\nphysics %.2f ms\nactive bodies %d\ncoins %d / pool %d" % [
		Engine.get_frames_per_second(),
		1000.0 * _frame_accum / _frames,
		1000.0 * _phys_accum / _frames,
		Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		pool.x, pool.y,
	]
	_frame_accum = 0.0
	_phys_accum = 0.0
	_frames = 0
