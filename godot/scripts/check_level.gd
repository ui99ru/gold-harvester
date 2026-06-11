extends SceneTree
## Headless-проверка формата уровня:
## godot --headless --path godot --script scripts/check_level.gd

func _initialize() -> void:
	var lvl: LevelDef = load("res://levels/level_01.tres")
	if lvl == null:
		print("LEVEL FAIL: не загрузился")
		quit(1)
		return
	var types := {}
	for e in lvl.entities:
		types[e.type] = types.get(e.type, 0) + 1
	var ok: bool = lvl.entities.size() == 15 \
		and types.get("wall", 0) == 11 and types.get("gate", 0) == 2 \
		and types.get("pad_knife", 0) == 1 and types.get("trash", 0) == 1 \
		and lvl.start_coins == 5 and lvl.source_pos == Vector3(0, 0, 9)
	print("LEVEL %s: entities=%d types=%s src=%s start=%d" %
		["OK" if ok else "FAIL", lvl.entities.size(), types, lvl.source_pos, lvl.start_coins])
	quit(0 if ok else 1)
