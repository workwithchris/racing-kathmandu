extends Node3D
## Loads real OpenStreetMap data for central Kathmandu (res://data/kathmandu.json)
## and builds a drivable 3D city: a ground plane, asphalt roads, and the real
## building footprints extruded into solid blocks with collision.

@export var data_path := "res://data/kathmandu.json"
@export var car_path: NodePath
@export var camera_path: NodePath

func _ready() -> void:
	var f := FileAccess.open(data_path, FileAccess.READ)
	if f == null:
		push_error("Kathmandu map data not found at %s" % data_path)
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()

	var roads: Array = data.get("roads", [])
	var bounds := _bounds(data)
	_build_ground(bounds)
	_build_roads(roads)
	_build_buildings(data.get("buildings", []))
	_place_start(_central_spawn(roads, data.get("spawn", {})))

## Pick a spawn on a wide road as close to the map centre as possible, so the
## player starts inside the city rather than out at the fetched edge.
func _central_spawn(roads: Array, fallback: Dictionary) -> Dictionary:
	var best_d := INF
	var best := fallback
	for r in roads:
		if float(r["w"]) < 7.0:
			continue
		var pts: Array = r["p"]
		for i in range(pts.size() - 1):
			var p: Array = pts[i]
			var d: float = p[0] * p[0] + p[1] * p[1]
			if d < best_d:
				best_d = d
				var nx: Array = pts[i + 1]
				best = {"pos": [p[0], p[1]], "dir": [nx[0] - p[0], nx[1] - p[1]]}
	return best

# --- ground -----------------------------------------------------------------

func _bounds(data: Dictionary) -> Vector2:
	var ext := 200.0
	for r in data.get("roads", []):
		for p in r["p"]:
			ext = maxf(ext, maxf(absf(p[0]), absf(p[1])))
	return Vector2(ext, ext)

func _build_ground(bounds: Vector2) -> void:
	var size := (maxf(bounds.x, bounds.y) + 60.0) * 2.0
	var body := StaticBody3D.new()
	add_child(body)

	var mesh := PlaneMesh.new()
	mesh.size = Vector2(size, size)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.32, 0.31, 0.29)  # muted city ground
	mat.roughness = 1.0
	mesh.material = mat
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	body.add_child(mi)

	var shape := BoxShape3D.new()
	shape.size = Vector3(size, 1.0, size)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = Vector3(0, -0.5, 0)
	body.add_child(cs)

# --- roads (visual asphalt on the ground) -----------------------------------

func _build_roads(roads: Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y := 0.04
	for r in roads:
		var w: float = float(r["w"]) * 0.5
		var pts: Array = r["p"]
		for i in range(pts.size() - 1):
			var a := Vector3(pts[i][0], y, pts[i][1])
			var b := Vector3(pts[i + 1][0], y, pts[i + 1][1])
			var dir := b - a
			dir.y = 0.0
			if dir.length() < 0.01:
				continue
			dir = dir.normalized()
			var side := Vector3(dir.z, 0.0, -dir.x) * w
			_quad_up(st, a + side, a - side, b - side, b + side)
		# Square patch at each vertex to fill corner gaps at bends.
		for p in pts:
			var c := Vector3(p[0], y, p[1])
			var sx := Vector3(w, 0, 0)
			var sz := Vector3(0, 0, w)
			_quad_up(st, c - sx - sz, c + sx - sz, c + sx + sz, c - sx + sz)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.12, 0.13)
	mat.roughness = 0.95
	st.set_material(mat)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	add_child(mi)

# --- buildings (extruded footprints with collision) -------------------------

func _build_buildings(buildings: Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := PackedVector3Array()

	for bld in buildings:
		var pts: Array = bld["p"]
		var h: float = float(bld["h"])
		var n := pts.size()
		# Drop a duplicated closing vertex if present.
		if n > 1 and pts[0][0] == pts[n - 1][0] and pts[0][1] == pts[n - 1][1]:
			n -= 1
		if n < 3:
			continue
		var shade := 0.6 + 0.35 * _hash01(pts[0][0] + pts[0][1] * 7.0)
		var col := Color(shade, shade * 0.97, shade * 0.92)

		# Walls.
		for i in range(n):
			var p0: Array = pts[i]
			var p1: Array = pts[(i + 1) % n]
			var a0 := Vector3(p0[0], 0.0, p0[1])
			var b0 := Vector3(p1[0], 0.0, p1[1])
			if a0.distance_to(b0) < 0.05:
				continue
			var at := a0 + Vector3.UP * h
			var bt := b0 + Vector3.UP * h
			_tri(st, faces, col, a0, at, bt)
			_tri(st, faces, col, a0, bt, b0)

		# Flat roof via 2D triangulation of the footprint.
		var poly := PackedVector2Array()
		for i in range(n):
			poly.append(Vector2(pts[i][0], pts[i][1]))
		var idx := Geometry2D.triangulate_polygon(poly)
		for k in range(0, idx.size(), 3):
			var ra := Vector3(poly[idx[k]].x, h, poly[idx[k]].y)
			var rb := Vector3(poly[idx[k + 1]].x, h, poly[idx[k + 1]].y)
			var rc := Vector3(poly[idx[k + 2]].x, h, poly[idx[k + 2]].y)
			_tri(st, faces, col, ra, rb, rc)

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
	st.generate_normals()

	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	add_child(mi)

	var body := StaticBody3D.new()
	add_child(body)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)

# --- helpers ----------------------------------------------------------------

func _quad_up(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)

func _tri(st: SurfaceTool, faces: PackedVector3Array, col: Color, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_color(col); st.add_vertex(a)
	st.set_color(col); st.add_vertex(b)
	st.set_color(col); st.add_vertex(c)
	faces.push_back(a); faces.push_back(b); faces.push_back(c)

func _hash01(v: float) -> float:
	var s := sin(v * 12.9898) * 43758.5453
	return s - floor(s)

func _place_start(spawn: Dictionary) -> void:
	if spawn.is_empty():
		return
	var pos := Vector3(spawn["pos"][0], 1.0, spawn["pos"][1])
	var travel := Vector3(spawn["dir"][0], 0.0, spawn["dir"][1]).normalized()
	var car := get_node_or_null(car_path)
	if car is Node3D:
		var z_axis := -travel  # car drives nose-first (-Z)
		var x_axis := Vector3.UP.cross(z_axis).normalized()
		car.global_transform = Transform3D(Basis(x_axis, Vector3.UP, z_axis), pos)
		if "linear_velocity" in car:
			car.linear_velocity = Vector3.ZERO
			car.angular_velocity = Vector3.ZERO
		var cam := get_node_or_null(camera_path)
		if cam is Node3D:
			cam.global_position = pos + z_axis * 8.0 + Vector3.UP * 4.0
