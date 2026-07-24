extends Node3D
## Loads real OpenStreetMap + SRTM data for central Kathmandu and builds a
## drivable, decent-looking 3D city on real terrain: heightmapped ground, parks,
## asphalt roads with lane markings, windowed buildings, and instanced trees.

@export var data_path := "res://data/kathmandu.json"
@export var car_path: NodePath
@export var camera_path: NodePath
## Vertical exaggeration for the terrain (1.0 = true-to-life).
@export var height_scale := 1.0
## Pedestrian NPC scene spawned along roads.
@export var npc_scene: PackedScene
@export var npc_count := 80
## Traffic vehicle scene spawned driving along roads.
@export var traffic_scene: PackedScene
@export var traffic_count := 40

const BUILDING_SHADER := preload("res://shaders/building.gdshader")
const ROAD_SHADER := preload("res://shaders/road.gdshader")

# Kathmandu-ish painted-house / brick palette: earthy, warm, colourful.
const PALETTE := [
	Color(0.74, 0.30, 0.23),  # brick red / terracotta
	Color(0.82, 0.60, 0.28),  # ochre / mustard
	Color(0.86, 0.79, 0.62),  # cream
	Color(0.52, 0.66, 0.68),  # dusty teal
	Color(0.80, 0.54, 0.55),  # dusty pink
	Color(0.60, 0.65, 0.50),  # sage / olive
	Color(0.66, 0.72, 0.82),  # pale blue
	Color(0.76, 0.72, 0.65),  # weathered concrete
	Color(0.66, 0.38, 0.40),  # maroon
	Color(0.84, 0.72, 0.42),  # turmeric yellow
]

var _nx := 0
var _nz := 0
var _minx := 0.0
var _maxx := 0.0
var _minz := 0.0
var _maxz := 0.0
var _h := PackedFloat32Array()
var _hmax := 1.0

func _ready() -> void:
	var f := FileAccess.open(data_path, FileAccess.READ)
	if f == null:
		push_error("Kathmandu map data not found at %s" % data_path)
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()

	_load_terrain(data.get("terrain", {}))
	var roads: Array = data.get("roads", [])
	_build_terrain()
	_build_greens(data.get("greens", []))
	_build_curbs(roads)
	_build_roads(roads)
	_build_markings(roads)
	_build_buildings(data.get("buildings", []))
	_build_trees(data.get("trees", []))
	_place_start(_central_spawn(roads))
	_spawn_npcs(roads)
	_spawn_traffic(roads)

# --- terrain heightmap ------------------------------------------------------

func _load_terrain(t: Dictionary) -> void:
	if t.is_empty():
		return
	_nx = int(t["nx"]); _nz = int(t["nz"])
	_minx = float(t["minx"]); _maxx = float(t["maxx"])
	_minz = float(t["minz"]); _maxz = float(t["maxz"])
	for v in t["h"]:
		_h.append(float(v) * height_scale)
	for v in _h:
		_hmax = maxf(_hmax, v)

## Public height query wrapper used by other systems (NPCs, etc.).
func height_at(x: float, z: float) -> float:
	return _height_at(x, z)

## Height sampled with the SAME triangle split as the terrain mesh (a,b,c)/(a,c,d),
## so draped roads/buildings sit exactly on the rendered surface (not buried).
func _height_at(x: float, z: float) -> float:
	if _nx == 0:
		return 0.0
	var fx := clampf((x - _minx) / (_maxx - _minx), 0.0, 1.0) * float(_nx - 1)
	var fz := clampf((z - _minz) / (_maxz - _minz), 0.0, 1.0) * float(_nz - 1)
	var j0 := mini(int(floor(fx)), _nx - 2)
	var i0 := mini(int(floor(fz)), _nz - 2)
	var tx := fx - j0
	var tz := fz - i0
	var ha := _h[i0 * _nx + j0]
	var hb := _h[i0 * _nx + j0 + 1]
	var hc := _h[(i0 + 1) * _nx + j0 + 1]
	var hd := _h[(i0 + 1) * _nx + j0]
	if tz <= tx:
		return ha + (hb - ha) * tx + (hc - hb) * tz
	return ha + (hc - hd) * tx + (hd - ha) * tz

