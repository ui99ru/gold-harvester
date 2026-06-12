class_name CoinPool
extends Node3D
## Пул монет: предсоздать N, неактивные заморожены/невидимы/без коллизий.
## Сам узел — родитель всех монет (бывший coins_root).
## Возврат идемпотентен (meta in_pool) — двойной release не дублирует пул.

const COIN_SCENE := preload("res://scenes/coin.tscn")

var size := 0

var _free: Array[RigidBody3D] = []


func setup(n: int, clink_cb: Callable) -> void:
	size = n
	for i in n:
		var coin: RigidBody3D = COIN_SCENE.instantiate()
		coin.idx = i
		coin.clink_cb = clink_cb
		add_child(coin)
		_park(coin)
		_free.append(coin)


func spawn(pos: Vector3, random_tilt := true) -> RigidBody3D:
	if _free.is_empty():
		return null
	var coin: RigidBody3D = _free.pop_back()
	coin.set_meta("in_pool", false)
	coin.set_meta("dead", false)
	coin.worth = 1
	coin.transform = Transform3D(Basis(), pos)
	if random_tilt:
		coin.rotation = Vector3(
			randf_range(-0.3, 0.3), randf_range(0, TAU), randf_range(-0.3, 0.3))
	coin.collision_layer = 1
	coin.collision_mask = 1
	coin.visible = true
	coin.freeze = false
	coin.linear_velocity = Vector3.ZERO
	coin.angular_velocity = Vector3.ZERO
	coin.dormant = false     # O3: свежая монета — активная (dynamic)
	coin.gripped = false     # O3b: не в ковше
	coin.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	coin._refresh_monitor()  # O5: свежеспавненная монета активна → монитор контактов on
	return coin


func release(coin: RigidBody3D) -> void:
	if coin.get_meta("in_pool", false):
		return
	coin.set_meta("dead", true)
	_park(coin)
	_free.append(coin)


func active_count() -> int:
	return size - _free.size()


func free_count() -> int:
	return _free.size()


func duplicates() -> int:
	var seen := {}
	for c in _free:
		seen[c] = true
	return _free.size() - seen.size()


func _park(coin: RigidBody3D) -> void:
	coin.set_meta("in_pool", true)
	coin.set_meta("dead", true)
	coin.worth = 1
	coin.freeze = true
	coin.visible = false
	# Слои обязательно в 0: замороженное тело — статик и иначе коллайдит
	coin.gripped = false     # O3b: не в ковше
	coin.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC  # park = статик-фриз (не kinematic)
	coin.collision_layer = 0
	coin.collision_mask = 0
	coin.dormant = false     # O3: запаркованная пулом — не dormant-состояние
	coin.position = Vector3(0, -100, 0)
	coin._refresh_monitor()  # O5: замороженная монета — без монитора контактов
