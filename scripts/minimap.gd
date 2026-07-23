extends CanvasLayer
## A live top-down minimap: an orthographic camera renders the real city into a
## SubViewport shown in the corner, with a rotating car marker at the centre.

@export var car_path: NodePath
@export var map_size := 220        ## on-screen size in pixels
@export var meters_across := 320.0 ## how much ground the minimap shows

var _car: Node3D
var _cam: Camera3D
var _marker: Label

func _ready() -> void:
	_car = get_node_or_null(car_path)

	var sv := SubViewport.new()
	sv.size = Vector2i(map_size, map_size)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	sv.world_3d = get_viewport().world_3d  # share the main scene
	sv.transparent_bg = false
	add_child(sv)

	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = meters_across
	_cam.near = 0.5
	_cam.far = 2000.0
	_cam.rotation_degrees = Vector3(-90, 0, 0)  # look straight down (north-up)
	sv.add_child(_cam)

	var vp := get_viewport().get_visible_rect().size
	var origin := Vector2(vp.x - map_size - 22, vp.y - map_size - 22)

	var frame := Panel.new()
	frame.position = origin - Vector2(4, 4)
	frame.size = Vector2(map_size + 8, map_size + 8)
	add_child(frame)

	var tr := TextureRect.new()
	tr.texture = sv.get_texture()
	tr.position = origin
	tr.size = Vector2(map_size, map_size)
	add_child(tr)

	var label := Label.new()
	label.text = "MAP"
	label.add_theme_font_size_override("font_size", 12)
	label.position = origin + Vector2(6, 4)
	add_child(label)

	_marker = Label.new()
	_marker.text = "▲"
	_marker.add_theme_font_size_override("font_size", 22)
	_marker.add_theme_color_override("font_color", Color(0.95, 0.15, 0.15))
	_marker.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_marker.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_marker.size = Vector2(26, 26)
	_marker.pivot_offset = Vector2(13, 13)
	_marker.position = origin + Vector2(map_size, map_size) * 0.5 - Vector2(13, 13)
	add_child(_marker)

func _process(_delta: float) -> void:
	if _car == null:
		return
	var p := _car.global_position
	_cam.global_position = Vector3(p.x, p.y + 400.0, p.z)
	# North-up map: rotate the car marker to match heading.
	var fwd := -_car.global_transform.basis.z
	_marker.rotation = atan2(fwd.x, -fwd.z)
