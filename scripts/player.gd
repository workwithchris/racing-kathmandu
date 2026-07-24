extends CharacterBody3D
## On-foot player: WASD/arrows move relative to the chase camera's current
## facing (GTA-style), Space jumps. Disabled while the player is driving the
## car (see main.gd), so it doesn't fight the vehicle for input/physics.
##
## The body is a jointed low-poly figure (see player.tscn: Rig/Torso, Head,
## ArmL/ArmR, LegL/LegR) rather than a single capsule. There's no skeleton or
## animation clips -- _animate() below just swings the limb pivots on a sine
## cycle driven by ground speed, the same "procedural walk" trick used for
## the car's wheels having no engine model behind them.

@export var speed := 5.0
@export var jump_velocity := 6.0
@export var gravity := 18.0
@export var turn_speed := 10.0
@export var camera_path: NodePath

## Degrees the legs/arms swing at a full stride, and how many stride-radians
## accumulate per metre of ground travel (stride "frequency").
@export var leg_swing_deg := 34.0
@export var arm_swing_deg := 28.0
@export var stride_rate := 2.6
@export var bob_amount := 0.045
## How fast limbs relax back to neutral when idle, and pull into the airborne
## pose when off the ground.
@export var pose_blend_speed := 9.0

@onready var _camera: Camera3D = get_node_or_null(camera_path)
@onready var _rig: Node3D = %Rig
@onready var _leg_l: Node3D = %LegL
@onready var _leg_r: Node3D = %LegR
@onready var _arm_l: Node3D = %ArmL
@onready var _arm_r: Node3D = %ArmR

var _gait_phase := 0.0

## Toggled by main.gd: false while the player is riding in the car, so the
## body neither processes input nor sits there as a solid obstacle.
var active := true:
	set(value):
		active = value
		set_physics_process(value)
		visible = value
		if is_inside_tree():
			var col := get_node_or_null("CollisionShape3D")
			if col:
				col.disabled = not value

func _ready() -> void:
	active = active

func _physics_process(delta: float) -> void:
	var input_dir := Vector2(
		Input.get_axis("move_left", "move_right"),
		Input.get_axis("move_forward", "move_back")
	)
	if input_dir.length() > 1.0:
		input_dir = input_dir.normalized()

	var forward := Vector3.FORWARD
	var right := Vector3.RIGHT
	if _camera:
		forward = -_camera.global_transform.basis.z
		right = _camera.global_transform.basis.x
	forward.y = 0.0
	right.y = 0.0
	forward = forward.normalized() if forward.length_squared() > 0.0001 else Vector3.FORWARD
	right = right.normalized() if right.length_squared() > 0.0001 else Vector3.RIGHT

	var move_dir := forward * -input_dir.y + right * input_dir.x
	if move_dir.length() > 1.0:
		move_dir = move_dir.normalized()

	if is_on_floor():
		if velocity.y < 0.0:
			velocity.y = -1.0
		if Input.is_action_just_pressed("jump"):
			velocity.y = jump_velocity
	else:
		velocity.y -= gravity * delta

	velocity.x = move_dir.x * speed
	velocity.z = move_dir.z * speed
	move_and_slide()

	if move_dir.length_squared() > 0.0001:
		_face(move_dir, delta)

	_animate(delta)

func _face(dir: Vector3, delta: float) -> void:
	var z_axis := -dir.normalized()
	var x_axis := Vector3.UP.cross(z_axis).normalized()
	var target_basis := Basis(x_axis, Vector3.UP, z_axis)
	var cur := global_transform.basis.orthonormalized()
	var q := cur.get_rotation_quaternion().slerp(target_basis.get_rotation_quaternion(), clampf(turn_speed * delta, 0.0, 1.0))
	global_transform.basis = Basis(q).scaled(global_transform.basis.get_scale())

## Drives the limb pivots each frame: a sine-wave stride while grounded and
## moving, a settled idle pose at rest, and a tucked pose in the air.
func _animate(delta: float) -> void:
	var speed_xz := Vector2(velocity.x, velocity.z).length()
	var t := clampf(pose_blend_speed * delta, 0.0, 1.0)

	if not is_on_floor():
		_leg_l.rotation.x = lerp_angle(_leg_l.rotation.x, deg_to_rad(-16.0), t)
		_leg_r.rotation.x = lerp_angle(_leg_r.rotation.x, deg_to_rad(-16.0), t)
		_arm_l.rotation.x = lerp_angle(_arm_l.rotation.x, deg_to_rad(-30.0), t)
		_arm_r.rotation.x = lerp_angle(_arm_r.rotation.x, deg_to_rad(-30.0), t)
		_rig.position.y = lerpf(_rig.position.y, 0.03, t)
		return

	if speed_xz > 0.15:
		_gait_phase += delta * speed_xz * stride_rate
		var swing := sin(_gait_phase)
		_leg_l.rotation.x = swing * deg_to_rad(leg_swing_deg)
		_leg_r.rotation.x = -swing * deg_to_rad(leg_swing_deg)
		_arm_l.rotation.x = -swing * deg_to_rad(arm_swing_deg)
		_arm_r.rotation.x = swing * deg_to_rad(arm_swing_deg)
		_rig.position.y = absf(cos(_gait_phase)) * bob_amount
	else:
		_gait_phase = 0.0
		_leg_l.rotation.x = lerp_angle(_leg_l.rotation.x, 0.0, t)
		_leg_r.rotation.x = lerp_angle(_leg_r.rotation.x, 0.0, t)
		_arm_l.rotation.x = lerp_angle(_arm_l.rotation.x, 0.0, t)
		_arm_r.rotation.x = lerp_angle(_arm_r.rotation.x, 0.0, t)
		_rig.position.y = lerpf(_rig.position.y, 0.0, t)
