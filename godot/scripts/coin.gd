extends RigidBody3D
## Монета. Физпараметры перенесены из Three.js-версии (src/config.js, src/main.js).
## Геометрия и материал — общие static-ресурсы: один меш и один материал на все
## монеты (батчинг), один PhysicsMaterial.

const RADIUS := 0.40
const THICKNESS := 0.085
const DENSITY := 9.0                       # rapier coinDensity
const MAX_SPEED := 12.0                    # rapier coinMaxV
const CLINK_IMPULSE := 0.7                 # порог импульса контакта для звона, Н·с

# Вызывается main'ом: (global_pos: Vector3, strength: float 0..1)
var clink_cb := Callable()

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
	_material.albedo_color = Color("ffb42e")
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
	contact_monitor = true                               # нужен для get_contact_count в _integrate_forces
	max_contacts_reported = 2

	var cs := CollisionShape3D.new()
	cs.shape = _shape
	add_child(cs)

	var mi := MeshInstance3D.new()
	mi.mesh = _mesh
	mi.material_override = _material
	add_child(mi)


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var v := state.linear_velocity
	if v.length_squared() > MAX_SPEED * MAX_SPEED:
		state.linear_velocity = v.normalized() * MAX_SPEED

	if clink_cb.is_valid():
		for i in state.get_contact_count():
			var imp := state.get_contact_impulse(i).length()
			if imp > CLINK_IMPULSE:
				clink_cb.call(global_position, clampf(imp / (CLINK_IMPULSE * 6.0), 0.15, 1.0))
				break
