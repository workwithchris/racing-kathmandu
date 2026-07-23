extends VehicleBody3D
## Drives a VehicleBody3D from player input.
## Controls: W/Up = accelerate, S/Down = brake or reverse, A/D or Left/Right = steer.

## Peak driving force applied to the traction wheels.
@export var max_engine_force := 600.0
## Peak reverse force (usually weaker than forward).
@export var max_reverse_force := 250.0
## How hard the brakes bite when stopping.
@export var max_brake := 8.0
## Maximum steering angle in radians (~0.5 rad ≈ 29°).
@export var max_steer := 0.5
## How quickly the wheels turn toward the target angle.
@export var steer_speed := 3.0

func _physics_process(delta: float) -> void:
	# Don't drive while the player is typing in a text field (e.g. place search).
	if get_viewport().gui_get_focus_owner() is LineEdit:
		engine_force = 0.0
		brake = 2.0
		return

	# get_axis returns strength(positive) - strength(negative).
	# Positive steering yaws the car toward -X (left), so left is the positive action.
	var steer_input := Input.get_axis("steer_right", "steer_left")
	var target_steer := steer_input * max_steer
	steering = move_toward(steering, target_steer, steer_speed * delta)

	var accel := Input.get_action_strength("accelerate")
	var reverse := Input.get_action_strength("brake_reverse")

	# Speed along the car's nose (-Z). Positive means driving nose-first.
	var forward_speed := -global_transform.basis.z.dot(linear_velocity)

	# Measured on this vehicle: positive engine_force pushes it +Z (toward the
	# chase camera). We want W to drive nose-first (-Z), so accelerate uses a
	# NEGATIVE engine_force and reverse uses a positive one.
	if accel > 0.0:
		engine_force = -accel * max_engine_force
		brake = 0.0
	elif reverse > 0.0:
		if forward_speed > 1.0:
			# Still rolling forward -> the S key acts as the brake.
			engine_force = 0.0
			brake = reverse * max_brake
		else:
			# Stopped or already reversing -> drive backwards.
			engine_force = reverse * max_reverse_force
			brake = 0.0
	else:
		# Coasting: a little engine braking so the car settles.
		engine_force = 0.0
		brake = 0.5