func _grid_pos(i: int, j: int) -> Vector3:
	var x := _minx + (_maxx - _minx) * float(j) / float(_nx - 1)
	var z := _minz + (_maxz - _minz) * float(i) / float(_nz - 1)
	return Vector3(x, _h[i * _nx + j], z)

func _build_terrain() -> void:
	if _nx == 0:
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := PackedVector3Array()
	var low := Color(0.36, 0.34, 0.30)
	var high := Color(0.31, 0.44, 0.25)
	for i in range(_nz - 1):
		for j in range(_nx - 1):
			var a := _grid_pos(i, j)
			var b := _grid_pos(i, j + 1)
			var c := _grid_pos(i + 1, j + 1)
			var d := _grid_pos(i + 1, j)
			var col := low.lerp(high, a.y / _hmax)
			_ctri(st, faces, col, a, b, c)
			_ctri(st, faces, col, a, c, d)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	st.set_material(mat)
	st.generate_normals()
	_add_mesh(st.commit())

	var body := StaticBody3D.new()
	add_child(body)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)

# --- parks / green areas ----------------------------------------------------

func _build_greens(greens: Array) -> void:
	if greens.is_empty():
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var grass := Color(0.33, 0.5, 0.26)
	for g in greens:
		var pts: Array = g["p"]
		var n := pts.size()
		if n > 1 and pts[0][0] == pts[n - 1][0] and pts[0][1] == pts[n - 1][1]:
			n -= 1
		if n < 3 or n > 60:
			continue
		var poly := PackedVector2Array()
		for i in range(n):
			poly.append(Vector2(pts[i][0], pts[i][1]))
		var idx := Geometry2D.triangulate_polygon(poly)
		for k in range(0, idx.size(), 3):
			var p := [poly[idx[k]], poly[idx[k + 1]], poly[idx[k + 2]]]
			for q in p:
				st.set_color(grass)
				st.add_vertex(Vector3(q.x, _height_at(q.x, q.y) + 0.07, q.y))
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	st.set_material(mat)
	st.generate_normals()
	_add_mesh(st.commit())

# --- roads + lane markings --------------------------------------------------

func _build_curbs(roads: Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in roads:
		var hw: float = float(r["w"]) * 0.5 + 0.8
		_ribbon(st, r["p"], hw, 0.06)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.5, 0.5, 0.52)  # concrete sidewalk / curb
	mat.roughness = 0.95
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
	st.generate_normals()
	_add_mesh(st.commit())

func _build_roads(roads: Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in roads:
		_ribbon(st, r["p"], float(r["w"]) * 0.5, 0.11)
	var mat := ShaderMaterial.new()
	mat.shader = ROAD_SHADER
	mat.set_shader_parameter("asphalt_tex", _asphalt_texture())
	mat.set_shader_parameter("uv_scale", Vector2(0.3, 0.3))
	st.set_material(mat)
	st.generate_normals()
	_add_mesh(st.commit())

## A continuous road/curb ribbon. Each segment is subdivided into short steps that
## each follow the terrain height (so the road hugs the ground instead of chording
## over hills and getting buried), and extended by its half-width at both ends so
## consecutive segments overlap and fill joints/intersections cleanly.
func _ribbon(st: SurfaceTool, pts: Array, hw: float, yoff: float) -> void:
	for i in range(pts.size() - 1):
		var ax: float = pts[i][0]
		var az: float = pts[i][1]
		var dx: float = pts[i + 1][0] - ax
		var dz: float = pts[i + 1][1] - az
		var L := sqrt(dx * dx + dz * dz)
		if L < 0.01:
			continue
		var ux := dx / L
		var uz := dz / L
		var sx := uz * hw   # perpendicular offset (road side)
		var sz := -ux * hw
		var start := -hw
		var stop := L + hw
		var n := int(ceil((stop - start) / 4.0))
		var step := (stop - start) / n
		var d := start
		var px := ax + ux * d
		var pz := az + uz * d
		var py := _height_at(px, pz) + yoff
		for k in range(n):
			var d2 := d + step
			var qx := ax + ux * d2
			var qz := az + uz * d2
			var qy := _height_at(qx, qz) + yoff
			_quad(st,
				Vector3(px + sx, py, pz + sz), Vector3(px - sx, py, pz - sz),
				Vector3(qx - sx, qy, qz - sz), Vector3(qx + sx, qy, qz + sz))
			d = d2; px = qx; pz = qz; py = qy

func _asphalt_texture() -> ImageTexture:
	var s := 64
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGB8)
	for y in range(s):
		for x in range(s):
			var n := 0.82 + 0.18 * _hash01(float(x) * 1.7 + float(y) * 2.3)
			img.set_pixel(x, y, Color(n, n, n * 1.02))
	return ImageTexture.create_from_image(img)

