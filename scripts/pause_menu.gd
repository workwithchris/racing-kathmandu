extends CanvasLayer
## Escape toggles a pause overlay: Resume, a full-screen map, back to the
## main menu, or quit. process_mode = ALWAYS so this node keeps handling
## input (and the map keeps rendering) while get_tree().paused freezes
## everything else.

## Whichever entity (player or car) the full map centers on -- kept in sync
## by main.gd via set_tracked() the same way the chase camera and world
## streaming are.
@export var tracked_path: NodePath
## Kept within the map's load_radius (world streams in ~900m around the
## tracked entity) so the full map shows loaded streets/buildings instead of
## bare unstreamed terrain past that range.
@export var map_meters_across := 1600.0

@onready var _menu_panel: Control = %MenuPanel
@onready var _map_panel: Control = %MapPanel
@onready var _map_texture_rect: TextureRect = %MapTextureRect
@onready var _map_marker: Label = %MapMarker

var _tracked: Node3D
var _open := false
var _showing_map := false
var _map_viewport: SubViewport
var _map_camera: Camera3D

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false

	_tracked = get_node_or_null(tracked_path)

	_map_viewport = SubViewport.new()
	_map_viewport.size = Vector2i(1024, 1024)
	_map_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_map_viewport.world_3d = get_viewport().world_3d
	add_child(_map_viewport)

	_map_camera = Camera3D.new()
	_map_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_map_camera.size = map_meters_across
	_map_camera.near = 10.0
	_map_camera.far = 2000.0
	_map_camera.rotation_degrees = Vector3(-90, 0, 0)
	_map_viewport.add_child(_map_camera)
	_map_texture_rect.texture = _map_viewport.get_texture()

	%ResumeButton.pressed.connect(_close)
	%MapButton.pressed.connect(_show_map)
	%MapBackButton.pressed.connect(_show_menu)
	%MainMenuButton.pressed.connect(_to_main_menu)
	%QuitButton.pressed.connect(_quit)

## Called by main.gd whenever control switches between the on-foot player and
## the car, so the full map keeps centering on whichever one is active.
func set_tracked(node: Node3D) -> void:
	_tracked = node

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if not _open:
			_open_pause()
		elif _showing_map:
			_show_menu()
		else:
			_close()
		get_viewport().set_input_as_handled()

func _open_pause() -> void:
	_open = true
	visible = true
	_show_menu()
	get_tree().paused = true
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

func _close() -> void:
	_open = false
	visible = false
	get_tree().paused = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _show_map() -> void:
	_showing_map = true
	_menu_panel.visible = false
	_map_panel.visible = true

func _show_menu() -> void:
	_showing_map = false
	_map_panel.visible = false
	_menu_panel.visible = true

func _to_main_menu() -> void:
	get_tree().paused = false
	get_tree().change_scene_to_file("res://scenes/main_menu.tscn")

func _quit() -> void:
	get_tree().quit()

func _process(_delta: float) -> void:
	if not (_open and _showing_map) or _tracked == null:
		return
	var p := _tracked.global_position
	# Ortho projection means camera height doesn't change the zoom, only how
	# much atmospheric fog the view has to look through -- stay low like the
	# corner minimap does, or the haze washes the whole map out to a blur.
	_map_camera.global_position = Vector3(p.x, p.y + 600.0, p.z)
	var fwd := -_tracked.global_transform.basis.z
	_map_marker.rotation = atan2(fwd.x, -fwd.z)
