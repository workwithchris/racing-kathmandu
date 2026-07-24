extends Node3D
## Game glue: switches control between the on-foot player and the car,
## keeps the HUD/camera/world-streaming in sync with whichever is active,
## and lets the player reset the car (R).

@onready var _car: VehicleBody3D = $Car
@onready var _player: CharacterBody3D = $Player
@onready var _camera = $ChaseCamera
@onready var _map = $Map
@onready var _speed_label: Label = $HUD/SpeedLabel
@onready var _prompt_label: Label = $HUD/PromptLabel

const ENTER_RADIUS := 3.2
const EXIT_SIDE_OFFSET := 2.4

const CAR_CAM_DISTANCE := 8.0
const CAR_CAM_HEIGHT := 3.5
const CAR_CAM_LOOK_HEIGHT := 1.0
const FOOT_CAM_DISTANCE := 5.0
const FOOT_CAM_HEIGHT := 2.2
const FOOT_CAM_LOOK_HEIGHT := 1.3

var _driving := false
var _spawn_transform: Transform3D

func _ready() -> void:
	_spawn_transform = _car.global_transform

	# Player starts on foot; the car sits parked until they walk up and get in.
	_player.active = true
	_car.active = false
	_camera.set_target(_player, FOOT_CAM_DISTANCE, FOOT_CAM_HEIGHT, FOOT_CAM_LOOK_HEIGHT, false)
	_map.set_tracked(_player)
	if _driving:
		var kmh := int(round(_car.linear_velocity.length() * 3.6))
		_speed_label.text = "%d km/h" % kmh
		_prompt_label.text = "Press E to get out"
	else:
		_speed_label.text = "On foot"
		if _player.global_position.distance_to(_car.global_position) <= ENTER_RADIUS:
			_prompt_label.text = "Press E to get in the car"
		else:
			_prompt_label.text = ""

	if Input.is_action_just_pressed("interact"):
		if _driving:
			_exit_car()
		elif _player.global_position.distance_to(_car.global_position) <= ENTER_RADIUS:
			_enter_car()

	if Input.is_action_just_pressed("reset_car"):
		_reset_car()

func _enter_car() -> void:
	_driving = true
	_player.active = false
	_car.active = true
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	_camera.set_target(_car, CAR_CAM_DISTANCE, CAR_CAM_HEIGHT, CAR_CAM_LOOK_HEIGHT)
	_map.set_tracked(_car)

func _exit_car() -> void:
	_driving = false
	_car.active = false
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO

	# Flatten the car's basis (it may be tilted on a slope/suspension) so the
	# player doesn't pop out standing at an angle.
	var car_fwd := -_car.global_transform.basis.z
	car_fwd.y = 0.0
	car_fwd = car_fwd.normalized() if car_fwd.length_squared() > 0.0001 else Vector3.FORWARD
	var z_axis := -car_fwd
	var x_axis := Vector3.UP.cross(z_axis).normalized()
	var flat_basis := Basis(x_axis, Vector3.UP, z_axis)

	var exit_pos := _car.global_position + x_axis * EXIT_SIDE_OFFSET
	exit_pos.y = _map.height_at(exit_pos.x, exit_pos.z)

	_player.velocity = Vector3.ZERO
	_player.global_transform = Transform3D(flat_basis, exit_pos)
	_player.active = true

	_camera.set_target(_player, FOOT_CAM_DISTANCE, FOOT_CAM_HEIGHT, FOOT_CAM_LOOK_HEIGHT, false)
	_map.set_tracked(_player)

func _reset_car() -> void:
	_car.global_transform = _spawn_transform
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
	if _driving:
		_camera.set_target(_car, CAR_CAM_DISTANCE, CAR_CAM_HEIGHT, CAR_CAM_LOOK_HEIGHT)
