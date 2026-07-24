extends ColorRect
## Drives the speed_blur.gdshader "amount" parameter from the car's speed.
## Attach to a full-rect ColorRect (anchors 0,0 -> 1,1) using speed_blur.gdshader,
## placed in its own low-layer CanvasLayer so it draws under the HUD text.

@export var car_path: NodePath
## km/h at which the blur ramps in.
@export var blur_start_kmh := 40.0
## km/h at which the blur reaches max_blur.
@export var blur_max_kmh := 140.0
@export var max_blur := 0.6

var _car: Node3D

func _ready() -> void:
	_car = get_node_or_null(car_path)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(_delta: float) -> void:
	if _car == null or material == null:
		return
	var kmh: float = _car.linear_velocity.length() * 3.6
	var t := clampf((kmh - blur_start_kmh) / maxf(blur_max_kmh - blur_start_kmh, 0.01), 0.0, 1.0)
	material.set_shader_parameter("amount", t * max_blur)
