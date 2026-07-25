extends CharacterBody3D
## Pedestrian: walks back and forth between two sidewalk points with a simple
## procedural stride (legs/arms swing on a sine cycle), and picks its own
## clothing colours so a crowd doesn't look cloned. Same blocky-figure look as
## the player character.

@export var target_a := Vector3.ZERO
@export var target_b := Vector3.ZERO
@export var walk_speed := 1.5

## Colourful tops (Kathmandu streetwear) over darker trousers.
const SHIRTS := [
	Color(0.82, 0.34, 0.16), Color(0.30, 0.45, 0.60), Color(0.35, 0.55, 0.30),
	Color(0.84, 0.72, 0.30), Color(0.85, 0.85, 0.85), Color(0.66, 0.38, 0.40),
	Color(0.45, 0.30, 0.55), Color(0.20, 0.55, 0.52), Color(0.74, 0.30, 0.23),
]
const PANTS := [
	Color(0.22, 0.24, 0.32), Color(0.12, 0.12, 0.14), Color(0.30, 0.30, 0.32),
	Color(0.32, 0.26, 0.18), Color(0.40, 0.40, 0.34),
]

@onready var _leg_l: Node3D = %LegL
@onready var _leg_r: Node3D = %LegR
@onready var _arm_l: Node3D = %ArmL
@onready var _arm_r: Node3D = %ArmR

var _target: Vector3
var _gait := 0.0

func _ready() -> void:
	_target = target_a
	walk_speed = 1.1 + randf() * 0.9
	_recolor()
	look_at_target()

func _recolor() -> void:
	var shirt: Color = SHIRTS[randi() % SHIRTS.size()]
	var pants: Color = PANTS[randi() % PANTS.size()]
	_paint(%Torso, shirt)
	_paint(get_node_or_null("Rig/ArmL/Mesh"), shirt)
	_paint(get_node_or_null("Rig/ArmR/Mesh"), shirt)
	_paint(get_node_or_null("Rig/LegL/Mesh"), pants)
	_paint(get_node_or_null("Rig/LegR/Mesh"), pants)

func _paint(mi: Node, col: Color) -> void:
	if mi is MeshInstance3D:
		var m := StandardMaterial3D.new()
		m.albedo_color = col
		m.roughness = 0.82
		mi.material_override = m

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
	_animate(delta)

func _animate(delta: float) -> void:
	_gait += delta * walk_speed * 3.4
	var swing := sin(_gait) * 0.5
	_leg_l.rotation.x = swing
	_leg_r.rotation.x = -swing
	_arm_l.rotation.x = -swing * 0.85
	_arm_r.rotation.x = swing * 0.85

func look_at_target() -> void:
	var flat := _target
	flat.y = global_position.y
	if flat.distance_squared_to(global_position) > 0.001:
		look_at(flat, Vector3.UP)
