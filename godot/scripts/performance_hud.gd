extends CanvasLayer
## Performance HUD (бриф §5): FPS, frame time, physics time, активные тела,
## состояние пула, кнопка стресс-теста «+50 монет».

var spawn_50_cb := Callable()
var pool_stats_cb := Callable()  # -> Vector2i(active, free)
var gd_time_cb := Callable()     # -> float: мс GDScript-сима за последний физ-тик (O1)
var toggles: Array = []          # [[название, старт, Callable(bool)], ...]

# Прокси слабого железа: замерено на одной сцене (~240 монет):
# десктоп 1.58 мс физики vs телефон 13.3 мс -> ~8x. Грубо (+-2x), но
# как ограждение работает: десктоп-физика x8 < бюджета кадра = на
# телефоне влезаем. Рендер прокси НЕ покрывает - чекпойнт APK на
# устройстве после каждой крупной механики.
const PHONE_FACTOR := 8.0
const FRAME_BUDGET_MS := 16.7

var _label: Label
var _frame_accum := 0.0
var _phys_accum := 0.0
var _gd_accum := 0.0
var _frames := 0


func _ready() -> void:
	_label = Label.new()
	_label.position = Vector2(24, 72)
	# Крупнее + тёмная обводка — читается на телефоне поверх светлого грунта
	_label.add_theme_font_size_override("font_size", 32)
	_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_label.add_theme_constant_override("outline_size", 10)
	add_child(_label)

	var box := VBoxContainer.new()
	box.position = Vector2(24, 360)
	add_child(box)
	for t in toggles:
		var cb := CheckButton.new()
		cb.text = t[0]
		cb.button_pressed = t[1]
		cb.add_theme_font_size_override("font_size", 24)
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
	if gd_time_cb.is_valid():
		_gd_accum += gd_time_cb.call()  # уже в мс
	_frames += 1
	if _frame_accum < 0.5:
		return
	var pool := Vector2i.ZERO
	if pool_stats_cb.is_valid():
		pool = pool_stats_cb.call()
	var phys_ms := 1000.0 * _phys_accum / _frames
	var gd_ms := _gd_accum / _frames                  # GDScript-сим (экономика/пузырь/дозер)
	var jolt_ms := maxf(0.0, phys_ms - gd_ms)         # остаток = шаг физ-сервера Jolt
	var phone_ms := phys_ms * PHONE_FACTOR
	_label.text = "FPS %d  |  frame %.2f ms\nphysics %.2f ms (jolt %.2f / gd %.2f)\n≈телефон %.1f / %.1f ms\nactive bodies %d\ncoins %d / pool %d" % [
		Engine.get_frames_per_second(),
		1000.0 * _frame_accum / _frames,
		phys_ms, jolt_ms, gd_ms, phone_ms, FRAME_BUDGET_MS,
		Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS),
		pool.x, pool.y,
	]
	_label.add_theme_color_override("font_color",
		Color(1, 0.45, 0.4) if phone_ms > FRAME_BUDGET_MS else Color(1, 1, 1, 0.92))
	_frame_accum = 0.0
	_phys_accum = 0.0
	_gd_accum = 0.0
	_frames = 0