func _build_markings(roads: Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dash := 2.5
	var gap := 3.5
	var period := dash + gap
	var mw := 0.16
	for r in roads:
		if float(r["w"]) < 7.0:
			continue
		var pts: Array = r["p"]
		var phase := 0.0
		for i in range(pts.size() - 1):
			var ax: float = pts[i][0]
			var az: float = pts[i][1]
			var ux: float = pts[i + 1][0] - ax
			var uz: float = pts[i + 1][1] - az
			var L := sqrt(ux * ux + uz * uz)
			if L < 0.01:
				continue
			ux /= L; uz /= L
			var side := Vector3(uz, 0.0, -ux) * mw
			var d := 0.0
			while d < L:
				var pos_in := fmod(phase + d, period)
				if pos_in < dash:
					var e: float = minf(d + (dash - pos_in), L)
					var p0 := _mark_pt(ax, az, ux, uz, d)
					var p1 := _mark_pt(ax, az, ux, uz, e)
					_quad(st, p0 + side, p0 - side, p1 - side, p1 + side)
					d = e
				else:
					d += period - pos_in
			phase = fmod(phase + L, period)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.9, 0.5)
	mat.roughness = 0.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
	st.generate_normals()
	_add_mesh(st.commit())

func _mark_pt(ax: float, az: float, ux: float, uz: float, d: float) -> Vector3:
	var x := ax + ux * d
	var z := az + uz * d
	return Vector3(x, _height_at(x, z) + 0.15, z)

# --- buildings (windowed walls + flat roofs) --------------------------------

func _build_buildings(buildings: Array) -> void:
	var walls := SurfaceTool.new()
	walls.begin(Mesh.PRIMITIVE_TRIANGLES)
	var roofs := SurfaceTool.new()
	roofs.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := PackedVector3Array()

	for bld in buildings:
		var pts: Array = bld["p"]
		var height: float = float(bld["h"])
		var n := pts.size()
		if n > 1 and pts[0][0] == pts[n - 1][0] and pts[0][1] == pts[n - 1][1]:
			n -= 1
		if n < 3:
			continue
		var base := INF
		for i in range(n):
			base = minf(base, _height_at(pts[i][0], pts[i][1]))
		base -= 0.5
		var top := base + height
		var seed: float = pts[0][0] + pts[0][1] * 7.0
		var col: Color = PALETTE[int(_hash01(seed) * PALETTE.size()) % PALETTE.size()]
		col = col.lerp(Color(0.5, 0.5, 0.5), 0.05 * _hash01(seed * 3.1))
		var roof_col := col.darkened(0.4)

		for i in range(n):
			var p0: Array = pts[i]
			var p1: Array = pts[(i + 1) % n]
			var a0 := Vector3(p0[0], base, p0[1])
			var b0 := Vector3(p1[0], base, p1[1])
			if a0.distance_to(b0) < 0.05:
				continue
			var at := Vector3(p0[0], top, p0[1])
			var bt := Vector3(p1[0], top, p1[1])
			_wall_tri(walls, faces, col, a0, at, bt, base, top)
			_wall_tri(walls, faces, col, a0, bt, b0, base, top)
			# Reversed-winding collision faces too: walls are a single zero-thickness
			# sheet, so a body that tunnels through at high speed needs a normal
			# facing the OTHER way as well, or physics has no way to push it back out.
			faces.push_back(a0); faces.push_back(bt); faces.push_back(at)
			faces.push_back(a0); faces.push_back(b0); faces.push_back(bt)

		if n <= 12:
			var poly := PackedVector2Array()
			for i in range(n):
				poly.append(Vector2(pts[i][0], pts[i][1]))
			var idx := Geometry2D.triangulate_polygon(poly)
			for k in range(0, idx.size(), 3):
				for m in [k, k + 1, k + 2]:
					roofs.set_color(roof_col)
					roofs.add_vertex(Vector3(poly[idx[m]].x, top, poly[idx[m]].y))

	var wall_mat := ShaderMaterial.new()
	wall_mat.shader = BUILDING_SHADER
	wall_mat.set_shader_parameter("window_tex", _window_texture())
	wall_mat.set_shader_parameter("uv_scale", Vector3(0.125, 0.125, 0.125))
	walls.set_material(wall_mat)
	walls.generate_normals()
	_add_mesh(walls.commit())

	var roof_mat := StandardMaterial3D.new()
	roof_mat.vertex_color_use_as_albedo = true
	roof_mat.roughness = 0.95
	roofs.set_material(roof_mat)
	roofs.generate_normals()
	_add_mesh(roofs.commit())

	var body := StaticBody3D.new()
	add_child(body)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)

