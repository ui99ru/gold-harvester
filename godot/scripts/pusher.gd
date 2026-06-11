extends AnimatableBody3D
## Толкатель: возвратно-поступательная синусоида вдоль z (бриф §4).
## AnimatableBody3D + sync_to_physics — физика корректно передаёт импульс монетам.

const SIZE := Vector3(8.8, 1.0, 2.0)
const PERIOD := 2.5      # с
const AMPLITUDE := 1.8

var base_z := 0.0

var _t := 0.0


func _ready() -> void:
	sync_to_physics = true
	base_z = position.z

	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = SIZE
	cs.shape = box
	add_child(cs)

	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = SIZE
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color("33647f")  # стально-голубой ковша web-версии
	mat.roughness = 0.55
	mat.metallic = 0.3
	mi.material_override = mat
	add_child(mi)


func _physics_process(delta: float) -> void:
	_t += delta
	position.z = base_z + AMPLITUDE * sin(TAU * _t / PERIOD)
