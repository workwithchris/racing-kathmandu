extends CharacterBody3D
## Simple traffic vehicle: drives back and forth along a fixed lane path
## (a lane-offset polyline built from real road data by kathmandu_map.gd).

const PALETTE := [
	Color(0.82, 0.15, 0.13),
	Color(0.85, 0.85, 0.85),
	Color(0.12, 0.12, 0.14),
	Color(0.15, 0.35, 0.75),
	Color(0.75, 0.72, 0.15),
	Color(0.30, 0.30, 0.32),
	Color(0.35, 0.55, 0.30),
]

@export var path: PackedVector3Array = PackedVector3Array()
@export var speed := 6.0
@export var turn_speed := 4.0

var _idx := 1
var _dir := 1

func _ready() -> void:
	var body := get_node_or_null("Body")
	if body is MeshInstance3D:
		var mat := StandardMaterial3D.new()
		mat.albedo_color = PALETTE[randi() % PALETTE.size()]
		mat.metallic = 0.3
		mat.roughness = 0.35
		body.material_override = mat
	if path.size() >= 2:
		global_position = path[0]
		_face(path[1] - path[0], 1.0)

func _physics_process(delta: float) -> void:
	if path.size() < 2:
		velocity = Vector3(0.0, -9.8, 0.0)
		move_and_slide()
		return

	var target: Vector3 = path[_idx]
	var to := target - global_position
	to.y = 0.0
	if to.length() < 0.8:
		_advance()
		target = path[_idx]
		to = target - global_position
		to.y = 0.0

	var dir := Vector3.ZERO
	if to.length() > 0.001:
		dir = to.normalized()
		_face(dir, delta)

	velocity = Vector3(dir.x * speed, -9.8, dir.z * speed)
	move_and_slide()

func _advance() -> void:
	_idx += _dir
	if _idx >= path.size():
		_idx = path.size() - 2
		_dir = -1
	elif _idx < 0:
		_idx = 1
		_dir = 1

## Drives the car nose-first (-Z) toward `dir`, matching the player car's convention.
func _face(dir: Vector3, delta: float) -> void:
	if dir.length_squared() < 0.0001:
		return
	var z_axis := -dir.normalized()
	var x_axis := Vector3.UP.cross(z_axis).normalized()
	var target_basis := Basis(x_axis, Vector3.UP, z_axis)
	var cur := global_transform.basis.orthonormalized()
	var q := cur.get_rotation_quaternion().slerp(target_basis.get_rotation_quaternion(), clampf(turn_speed * delta, 0.0, 1.0))
	global_transform.basis = Basis(q)
