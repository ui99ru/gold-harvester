class_name ShotTool
extends Node
## Скриншот-хелпер: ждёт N кадров, сохраняет PNG, печатает SHOT-строку, выходит.
## Запрос: request("out/x.png", 20). info_cb -> String добавляется в лог.

var info_cb := Callable()

var _path := ""
var _frames_left := 0


func request(path: String, frames := 20) -> void:
	if path != "":
		_path = path
	_frames_left = maxi(_frames_left, frames)


func delay(frames: int) -> void:
	## Отодвинуть кадр снимка (сцене нужно осесть), путь не трогая
	_frames_left = maxi(_frames_left, frames)


func active() -> bool:
	return _path != ""


func _process(_delta: float) -> void:
	if _path == "":
		return
	_frames_left -= 1
	if _frames_left > 0:
		return
	var img := get_viewport().get_texture().get_image()
	var abs_path := _path
	if abs_path.is_relative_path():
		abs_path = ProjectSettings.globalize_path("res://").path_join(_path)
	DirAccess.make_dir_recursive_absolute(abs_path.get_base_dir())
	var err := img.save_png(abs_path)
	var extra: String = info_cb.call() if info_cb.is_valid() else ""
	print("SHOT %s -> %s | %s" %
		[("OK" if err == OK else "FAIL %d" % err), abs_path, extra])
	_path = ""
	get_tree().quit(0 if err == OK else 1)