# --- trees (instanced crossed billboards) -----------------------------------

func _build_trees(trees: Array) -> void:
	if trees.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _tree_mesh()
	mm.instance_count = trees.size()
	var faces := PackedVector3Array()
	for i in range(trees.size()):
		var t: Array = trees[i]
		var x: float = t[0]
		var z: float = t[1]
		var s: float = t[2] if t.size() > 2 else 1.0
		var basis := Basis(Vector3.UP, _hash01(x + z) * TAU).scaled(Vector3(s, s, s))
		var y := _height_at(x, z)
		mm.set_instance_transform(i, Transform3D(basis, Vector3(x, y, z)))
		_add_trunk_collision(faces, x, y, z, 0.45 * s, 3.0 * s)
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)

	var body := StaticBody3D.new()
	add_child(body)
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)

## Adds an axis-aligned box (double-sided, so it can't be tunnelled through and
## always has a valid push-out normal) as a trunk obstacle for one tree.
func _add_trunk_collision(faces: PackedVector3Array, x: float, y: float, z: float, hw: float, h: float) -> void:
	var corners: Array[Vector3] = [
		Vector3(x - hw, y, z - hw), Vector3(x + hw, y, z - hw),
		Vector3(x + hw, y, z + hw), Vector3(x - hw, y, z + hw),
	]
	for i in range(4):
		var a := corners[i]
		var b := corners[(i + 1) % 4]
		var at := a + Vector3.UP * h
		var bt := b + Vector3.UP * h
		faces.push_back(a); faces.push_back(at); faces.push_back(bt)
		faces.push_back(a); faces.push_back(bt); faces.push_back(b)
		faces.push_back(a); faces.push_back(bt); faces.push_back(at)
		faces.push_back(a); faces.push_back(b); faces.push_back(bt)

func _tree_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var w := 2.6
	var h := 5.2
	# Two crossed vertical quads so the tree reads from any angle.
	_billboard(st, Vector3(-w, 0, 0), Vector3(w, 0, 0), Vector3(w, h, 0), Vector3(-w, h, 0))
	_billboard(st, Vector3(0, 0, -w), Vector3(0, 0, w), Vector3(0, h, w), Vector3(0, h, -w))
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _tree_texture()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.5
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.roughness = 1.0
	st.set_material(mat)
	st.generate_normals()
	return st.commit()

