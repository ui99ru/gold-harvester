class_name GameAudio
extends Node
## Двигатель-луп + джинглы + mute. Порт src/audio.js: синтез запечён в wav
## (tools/make_godot_enginefx.py, make_godot_jingles.py), рантайм крутит
## pitch/volume от скорости. Шины web: master 0.5, engine 0.85.

var muted := false

var _engine: AudioStreamPlayer
var _chimes := {}
var _chime_players: Array[AudioStreamPlayer] = []


func _ready() -> void:
	var stream: AudioStreamWAV = load("res://assets/audio/engine_loop.wav")
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = stream.data.size() / 2  # 16-бит моно: байты -> сэмплы
	_engine = AudioStreamPlayer.new()
	_engine.stream = stream
	_engine.volume_db = -80.0
	add_child(_engine)
	_engine.play()
	for kind in ["gate", "upgrade", "trash"]:
		_chimes[kind] = load("res://assets/audio/chime_%s.wav" % kind)
	for i in 3:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_chime_players.append(p)


## web pumpEngine (audio.js:41-49): громкость 0.55+0.45sp, питч 0.9+0.5sp
func pump_engine(sp: float, playing: bool) -> void:
	if muted or not playing:
		_engine.volume_db = -80.0
		return
	_engine.volume_db = linear_to_db(0.5 * 0.85 * (0.55 + sp * 0.45))
	_engine.pitch_scale = 0.9 + sp * 0.5


## web chime (audio.js:74-79): gate / upgrade / trash
func chime(kind: String) -> void:
	if muted:
		return
	for p in _chime_players:
		if not p.playing:
			p.stream = _chimes[kind]
			p.volume_db = linear_to_db(0.5)
			p.play()
			return


func toggle_mute() -> bool:
	muted = not muted
	AudioServer.set_bus_mute(0, muted)  # глушит и клинки — как web master
	return muted
