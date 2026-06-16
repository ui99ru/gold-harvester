class_name CoinDormant
extends MultiMeshInstance3D
## Декор-слой «спящих» монет БЕЗ физ-тел: запись {Transform3D, worth} + инстанс
## MultiMesh + grid-индекс (ячейка 2 м) для быстрых выборок кругом. Тысячи записей
## стоят ≈0 CPU (нет узлов/тел/коллизий) — отсюда «изобилие». Гидрация берёт
## запись и поднимает тело из пула; дегидрация кладёт сюда спящее тело.
## Меш/материал — общие статики Coin (батчинг, 1 draw-call). Плотная упаковка:
## remove(i) переносит последний элемент в дырку i (swap-remove) и чинит grid+mm.
##
## ВАЖНО для вызывающего: remove() меняет индексацию (swap-remove). Пакетное
## удаление — собрать индексы, отсортировать ПО УБЫВАНИЮ и удалять с конца, либо
## прочитать все нужные записи ДО первого remove().

const CELL := 2.0

var _mm: MultiMesh
var _xforms: Array[Transform3D] = []
var _worth := PackedInt64Array()   # после ×1000 (этап B5) номиналы выходят за int32
var _count := 0
var _max := 0
var _grid: Dictionary = {}         # Vector2i -> PackedInt32Array(индексы записей)


## mesh/mat — ресурсы рендера слоя. B6: передаём дешёвый LOD-меш/материал (Coin._mesh_lod
## / Coin._material_lod); при null фолбэк на полные Coin._mesh/_material (старое поведение).
func setup(max_n: int, world_aabb: AABB, mesh: Mesh = null, mat: Material = null) -> void:
	Coin._ensure_shared()
	_max = max_n
	_xforms.resize(max_n)
	_worth.resize(max_n)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.mesh = mesh if mesh != null else Coin._mesh
	_mm.instance_count = max_n              # выделяем буфер ОДИН раз
	_mm.visible_instance_count = 0
	multimesh = _mm
	material_override = mat if mat != null else Coin._material
	# custom_aabb на весь уровень: иначе движок пересчитывает AABB на каждое
	# изменение видимого числа (O(N) по инстансам) — спайк на больших полях.
	custom_aabb = world_aabb
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func count() -> int:
	return _count


func get_xform(i: int) -> Transform3D:
	return _xforms[i]


func get_worth(i: int) -> int:
	return _worth[i]


func total_worth() -> int:
	var s := 0
	for i in _count:
		s += _worth[i]
	return s


## Добавить запись (дегидрация). Возврат индекс, или -1 при переполнении слоя.
## ПЕРЕПОЛНЕНИЕ НЕ ТЕРЯЕТ worth: сливаем в запись той же ячейки, иначе — в любую
## существующую (_worth[0]). Гарантия сохранения ценности (важно с этапа B3,
## когда экономика читает dormant напрямую).
func add(xform: Transform3D, w: int) -> int:
	if _count >= _max:
		var cell := _cell(xform.origin)
		if _grid.has(cell):
			var arr: PackedInt32Array = _grid[cell]
			if arr.size() > 0:
				_worth[arr[0]] += w
				return -1
		if _count > 0:
			_worth[0] += w  # фолбэк: ячейка пуста → не теряем worth (см. докстринг)
		return -1
	var i := _count
	_xforms[i] = xform
	_worth[i] = w
	_mm.set_instance_transform(i, xform)
	_grid_add(_cell(xform.origin), i)
	_count += 1
	_mm.visible_instance_count = _count
	return i


## Удалить запись i (гидрация). Swap-remove: последний элемент → в слот i.
func remove(i: int) -> void:
	if i < 0 or i >= _count:
		return
	var last := _count - 1
	_grid_remove(_cell(_xforms[i].origin), i)
	if i != last:
		_grid_remove(_cell(_xforms[last].origin), last)
		_xforms[i] = _xforms[last]
		_worth[i] = _worth[last]
		_mm.set_instance_transform(i, _xforms[i])
		_grid_add(_cell(_xforms[i].origin), i)   # перенесённый: тот же мир-cell, новый индекс
	_count -= 1
	_mm.visible_instance_count = _count


## Индексы записей в круге (center, r) на плоскости XZ. Сканирует перекрытые ячейки.
func query_circle(center: Vector3, r: float) -> PackedInt32Array:
	var out := PackedInt32Array()
	var r2 := r * r
	var c0 := _cell(center - Vector3(r, 0, r))
	var c1 := _cell(center + Vector3(r, 0, r))
	for cx in range(c0.x, c1.x + 1):
		for cz in range(c0.y, c1.y + 1):
			var key := Vector2i(cx, cz)
			if not _grid.has(key):
				continue
			for i in _grid[key]:
				var p: Vector3 = _xforms[i].origin
				var dx := p.x - center.x
				var dz := p.z - center.z
				if dx * dx + dz * dz <= r2:
					out.append(i)
	return out


func _cell(p: Vector3) -> Vector2i:
	return Vector2i(floori(p.x / CELL), floori(p.z / CELL))


func _grid_add(cell: Vector2i, i: int) -> void:
	if _grid.has(cell):
		var arr: PackedInt32Array = _grid[cell]
		arr.append(i)
		_grid[cell] = arr          # PackedArray — value-type (CoW): вернуть обратно
	else:
		_grid[cell] = PackedInt32Array([i])


func _grid_remove(cell: Vector2i, i: int) -> void:
	if not _grid.has(cell):
		return
	var arr: PackedInt32Array = _grid[cell]
	var pos := arr.find(i)
	if pos >= 0:
		arr.remove_at(pos)
		if arr.is_empty():
			_grid.erase(cell)
		else:
			_grid[cell] = arr