func _billboard(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.set_uv(Vector2(0, 1)); st.add_vertex(a)
	st.set_uv(Vector2(1, 1)); st.add_vertex(b)
	st.set_uv(Vector2(1, 0)); st.add_vertex(c)
	st.set_uv(Vector2(0, 1)); st.add_vertex(a)
	st.set_uv(Vector2(1, 0)); st.add_vertex(c)
	st.set_uv(Vector2(0, 0)); st.add_vertex(d)

# --- procedural textures ----------------------------------------------------

## RGB = wall/frame/glass colour. A = 1.0 on glass pixels only, used by
## building.gdshader as a mask for per-window specular/emission variation.
func _window_texture() -> ImageTexture:
	var s := 128
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGBA8)
	var wall := Color(0.92, 0.90, 0.86)
	var glass := Color(0.16, 0.19, 0.24)   # darker glass reads as real windows
	var frame := Color(0.55, 0.52, 0.48)
	var band := Color(0.70, 0.67, 0.62)    # floor slab between storeys
	for y in range(s):
		for x in range(s):
			var cx := x % 32
			var cy := y % 32
			var col := wall
			var is_glass := false
			if cy < 4:
				col = band
			elif cx >= 9 and cx <= 23 and cy >= 9 and cy <= 26:
				# small window with a frame border and a central mullion
				if cx == 9 or cx == 23 or cy == 9 or cy == 26 or cx == 16:
					col = frame
				else:
					col = glass
					is_glass = true
			img.set_pixel(x, y, Color(col.r, col.g, col.b, 1.0 if is_glass else 0.0))
	return ImageTexture.create_from_image(img)

func _tree_texture() -> ImageTexture:
	var s := 128
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGBA8)
	var clear := Color(0, 0, 0, 0)
	var trunk := Color(0.36, 0.24, 0.14, 1.0)
	var cx := 64.0
	var cy := 46.0
	var rad := 44.0
	for y in range(s):
		for x in range(s):
			var col := clear
			# trunk
			if x >= 58 and x <= 70 and y >= 74 and y <= 128:
				col = trunk
			# canopy blob with ragged edge + shaded greens
			var dx := x - cx
			var dy := (y - cy) * 1.15
			var dist := sqrt(dx * dx + dy * dy)
			var edge := rad * (0.82 + 0.18 * _hash01(float(x) * 0.7 + float(y) * 1.3))
			if dist < edge:
				var shade := 0.55 + 0.45 * (1.0 - dist / rad) + 0.12 * _hash01(float(x) * 2.1 + float(y))
				col = Color(0.16 * shade, 0.42 * shade, 0.15 * shade, 1.0)
			img.set_pixel(x, y, col)
	return ImageTexture.create_from_image(img)

# --- helpers ----------------------------------------------------------------

func _add_mesh(mesh: Mesh) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
	st.add_vertex(a); st.add_vertex(c); st.add_vertex(d)

