extends Camera3D
## Chase camera with GTA-style mouse-look: moving the mouse orbits the camera
## (yaw + pitch).
##
## Two follow modes, picked via set_target()'s follow_facing param:
## - follow_facing = true (driving): the camera's yaw continuously tracks the
##   target's current heading, with mouse-look as an offset on top that decays
##   back to 0 when the mouse sits idle -- so orbiting stays relative to
##   wherever the car is currently pointed, and letting go of the mouse settles
##   the camera back directly behind it. Safe because the car's heading comes
##   from its own vehicle physics, independent of the camera.
## - follow_facing = false (on foot): the camera's yaw is fully independent,
##   moved only by the mouse, with no auto-recenter. This mode exists because
##   the player's own movement/facing is camera-relative (see player.gd) --
##   if the camera also tracked the player's facing like it does the car's,
##   the two would chase each other's tail: camera yaw sets the player's move
##   direction, the player turns to face it, and the camera re-centers on that
##   new facing, repeating every frame. Whenever the input direction isn't
##   dead-ahead of the camera (e.g. strafing), that loop doesn't converge --
##   it spins continuously, which is exactly the "camera moving here and
##   there" bug this mode avoids by never reading the target's facing again
##   after the initial snap in set_target().

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

## Mouse-look tuning.
@export var mouse_sensitivity := 0.006
@export var min_pitch_deg := -20.0
@export var max_pitch_deg := 60.0
## Seconds of no mouse movement before the camera starts drifting back behind the car.
@export var recenter_delay := 1.2
## Radians/sec the yaw offset recenters at once idle.
@export var recenter_speed := 2.0
## Captures and hides the OS cursor so mouse deltas are unbounded, like a normal 3D game.
@export var capture_mouse := true

var _target: Node3D
var _follow_facing := true
var _yaw := 0.0           # absolute yaw, used directly when not follow_facing
var _yaw_offset := 0.0    # orbit offset from the target's heading, used when follow_facing
var _pitch := 0.15        # radians, absolute
var _idle_time := 0.0

func _ready() -> void:
	if target_path:
		_target = get_node_or_null(target_path)
		if _target:
			_yaw = _facing_yaw(_target)
	if capture_mouse:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Retargets the camera at runtime (e.g. switching between the on-foot player
## and the car). Snaps straight to the new framing instead of lerping from
## wherever the old target left off, so the swap doesn't visibly swoop.
func set_target(node: Node3D, cam_distance: float, cam_height: float, cam_look_height: float, follow_facing: bool = true) -> void:
	_target = node
	distance = cam_distance
	height = cam_height
	look_height = cam_look_height
	_follow_facing = follow_facing
	_yaw_offset = 0.0
	if _target:
		_yaw = _facing_yaw(_target)
		var horiz := cos(_pitch)
		var dir := Vector3(sin(_yaw) * horiz, sin(_pitch), cos(_yaw) * horiz)
		global_position = _target.global_position + dir * distance + Vector3.UP * height
		look_at(_target.global_position + Vector3.UP * look_height, Vector3.UP)

## The target's backward direction flattened to the horizontal plane (so a
## bumpy/banked chassis doesn't drag the camera's reference frame with it).
func _facing_yaw(node: Node3D) -> float:
	var back := node.global_transform.basis.z
	back.y = 0.0
	if back.length() < 0.001:
		back = Vector3.BACK
	back = back.normalized()
	return atan2(back.x, back.z)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		if _follow_facing:
			_yaw_offset -= event.relative.x * mouse_sensitivity
		else:
			_yaw -= event.relative.x * mouse_sensitivity
		_pitch = clampf(_pitch - event.relative.y * mouse_sensitivity,
				deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
		_idle_time = 0.0
	elif event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
	if _target == null:
		return

	var yaw: float
	if _follow_facing:
		_idle_time += delta
		if _idle_time > recenter_delay:
			_yaw_offset = move_toward(_yaw_offset, 0.0, recenter_speed * delta)
		yaw = _facing_yaw(_target) + _yaw_offset
	else:
		yaw = _yaw

	var horiz := cos(_pitch)
	var dir := Vector3(sin(yaw) * horiz, sin(_pitch), cos(yaw) * horiz)
	var desired := _target.global_position + dir * distance + Vector3.UP * height

	global_position = global_position.lerp(desired, clampf(follow_speed * delta, 0.0, 1.0))
	look_at(_target.global_position + Vector3.UP * look_height, Vector3.UP)
