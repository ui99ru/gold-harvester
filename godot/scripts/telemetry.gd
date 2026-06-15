extends Node
## Авто-телеметрия прогона (--probe): пер-тик ПИК физики + пер-окно сэмплы →
## строки @TLM в stdout/logcat (liveness) + авторитетный JSON в user://telemetry/.
## Армится только game.gd при --probe (begin); обычная игра и смоуки не затронуты
## (_active=false → ранний выход, нет печати @TLM, гейт CI не задет).
##
## Образцы: lifecycle/запись файла/quit — shot_tool.gd; формулы метрик и порог
## бюджета — performance_hud.gd. Пер-тик путь O(1) (только Performance-мониторы +
## O(1) колбэк gd_ms); O(N)-сигналы (dormant) берём ТОЛЬКО на границе окна (sample_cb).

const WINDOW_S := 0.5
const BUDGET_MS := 16.7
const PHONE_FACTOR := 8.0   # десктоп-физика ×8 ≈ телефон (только CPU; см. HUD)

# Инъекция провайдеров (как gd_time_cb/pool_stats_cb у HUD) — телеметрия не лезет в Game.
var sample_cb := Callable()  # -> Dictionary {active, free, dormant, vis_gold, cap}; зовётся НА ГРАНИЦЕ окна
var tick_cb := Callable()    # -> float: gd_ms за тик (O(1)); зовётся пер-тик

var _active := false
var _scenario := ""
var _seed := 0
var _duration_s := 0.0   # длительность прогона в РЕАЛЬНЫХ секундах (не тиках — на
                         # медленном телефоне тик-счёт раздувает wall-time, тайм-аут хоста)
var _tick := 0
var _t0_unix := 0.0

# Прогон-длинные массивы для честных p50/p95/p99/max (окна слепы к пику одного тика)
var _phys_ms_all := PackedFloat32Array()
var _frame_ms_all := PackedFloat32Array()

# Оконные аккумуляторы — физика (пер-тик)
var _win_phys_accum := 0.0
var _win_phys_max := 0.0
var _win_gd_accum := 0.0
var _win_ticks := 0
# Оконные аккумуляторы — рендер (пер-кадр)
var _win_wall := 0.0
var _win_frame_accum := 0.0
var _win_frames := 0
var _win_min_fps := 1.0e9
var _win_over := 0

var _node_count_start := 0
var _windows: Array = []


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


## Старт прогона. Зовёт game.gd при --probe после постройки сцены.
func begin(scenario: String, seed_value: int, duration_s: float) -> void:
	_scenario = scenario
	_seed = seed_value
	_duration_s = duration_s
	_node_count_start = int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	_t0_unix = Time.get_unix_time_from_system()
	_reset_window()
	_active = true
	print("@TLM_BEGIN scenario=%s seed=%d duration_s=%.0f" % [scenario, seed_value, duration_s])


func _physics_process(_delta: float) -> void:
	if not _active:
		return
	_tick += 1
	# Пик физики = max времени ОДНОГО физ-тика (кандидат во фриз, не среднее).
	var pm := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	_phys_ms_all.append(pm)
	_win_phys_accum += pm
	if pm > _win_phys_max:
		_win_phys_max = pm
	_win_ticks += 1
	if tick_cb.is_valid():
		_win_gd_accum += tick_cb.call()  # O(1): _sim_us_last/1000
	if Time.get_unix_time_from_system() - _t0_unix >= _duration_s:
		finish()


func _process(delta: float) -> void:
	if not _active:
		return
	# Рендер-кадры: frame time, FPS, доля кадров вне бюджета (физика ≠ рендер).
	_win_wall += delta
	_win_frames += 1
	var fr_ms := delta * 1000.0
	_frame_ms_all.append(fr_ms)
	_win_frame_accum += fr_ms
	var fps := Engine.get_frames_per_second()
	if fps < _win_min_fps:
		_win_min_fps = fps
	if fr_ms > BUDGET_MS:
		_win_over += 1
	if _win_wall >= WINDOW_S:
		_flush_window()


