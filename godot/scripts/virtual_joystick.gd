class_name VirtualJoystick
extends Control
## Виртуальный джойстик мобильного управления: база появляется в точке касания,
## ручка тянется за пальцем (клэмп по радиусу). Сам ввод не перехватывает —
## позицией рулит game._unhandled_input, отсюда только отрисовка + offset.

const RADIUS := 130.0
const KNOB_RADIUS := 52.0
const DEADZONE := 18.0   # px: меньше — стоим на месте

var base_pos := Vector2.ZERO
var knob_pos := Vector2.ZERO
var active := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE  # кнопки/HUD ловят ввод первыми
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func show_at(p: Vector2) -> void:
	base_pos = p
	knob_pos = p
	active = true
	queue_redraw()


func move_knob(p: Vector2) -> void:
	var off := p - base_pos
	if off.length() > RADIUS:
		off = off.normalized() * RADIUS
	knob_pos = base_pos + off
	queue_redraw()


func hide_joy() -> void:
	active = false
	queue_redraw()


## Смещение ручки от базы (px). Длина < DEADZONE → считать «нет ввода».
func offset() -> Vector2:
	return knob_pos - base_pos


func _draw() -> void:
	if not active:
		return
	draw_circle(base_pos, RADIUS, Color(0.10, 0.08, 0.20, 0.28))
	draw_arc(base_pos, RADIUS, 0.0, TAU, 64, Color(1, 1, 1, 0.32), 5.0, true)
	draw_circle(knob_pos, KNOB_RADIUS, Color(1, 1, 1, 0.55))
	draw_arc(knob_pos, KNOB_RADIUS, 0.0, TAU, 40, Color(0.55, 0.85, 1.0, 0.8), 4.0, true)
