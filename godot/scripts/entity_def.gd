class_name EntityDef
extends Resource
## Одна сущность уровня. type: "wall" | "gate" | "pad_knife" | "trash".
## params: wall {half: Vector3}; gate {mult: int, cost: int}; pad_knife {cost: int}.

@export var type := ""
@export var position := Vector3.ZERO
@export var rotation_y := 0.0
@export var params := {}