func _ctri(st: SurfaceTool, faces: PackedVector3Array, col: Color, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.set_color(col); st.add_vertex(a)
	st.set_color(col); st.add_vertex(b)
	st.set_color(col); st.add_vertex(c)
	faces.push_back(a); faces.push_back(b); faces.push_back(c)

## Same as _ctri but stows each vertex's 0..1 base-to-roof height fraction in
## COLOR.a, which building.gdshader reads to fade grime/AO in toward the base.
func _wall_tri(st: SurfaceTool, faces: PackedVector3Array, col: Color, a: Vector3, b: Vector3, c: Vector3, base: float, top: float) -> void:
	var span := maxf(top - base, 0.001)
	st.set_color(Color(col.r, col.g, col.b, clampf((a.y - base) / span, 0.0, 1.0))); st.add_vertex(a)
	st.set_color(Color(col.r, col.g, col.b, clampf((b.y - base) / span, 0.0, 1.0))); st.add_vertex(b)
	st.set_color(Color(col.r, col.g, col.b, clampf((c.y - base) / span, 0.0, 1.0))); st.add_vertex(c)
	faces.push_back(a); faces.push_back(b); faces.push_back(c)

func _hash01(v: float) -> float:
	var q := sin(v * 12.9898) * 43758.5453
	return q - floor(q)

func _central_spawn(roads: Array) -> Dictionary:
	var best_d := INF
	var best := {}
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

func _place_start(spawn: Dictionary) -> void:
	if spawn.is_empty():
		return
	var x: float = spawn["pos"][0]
	var z: float = spawn["pos"][1]
	var pos := Vector3(x, _height_at(x, z) + 1.0, z)
	var travel := Vector3(spawn["dir"][0], 0.0, spawn["dir"][1]).normalized()
	var car := get_node_or_null(car_path)
	if car is Node3D:
		var z_axis := -travel
		var x_axis := Vector3.UP.cross(z_axis).normalized()
		car.global_transform = Transform3D(Basis(x_axis, Vector3.UP, z_axis), pos)
		if "linear_velocity" in car:
			car.linear_velocity = Vector3.ZERO
			car.angular_velocity = Vector3.ZERO
		var cam := get_node_or_null(camera_path)
		if cam is Node3D:
			cam.global_position = pos + z_axis * 8.0 + Vector3.UP * 4.0

func _spawn_npcs(roads: Array) -> void:
	if npc_scene == null:
		return
	randomize()
	var container := Node3D.new()
	container.name = "NPCs"
	add_child(container)
	var candidates: Array = []
	for r in roads:
		if float(r.get("w", 0.0)) >= 5.0 and r["p"].size() >= 2:
			candidates.append(r)
	if candidates.is_empty():
		return
	var spawned := 0
	var attempts := 0
	var max_attempts := npc_count * 4
	while spawned < npc_count and attempts < max_attempts:
		attempts += 1
		var r: Dictionary = candidates[randi() % candidates.size()]
		var pts: Array = r["p"]
		var idx := randi() % (pts.size() - 1)
		var ax: float = pts[idx][0]
		var az: float = pts[idx][1]
		var bx: float = pts[idx + 1][0]
		var bz: float = pts[idx + 1][1]
		var dx := bx - ax
		var dz := bz - az
		var L := sqrt(dx * dx + dz * dz)
		if L < 1.0:
			continue
		var ux := dx / L
		var uz := dz / L
		var sx := uz
		var sz := -ux
		if randf() < 0.5:
			sx = -sx
			sz = -sz
		var hw := float(r["w"]) * 0.5 + 0.8
		var off := hw + 1.0
		var ya := height_at(ax + sx * off, az + sz * off)
		var yb := height_at(bx + sx * off, bz + sz * off)
		var npc = npc_scene.instantiate()
		npc.target_a = Vector3(ax + sx * off, ya, az + sz * off)
		npc.target_b = Vector3(bx + sx * off, yb, bz + sz * off)
		container.add_child(npc)
		npc.position = npc.target_a
		spawned += 1

# --- traffic vehicles --------------------------------------------------------

func _spawn_traffic(roads: Array) -> void:
	if traffic_scene == null:
		return
	var container := Node3D.new()
	container.name = "Traffic"
	add_child(container)
	var candidates: Array = []
	for r in roads:
		if float(r.get("w", 0.0)) >= 6.0 and r["p"].size() >= 2:
			candidates.append(r)
	if candidates.is_empty():
		return
	var spawned := 0
	var attempts := 0
	var max_attempts := traffic_count * 4
	while spawned < traffic_count and attempts < max_attempts:
		attempts += 1
		var r: Dictionary = candidates[randi() % candidates.size()]
		var lane := _lane_path(r, randf() < 0.5)
		if lane.size() < 2:
			continue
		var car = traffic_scene.instantiate()
		car.path = lane
		car.speed = randf_range(4.0, 9.0)
		container.add_child(car)
		car.global_position = lane[0]
		spawned += 1

## Builds a lane-offset waypoint path (draped onto the terrain) that follows one
## side of a road's full centerline, so traffic drives along real streets rather
## than a single straight segment.
func _lane_path(r: Dictionary, side_positive: bool) -> PackedVector3Array:
	var pts: Array = r["p"]
	var hw: float = float(r["w"]) * 0.5
	var lane_off: float = maxf(hw * 0.5, 1.2)
	var out := PackedVector3Array()
	var n := pts.size()
	for i in range(n):
		var ax: float = pts[i][0]
		var az: float = pts[i][1]
		var dx: float
		var dz: float
		if i < n - 1:
			dx = pts[i + 1][0] - ax
			dz = pts[i + 1][1] - az
		else:
			dx = ax - pts[i - 1][0]
			dz = az - pts[i - 1][1]
		var L := sqrt(dx * dx + dz * dz)
		if L < 0.01:
			continue
		var ux := dx / L
		var uz := dz / L
		var sx := uz
		var sz := -ux
		if not side_positive:
			sx = -sx
			sz = -sz
		var ox := ax + sx * lane_off
		var oz := az + sz * lane_off
		out.append(Vector3(ox, _height_at(ox, oz) + 0.05, oz))
	return out
