class_name VirtualJoystick
extends Control
## Фиксированный виртуальный джойстик в правом нижнем углу. База нарисована
## всегда; касание в его зоне активирует, драг тянет ручку (клэмп по радиусу).
## Ввод не перехватывает — позицией рулит game._unhandled_input; отсюда offset().

const RADIUS := 130.0
const KNOB_RADIUS := 52.0
const DEADZONE := 18.0     # px: меньше — стоим на месте
const MARGIN := 90.0       # отступ центра от краёв экрана
const TOUCH_SLACK := 1.7   # во сколько RADIUS вокруг базы ловим палец

var knob_off := Vector2.ZERO   # смещение ручки от базы
var active := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # кнопки/HUD ловят ввод первыми
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


## Центр джойстика — правый нижний угол (пересчитывается от размера вьюпорта).
func base_pos() -> Vector2:
	var vp := get_viewport_rect().size
	return Vector2(vp.x - RADIUS - MARGIN, vp.y - RADIUS - MARGIN)


## Палец нажал: True если попал в зону джойстика (тогда game ведёт драг).
func press(p: Vector2) -> bool:
	if p.distance_to(base_pos()) > RADIUS * TOUCH_SLACK:
		return false
	active = true
	move_knob(p)
	return true


func move_knob(p: Vector2) -> void:
	var off := p - base_pos()
	if off.length() > RADIUS:
		off = off.normalized() * RADIUS
	knob_off = off
	queue_redraw()


func release() -> void:
	active = false
	knob_off = Vector2.ZERO
	queue_redraw()


func offset() -> Vector2:
	return knob_off


func _draw() -> void:
	var c := base_pos()
	var base_a := 0.34 if active else 0.18
	draw_circle(c, RADIUS, Color(0.10, 0.08, 0.20, 0.22))
	draw_arc(c, RADIUS, 0.0, TAU, 64, Color(1, 1, 1, base_a), 5.0, true)
	draw_circle(c + knob_off, KNOB_RADIUS, Color(1, 1, 1, 0.5))
	draw_arc(c + knob_off, KNOB_RADIUS, 0.0, TAU, 40, Color(0.55, 0.85, 1.0, 0.85), 4.0, true)


func _process(_dt: float) -> void:
	queue_redraw()   # держим базу на месте при смене размера/ориентации
