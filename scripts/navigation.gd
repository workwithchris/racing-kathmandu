extends CanvasLayer
## Search real Kathmandu places (res://data/places.json). Selecting one drops a
## beacon at that location and shows a HUD arrow + distance pointing toward it.

@export var car_path: NodePath
@export var world_root_path: NodePath  ## a Node3D to parent the beacon under
@export var places_path := "res://data/places.json"

var _car: Node3D
var _world: Node3D
var _places: Array = []
var _dest = null            # Vector2(x, z) or null
var _dest_name := ""
var _beacon: MeshInstance3D

var _search: LineEdit
var _results: VBoxContainer
var _arrow: Label
var _nav_label: Label

func _ready() -> void:
	_car = get_node_or_null(car_path)
	_world = get_node_or_null(world_root_path)
	var f := FileAccess.open(places_path, FileAccess.READ)
	if f:
		var d = JSON.parse_string(f.get_as_text())
		if d is Dictionary:
			_places = d.get("places", [])
		f.close()
	_build_ui()

func _build_ui() -> void:
	var w := float(get_viewport().get_visible_rect().size.x)

	_search = LineEdit.new()
	_search.placeholder_text = "Search a place in Kathmandu…"
	_search.size = Vector2(400, 36)
	_search.position = Vector2(w * 0.5 - 200, 10)
	_search.clear_button_enabled = true
	_search.text_changed.connect(_on_text_changed)
	add_child(_search)

	_results = VBoxContainer.new()
	_results.position = Vector2(w * 0.5 - 200, 50)
	_results.custom_minimum_size = Vector2(400, 0)
	add_child(_results)

	_nav_label = Label.new()
	_nav_label.add_theme_font_size_override("font_size", 22)
	_nav_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_nav_label.size = Vector2(500, 60)
	_nav_label.position = Vector2(w * 0.5 - 250, 100)
	_nav_label.visible = false
	add_child(_nav_label)

	_arrow = Label.new()
	_arrow.text = "▲"
	_arrow.add_theme_font_size_override("font_size", 64)
	_arrow.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	_arrow.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_arrow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_arrow.size = Vector2(80, 80)
	_arrow.pivot_offset = Vector2(40, 40)
	_arrow.position = Vector2(w * 0.5 - 40, 150)
	_arrow.visible = false
	add_child(_arrow)

func _on_text_changed(text: String) -> void:
	for c in _results.get_children():
		c.queue_free()
	var q := text.strip_edges().to_lower()
	if q.length() < 2 or _car == null:
		return
	var cx := _car.global_position.x
	var cz := _car.global_position.z
	var matches: Array = []
	for p in _places:
		if String(p["n"]).to_lower().contains(q):
			matches.append(p)
	matches.sort_custom(func(a, b): return _d2(a, cx, cz) < _d2(b, cx, cz))
	for i in range(mini(8, matches.size())):
		var p = matches[i]
		var btn := Button.new()
		btn.text = "%s   —   %s" % [p["n"], _fmt(sqrt(_d2(p, cx, cz)))]
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.pressed.connect(_set_dest.bind(p))
		_results.add_child(btn)

func _set_dest(p: Dictionary) -> void:
	_dest = Vector2(float(p["x"]), float(p["z"]))
	_dest_name = String(p["n"])
	_place_beacon(_dest.x, _dest.y)
	for c in _results.get_children():
		c.queue_free()
	_search.text = ""
	_search.release_focus()

func _place_beacon(x: float, z: float) -> void:
	if _beacon:
		_beacon.queue_free()
	if _world == null:
		return
	var mesh := CylinderMesh.new()
	mesh.top_radius = 4.0
	mesh.bottom_radius = 4.0
	mesh.height = 500.0
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.85, 0.2, 0.45)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.8, 0.1)
	mat.emission_energy_multiplier = 3.0
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh.material = mat
	_beacon = MeshInstance3D.new()
	_beacon.mesh = mesh
	_beacon.position = Vector3(x, 240.0, z)
	_world.add_child(_beacon)

func _process(_delta: float) -> void:
	if _dest == null or _car == null:
		return
	var dest: Vector2 = _dest
	var cp := _car.global_position
	var to := dest - Vector2(cp.x, cp.z)
	var dist := to.length()
	var fwd := -_car.global_transform.basis.z
	var right := _car.global_transform.basis.x
	var fwd2 := Vector2(fwd.x, fwd.z).normalized()
	var right2 := Vector2(right.x, right.z).normalized()
	var dir := to.normalized()
	var bearing := atan2(dir.dot(right2), dir.dot(fwd2))
	_arrow.rotation = bearing
	_arrow.visible = true
	_nav_label.visible = true
	if dist < 30.0:
		_nav_label.text = "Arrived at %s" % _dest_name
		_arrow.visible = false
	else:
		_nav_label.text = "%s\n%s" % [_dest_name, _fmt(dist)]

func _d2(p: Dictionary, cx: float, cz: float) -> float:
	var dx := float(p["x"]) - cx
	var dz := float(p["z"]) - cz
	return dx * dx + dz * dz

func _fmt(d: float) -> String:
	if d >= 1000.0:
		return "%.1f km" % (d / 1000.0)
	return "%d m" % int(d)
