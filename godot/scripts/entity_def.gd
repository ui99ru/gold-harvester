class_name EntityDef
extends Resource
## Одна сущность уровня. type: "wall" | "gate" | "pad" | "pad_knife" (алиас) | "trash".
## params: wall {half: Vector3}; gate {mult, cost}; pad {kind: knife|speed|value, cost}
## (B5 лестница ×3 до кэпа); trash {}.

@export var type := ""
@export var position := Vector3.ZERO
@export var rotation_y := 0.0
@export var params := {}
