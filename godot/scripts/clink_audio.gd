class_name ClinkAudio
extends Node
## Пул AudioStreamPlayer3D для звона монет: round-robin, глобальный мин-интервал.

const POOL_SIZE := 8
const MIN_INTERVAL_MS := 50

var enabled := true

var _players: Array[AudioStreamPlayer3D] = []
var _streams: Array[AudioStream] = []
var _idx := 0
var _last_ms := 0


func _ready() -> void:
	for i in 4:
		_streams.append(load("res://assets/audio/clink_%d.wav" % (i + 1)))
	for i in POOL_SIZE:
		var p := AudioStreamPlayer3D.new()
		p.max_polyphony = 1
		add_child(p)
		_players.append(p)


func clink(pos: Vector3, strength: float) -> void:
	if not enabled:
		return
	var now := Time.get_ticks_msec()
	if now - _last_ms < MIN_INTERVAL_MS:
		return
	_last_ms = now
	var p := _players[_idx]
	_idx = (_idx + 1) % POOL_SIZE
	p.stream = _streams[randi() % _streams.size()]
	p.global_position = pos
	p.pitch_scale = randf_range(0.9, 1.1)
	p.volume_db = linear_to_db(clampf(strength, 0.15, 1.0))
	p.play()
