class_name LevelDef
extends Resource
## Описание уровня: данные, не код. Уровень 1 = точная копия web-карты
## (src/main.js:251-254, 305-311). Редактор карт v0 = правка .tres руками.

@export var source_pos := Vector3.ZERO    # источник монет (центр respawn)
@export var source_radius := 0.8
@export var start_coins := 5
@export var dozer_start := Vector3.ZERO
# Кольцо скал: граница сцены (0 = нет кольца). Дозер клэмпится, монеты
# держит невидимая стена-многоугольник, визуал — скалы по окружности.
@export var ring_center := Vector3.ZERO
@export var ring_radius := 0.0
@export var entities: Array[EntityDef] = []