func _flush_window() -> void:
	var g: Dictionary = {}
	if sample_cb.is_valid():
		g = sample_cb.call()  # O(N) — только здесь, раз в окно
	var phys_avg := _win_phys_accum / float(maxi(1, _win_ticks))
	var gd_avg := _win_gd_accum / float(maxi(1, _win_ticks))
	var frame_avg := _win_frame_accum / float(maxi(1, _win_frames))
	var over_pct := 100.0 * _win_over / float(maxi(1, _win_frames))
	var sample := {
		"t": snappedf(Time.get_unix_time_from_system() - _t0_unix, 0.01),
		"tick": _tick,
		"fps": int(Engine.get_frames_per_second()),
		"min_fps_win": int(_win_min_fps),
		"frame_ms": snappedf(frame_avg, 0.01),
		"physics_ms_avg": snappedf(phys_avg, 0.01),
		"physics_ms_max": snappedf(_win_phys_max, 0.01),
		"gd_ms": snappedf(gd_avg, 0.01),
		"jolt_ms": snappedf(maxf(0.0, phys_avg - gd_avg), 0.01),
		"over_budget_pct": snappedf(over_pct, 0.1),
		"active": int(g.get("active", -1)),
		"dormant": int(g.get("dormant", -1)),
		"free": int(g.get("free", -1)),
		"visible_coins": int(g.get("active", -1)),
		"vis_gold": int(g.get("vis_gold", 0)),
		"node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"draw_calls": int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		"render_objs": int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		"cap": int(g.get("cap", -1)),
	}
	_windows.append(sample)
	print("@TLM %s" % JSON.stringify(sample))
	_reset_window()


func _reset_window() -> void:
	_win_phys_accum = 0.0
	_win_phys_max = 0.0
	_win_gd_accum = 0.0
	_win_ticks = 0
	_win_wall = 0.0
	_win_frame_accum = 0.0
	_win_frames = 0
	_win_min_fps = 1.0e9
	_win_over = 0


func finish() -> void:
	if not _active:
		return
	_active = false
	var node_end := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var dur := Time.get_unix_time_from_system() - _t0_unix
	var phys := _stats(_phys_ms_all)
	var frame := _stats(_frame_ms_all)
	var leak := node_end - _node_count_start
	var frame_p95: float = frame["p95"]
	var reasons: Array = []
	if leak >= 200:
		reasons.append("node_leak=%d" % leak)
	# На телефоне frame_ms реальный → прямой гейт бюджета. На десктопе с vsync
	# frame≈16.7 (тривиально проходит) — там смотри phys_p95_x8 (поле ниже).
	if frame_p95 > BUDGET_MS + 1.0:
		reasons.append("frame_p95=%.1f>%.1f" % [frame_p95, BUDGET_MS])
	var summary := {
		"physics_ms": phys,
		"frame_ms": frame,
		"phys_p95_x8": snappedf(float(phys["p95"]) * PHONE_FACTOR, 0.01),
		"min_fps": _min_of_windows("min_fps_win"),
		"frames_over_budget_pct": _overall_over_pct(),
		"node_count_start": _node_count_start,
		"node_count_end": node_end,
		"node_leak": leak,
		"max_visible_coins": _max_of_windows("visible_coins"),
		"max_vis_gold": _max_of_windows("vis_gold"),
		"max_draw_calls": _max_of_windows("draw_calls"),
		"cap_min": _min_of_windows("cap"),
		"cap_max": _max_of_windows("cap"),
		"pass": reasons.is_empty(),
		"fail_reasons": reasons,
	}
	var payload := {
		"schema": 1,
		"seed": _seed,
		"scenario": _scenario,
		"duration_s": snappedf(dur, 0.01),
		"ticks": _tick,
		"device": null,  # хост дозаполняет после выкачки (model/size/gpu)
		"summary": summary,
		"windows": _windows,
	}
	print("@TLM_SUMMARY %s" % JSON.stringify(summary))
	var path := "user://telemetry/run-%d-%d.json" % [_seed, int(_t0_unix)]
	var err := _write_json(path, payload)
	print("@TLM_DONE -> %s exit=0 ok=%d" % [ProjectSettings.globalize_path(path), 1 if err == OK else 0])
	get_tree().quit(0)


func _write_json(path: String, data: Dictionary) -> int:
	# Рецепт shot_tool.gd: создать каталог, записать, закрыть.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	return OK


func _stats(a: PackedFloat32Array) -> Dictionary:
	var n := a.size()
	if n == 0:
		return {"p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var s := a.duplicate()
	s.sort()
	return {
		"p50": snappedf(s[int(0.50 * (n - 1))], 0.01),
		"p95": snappedf(s[int(0.95 * (n - 1))], 0.01),
		"p99": snappedf(s[int(0.99 * (n - 1))], 0.01),
		"max": snappedf(s[n - 1], 0.01),
	}


func _max_of_windows(key: String) -> int:
	if _windows.is_empty():
		return -1
	var m := -2147483648
	for w in _windows:
		m = maxi(m, int(w.get(key, m)))
	return m


func _min_of_windows(key: String) -> int:
	if _windows.is_empty():
		return -1
	var m := 2147483647
	for w in _windows:
		m = mini(m, int(w.get(key, m)))
	return m


func _overall_over_pct() -> float:
	var n := _frame_ms_all.size()
	if n == 0:
		return 0.0
	var over := 0
	for v in _frame_ms_all:
		if v > BUDGET_MS:
			over += 1
	return snappedf(100.0 * over / n, 0.1)
