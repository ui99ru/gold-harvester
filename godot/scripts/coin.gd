extends RigidBody3D
## Монета. Физпараметры перенесены из Three.js-версии (src/config.js, src/main.js).
## Геометрия и материал — общие static-ресурсы: один меш и один материал на все
## монеты (батчинг), один PhysicsMaterial.

const RADIUS := 0.40                       # = CFG.COIN_RAD (дублируем: coin.tscn самодостаточен)
const THICKNESS := 0.085
const DENSITY := 9.0                       # rapier coinDensity
const MAX_SPEED := 12.0                    # rapier coinMaxV
const CLINK_IMPULSE := 0.7                 # порог импульса контакта для звона, Н·с
const CLINK_V2 := 9.0                      # clinkV=3.0² — скольжение/оседание молчит (web drainContacts)

# Активный «завал» монеты с ребра (порт physics.js:129-136, пороги src/config.js:31-32)
const CALM_V2 := 1.44                      # calmV 1.2²
const CALM_FRAMES := 18                    # кадров деадзоны до сна
const CALM_W2 := 36.0                      # calmW 6.0²
const CALM_VY := 0.4
const CALM_FLAT := 0.45
const CALM_FLAT_G := 0.75
const CALM_GROUND_Y := 0.6
const FLATTEN_K := 8.0

@export var calm_flatten := true

var idx := -1                              # стабильный индекс в пуле (side-массивы ворот)
var worth := 1                             # ценность; множится воротами

# Вызывается main'ом: (global_pos: Vector3, strength: float 0..1)
var clink_cb := Callable()

# «Звон» on/off (тумблер). Монитор контактов — только у активных монет (O5).
var clink_wanted := true

# O3 «физический LOD»: осевшая вдали монета — dormant (freeze=статик, вне
# dynamic-солвера Jolt, но коллайдер и видима). Возврат в dynamic при подъезде.
var dormant := false

static var _shape: CylinderShape3D
static var _mesh: CylinderMesh
static var _material: StandardMaterial3D
static var _phys_material: PhysicsMaterial


static func _ensure_shared() -> void:
	if _shape:
		return
	_shape = CylinderShape3D.new()
	_shape.radius = RADIUS
	_shape.height = THICKNESS

	_mesh = CylinderMesh.new()
	_mesh.top_radius = RADIUS
	_mesh.bottom_radius = RADIUS
	_mesh.height = THICKNESS
	_mesh.radial_segments = 24

	_material = StandardMaterial3D.new()                 # палитра web-версии
	# Цвета впечены в атлас (TexGen.coin_atlas: грань #ffb42e + гравировка,
	# бок #e0a52e), albedo белый. Рельеф — normal из bump-карты (web bumpScale 1.4).
	_material.albedo_color = Color.WHITE
	_material.albedo_texture = TexGen.coin_atlas()
	_material.normal_enabled = true
	_material.normal_texture = TexGen.coin_normal()
	_material.metallic = 0.42
	_material.roughness = 0.36
	_material.emission_enabled = true
	_material.emission = Color("c06a00")
	_material.emission_energy_multiplier = 0.27

	_phys_material = PhysicsMaterial.new()
	_phys_material.friction = 0.95                       # rapier coinFriction
	_phys_material.bounce = 0.02                         # rapier coinRestitution


func _ready() -> void:
	_ensure_shared()
	mass = PI * RADIUS * RADIUS * THICKNESS * DENSITY    # ≈ 0.384 кг
	physics_material_override = _phys_material
	linear_damp = 0.8                                    # rapier linDamp
	angular_damp = 0.9                                   # rapier angDamp
	can_sleep = true
	# O5: контакт-монитор 1000 спящих тел — главная цена Jolt (замер на устройстве:
	# jolt 101→45 мс при выключенном «Звоне»). Держим его только у бодрствующих
	# монет, способных звенеть; спящие/замороженные — без монитора. Управление —
	# по событию засыпания/пробуждения, без поллинга.
	contact_monitor = false                              # включится в _refresh_monitor по пробуждении
	max_contacts_reported = 1                            # для звона хватает 1 точки
	sleeping_state_changed.connect(_refresh_monitor)

	var cs := CollisionShape3D.new()
	cs.shape = _shape
	add_child(cs)

	var mi := MeshInstance3D.new()
	mi.mesh = _mesh
	mi.material_override = _material
	add_child(mi)


## Контакт-монитор только у активных монет (O5). set_deferred — безопасно из
## колбэка sleeping_state_changed (вне физ-шага применится в конце кадра).
func _refresh_monitor() -> void:
	set_deferred("contact_monitor", clink_wanted and not freeze and not sleeping)


func set_clink_wanted(on: bool) -> void:
	clink_wanted = on
	_refresh_monitor()


## O3: вывести осевшую дальнюю монету из симуляции — ровно как паркует пул
## (freeze=статик + слои в 0: ни островов, ни контактных пар), но на месте и
## видимой. Сохранять коллизию нельзя — freeze с коллизией дробит спящий остров
## кучи и выходит ДОРОЖЕ (замер: jolt 101→172). Возврат — make_active.
func make_dormant() -> void:
	if dormant or freeze:
		return
	dormant = true
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	freeze = true
	_refresh_monitor()


func make_active() -> void:
	if not dormant:
		return
	dormant = false
	freeze = false
	collision_layer = 1
	collision_mask = 1
	_refresh_monitor()


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var v := state.linear_velocity
	var s := v.length_squared()
	if s > MAX_SPEED * MAX_SPEED:
		state.linear_velocity = v.normalized() * MAX_SPEED
		v = state.linear_velocity
		s = MAX_SPEED * MAX_SPEED

	# Звон: удар с импульсом выше порога И тело реально движется (web clinkV)
	if clink_cb.is_valid() and s > CLINK_V2:
		for i in state.get_contact_count():
			var imp := state.get_contact_impulse(i).length()
			if imp > CLINK_IMPULSE:
				clink_cb.call(global_position, clampf(imp / (CLINK_IMPULSE * 6.0), 0.15, 1.0))
				break

	# Активный «завал» с ребра (web physics.js:134-135). Принудительный сон
	# web (обнуление + sleep) НЕ портирован: обнуление скоростей каждый тик
	# сбрасывает таймер сна Jolt и ломает островной сон (куча перестаёт
	# засыпать вовсе). Вместо него — агрессивные sleep-пороги Jolt в
	# project.godot (sleep_velocity_threshold/time_threshold).
	if calm_flatten and s < CALM_V2 and absf(v.y) < CALM_VY \
			and state.angular_velocity.length_squared() < CALM_W2:
		var up := state.transform.basis.y                # ось монеты R·(0,1,0)
		var flat_thr := CALM_FLAT_G if state.transform.origin.y < CALM_GROUND_Y else CALM_FLAT
		if absf(up.y) < flat_thr:
			state.angular_velocity = Vector3(-FLATTEN_K * up.z, 0, FLATTEN_K * up.x)
