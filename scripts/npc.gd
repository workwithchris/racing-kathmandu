extends CharacterBody3D
## Simple pedestrian: walks back and forth between two sidewalk points.

@export var target_a := Vector3.ZERO
@export var target_b := Vector3.ZERO
@export var walk_speed := 1.6

var _target: Vector3

func _ready() -> void:
	_target = target_a
	look_at_target()

func _physics_process(delta: float) -> void:
	var to := _target - global_position
	to.y = 0.0
	if to.length() < 0.4:
		_target = target_a if _target == target_b else target_b
		to = _target - global_position
		to.y = 0.0

	var dir := to.normalized()
	look_at_target()
	velocity = Vector3(dir.x * walk_speed, -9.8, dir.z * walk_speed)
	move_and_slide()

func look_at_target() -> void:
	var flat := _target
	flat.y = global_position.y
	if flat.distance_squared_to(global_position) > 0.001:
		look_at(flat, Vector3.UP)
