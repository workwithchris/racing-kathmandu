extends Camera3D
## Smoothly follows a target from behind and slightly above.

## The node to follow (set to the Car in the scene).
@export var target_path: NodePath
## How far behind the target the camera sits.
@export var distance := 8.0
## How high above the target the camera sits.
@export var height := 3.5
## Higher = snappier follow, lower = floatier.
@export var follow_speed := 6.0
## Vertical offset of the point the camera looks at.
@export var look_height := 1.0

var _target: Node3D

func _ready() -> void:
	if target_path:
		_target = get_node_or_null(target_path)

func _physics_process(delta: float) -> void:
	if _target == null:
		return
	# The target's +Z axis points backwards (forward is -Z), so this sits behind it.
	var behind := _target.global_transform.basis.z * distance
	var desired := _target.global_position + behind + Vector3.UP * height
	global_position = global_position.lerp(desired, clampf(follow_speed * delta, 0.0, 1.0))
	look_at(_target.global_position + Vector3.UP * look_height, Vector3.UP)
