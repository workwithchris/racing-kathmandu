extends Node3D
## Game glue: updates the speed HUD and lets the player reset the car (R).

@onready var _car: VehicleBody3D = $Car
@onready var _speed_label: Label = $HUD/SpeedLabel

var _spawn_transform: Transform3D

func _ready() -> void:
	_spawn_transform = _car.global_transform

func _process(_delta: float) -> void:
	var kmh := int(round(_car.linear_velocity.length() * 3.6))
	_speed_label.text = "%d km/h" % kmh

	if Input.is_action_just_pressed("reset_car"):
		_reset_car()

func _reset_car() -> void:
	_car.global_transform = _spawn_transform
	_car.linear_velocity = Vector3.ZERO
	_car.angular_velocity = Vector3.ZERO
