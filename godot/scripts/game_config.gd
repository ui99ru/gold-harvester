class_name CFG
## Все константы web-версии (src/config.js) 1:1. Карты здесь НЕТ — она в levels/*.tres.
## Палитра/камера откалиброваны циклом сравнения с рефом (docs/METHOD.md) — не «улучшать».

# --- Рендер / атмосфера ---
const EXPOSURE := 0.92
const BG_COLOR := Color("7c6cb2")
const GROUND_COLOR := Color("8e8c94")     # серый текстурированный грунт (правка по рефу)
const FOG_NEAR := 120.0
const FOG_FAR := 360.0
const SUN_INT := 1.5
const HEMI_INT := 1.15
const BLOOM_THR := 0.86
const BLOOM_INTEN := 0.38

# --- Палитра объектов ---
const COIN_COLOR := Color("ffb42e")
const COIN_METAL := 0.42
const COIN_ROUGH := 0.36
const COIN_EMISSIVE := Color("c06a00")
const COIN_EM_INT := 0.27
const DOZER_COLOR := Color("1c1748")      # тёмный индиго-корпус
const SCOOP_COLOR := Color("33647f")      # стально-голубой ковш
const GATE_CURTAIN := Color("5ac8ff")
const GATE_GLOW := Color("39c8ff")

# --- Камера (фит по осям пользователя: yaw 49.4°, см. METHOD.md) ---
const FOV := 43.6
const CAM_HEIGHT := 38.1
const CAM_BACK := 20.0
const LOOK_AHEAD := 11.0
const CAM_YAW := 0.862
const GATE_ROT := 0.0
const CAM_ZOOM_MIN := 0.45
const CAM_ZOOM_MAX := 2.2

# --- Физика монет (валидирована лотком pusher_lab) ---
const GRAVITY_Y := -30.0
const COIN_RAD := 0.40
const COIN_THK := 0.085
const COIN_DENSITY := 9.0
const COIN_FRICTION := 0.95
const COIN_RESTITUTION := 0.02
const LIN_DAMP := 0.8
const ANG_DAMP := 0.9
const CONTACT_THR := 50.0
const COIN_MAX_V := 12.0

# --- Звон ---
const CLINK_CAP := 3          # макс дзынь за кадр
const CLINK_SCALE := 0.05     # контакты -> дзынь
const CLINK_V := 3.0          # порог скорости удара: скольжение/оседание молчит

# --- Успокоение монет (деадзона + активный «завал» с ребра) ---
const CALM_V := 1.2
const CALM_W := 6.0
const CALM_FRAMES := 18
const CALM_VY := 0.4
const CALM_FLAT := 0.45       # |upy| порог «плашмя» в куче
const CALM_FLAT_G := 0.75     # жёстче у земли: наклон <41° — валим
const CALM_GROUND_Y := 0.6
const FLATTEN_K := 8.0

# --- Экономика ---
const GATE1_COST := 10
const GATE2_COST := 600
const UPGRADE_COST := 120
const START_COINS := 5

# --- Волна из ворот ---
const GATE_BURST := 9         # макс физ-копий на монету
const BURST_FWD := 5.5
const BURST_UP := 3.0
const GATE_MIN_V := 1.0       # анти-фарм: медленное продавливание не множит

# --- Дозер / мир ---
const MOVE := 10.0            # скорость дозера (цель апгрейда)
const HEADING_LERP := 7.0
const SPEED_LERP := 5.0
const COIN_N := 1000          # пул тел (web-замер: 1000 ≈ потолок 60fps)
const LANE_HALF := 2.8
const SRC_R := 0.8
const SOURCE_SPREAD_V := 3.5  # радиальный разлёт монет при респауне («волна», против плотной башни)

# --- UP-апгрейды: стартовые значения (мутабельная копия живёт в game.gd) ---
const UP_BLADE_HALF := 1.6
const UP_REACH := 2.7
const UP_MULT := 1.0
