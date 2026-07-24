extends Node3D
## Streams the whole Kathmandu Valley in around the car. A single global
## terrain (+ ocean/skirt) is built once from data/terrain.json; buildings,
## roads, trees, greens, NPCs and traffic are loaded/unloaded per ~1km chunk
## (data/chunks/{cx}_{cz}.json) as the car moves, off the main thread, so the
## whole valley never has to exist in memory or as one mesh at once.
## Beyond the fetched valley data, a terrain skirt slopes down to a flat ocean
## plane so the map never shows a visible edge.

@export var manifest_path := "res://data/manifest.json"
@export var car_path: NodePath
@export var camera_path: NodePath
## Vertical exaggeration for the terrain (1.0 = true-to-life).
@export var height_scale := 1.0
## Pedestrian NPC scene spawned along roads.
@export var npc_scene: PackedScene
## Traffic vehicle scene spawned driving along roads.
@export var traffic_scene: PackedScene

## Streaming tuning.
@export var load_radius := 900.0
@export var unload_radius := 1400.0
@export var stream_interval := 0.5
@export var npcs_per_chunk := 3
@export var traffic_per_chunk := 2

## Ocean / terrain-skirt tuning.
@export var ocean_extent := 40000.0
@export var skirt_falloff := 1500.0
@export var sea_level_offset := -6.0

const BUILDING_SHADER := preload("res://shaders/building.gdshader")
const ROAD_SHADER := preload("res://shaders/road.gdshader")
const OCEAN_SHADER := preload("res://shaders/ocean.gdshader")

## Real building asset scattered in as a landmark prop on a random eligible
## footprint per chunk (not a full replacement for the procedural city --
## this is a fixed model, so it can't deform to arbitrary OSM footprints).
## It's a placeholder ("Futuristic Building" by 3DHaupt, CC-BY-NC) standing in
## until the intended old-town-style models are swapped in.
const PROP_BUILDING_SCENE := preload("res://assets/building.glb")
## Rough guess at the source model's native footprint/height in metres --
## no display access to eyeball this, so tune by looking at it in-editor.
const PROP_NATIVE_SIZE := Vector3(10.0, 15.0, 10.0)
## Fraction of chunks (with an eligible building) that get the prop, so
## concurrently-loaded instances stay bounded regardless of map size.
const PROP_CHANCE := 0.2

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

var _chunk_size := 1000.0
var _car: Node3D

# Terrain (global, shared, read-only once built -- safe to read from worker threads).
var _nx := 0
var _nz := 0
var _minx := 0.0
var _maxx := 0.0
var _minz := 0.0
var _maxz := 0.0
var _h := PackedFloat32Array()
var _hmax := 1.0

# Shared procedural textures/meshes, built once so per-chunk loads don't redo the work.
var _window_tex: ImageTexture
var _asphalt_tex: ImageTexture
var _tree_mesh_res: ArrayMesh

# Streaming state.
var _loaded: Dictionary = {}    # Vector2i -> Node3D chunk container
var _pending: Dictionary = {}   # Vector2i -> true (in-flight async load)
var _stream_timer := 0.0

func _ready() -> void:
	_car = get_node_or_null(car_path)

	var mf := FileAccess.open(manifest_path, FileAccess.READ)
	if mf == null:
		push_error("Kathmandu manifest not found at %s" % manifest_path)
		return
	var manifest: Dictionary = JSON.parse_string(mf.get_as_text())
	mf.close()
	_chunk_size = float(manifest.get("chunk_size", 1000.0))

	_window_tex = _window_texture()
	_asphalt_tex = _asphalt_texture()
	_tree_mesh_res = _tree_mesh()

	_load_terrain(String(manifest.get("terrain", "res://data/terrain.json")))
	_build_terrain()
	_build_ocean_and_skirt()

	# Force-load a block of chunks around the origin synchronously, so there's
	# a spawn point and immediate surroundings ready before the player appears.
	var initial_roads: Array = []
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var data: Variant = _load_chunk_sync(Vector2i(dx, dz))
			if data != null:
				initial_roads.append_array(data.get("roads", []))
	_place_start(_central_spawn(initial_roads))

func _process(delta: float) -> void:
	if _car == null:
		return
	_stream_timer -= delta
	if _stream_timer <= 0.0:
		_stream_timer = stream_interval
		_update_streaming()

# --- chunk streaming ---------------------------------------------------------

func _coord_at(x: float, z: float) -> Vector2i:
	return Vector2i(int(floor(x / _chunk_size)), int(floor(z / _chunk_size)))

func _chunk_center(c: Vector2i) -> Vector2:
	return Vector2((c.x + 0.5) * _chunk_size, (c.y + 0.5) * _chunk_size)

func _update_streaming() -> void:
	var cp := _car.global_position
	var car_coord := _coord_at(cp.x, cp.z)
	var r := int(ceil(load_radius / _chunk_size)) + 1

	for dz in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var c := car_coord + Vector2i(dx, dz)
			if _loaded.has(c) or _pending.has(c):
				continue
			var center := _chunk_center(c)
			if Vector2(center.x - cp.x, center.y - cp.z).length() <= load_radius:
				_load_chunk_async(c)

	for c in _loaded.keys():
		var center := _chunk_center(c)
		if Vector2(center.x - cp.x, center.y - cp.z).length() > unload_radius:
			_unload_chunk(c)

func _load_chunk_sync(coord: Vector2i) -> Variant:
	if _loaded.has(coord):
		return null
	var path := "res://data/chunks/%d_%d.json" % [coord.x, coord.y]
	if not FileAccess.file_exists(path):
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var built := _build_chunk_meshes(data, coord)
	_attach_chunk(coord, built)
	return data

func _load_chunk_async(coord: Vector2i) -> void:
	var path := "res://data/chunks/%d_%d.json" % [coord.x, coord.y]
	if not FileAccess.file_exists(path):
		return
	_pending[coord] = true
	WorkerThreadPool.add_task(_build_chunk_task.bind(coord, path))

func _build_chunk_task(coord: Vector2i, path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		call_deferred("_finish_async_chunk", coord, {})
		return
	var data: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
	var built := _build_chunk_meshes(data, coord)
	call_deferred("_finish_async_chunk", coord, built)

func _finish_async_chunk(coord: Vector2i, built: Dictionary) -> void:
	_pending.erase(coord)
	if built.is_empty() or _loaded.has(coord):
		return
	_attach_chunk(coord, built)

func _unload_chunk(coord: Vector2i) -> void:
	var node = _loaded.get(coord)
	if node:
		node.queue_free()
	_loaded.erase(coord)

func _attach_chunk(coord: Vector2i, built: Dictionary) -> void:
	if built.is_empty():
		return
	var root := Node3D.new()
	root.name = "Chunk_%d_%d" % [coord.x, coord.y]
	add_child(root)

	for key in ["walls_mesh", "roofs_mesh", "curbs_mesh", "roads_mesh", "markings_mesh", "greens_mesh"]:
		var mesh: Mesh = built.get(key)
		if mesh != null:
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			root.add_child(mi)

	var mm: MultiMesh = built.get("tree_multimesh")
	if mm != null:
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(mmi)

	var faces: PackedVector3Array = built.get("collision_faces", PackedVector3Array())
	if faces.size() > 0:
		var body := StaticBody3D.new()
		root.add_child(body)
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(faces)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)

	var prop: Variant = built.get("prop")
	if prop != null:
		var inst := PROP_BUILDING_SCENE.instantiate()
		if inst is Node3D:
			root.add_child(inst)
			inst.position = prop["pos"]
			inst.scale = prop["scale"]
		else:
			inst.queue_free()

	_spawn_npcs_for_chunk(root, built.get("npc_spawns", []))
	_spawn_traffic_for_chunk(root, built.get("traffic_paths", []))

	_loaded[coord] = root

# --- per-chunk mesh building (thread-safe: only touches its own locals plus
# read-only terrain/texture fields set up once before streaming starts) -------

func _build_chunk_meshes(data: Dictionary, coord: Vector2i) -> Dictionary:
	var result := {}
	var faces := PackedVector3Array()
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(coord)

	var wb := _build_buildings_mesh(data.get("buildings", []), faces, rng)
	result["walls_mesh"] = wb.get("walls")
	result["roofs_mesh"] = wb.get("roofs")
	result["prop"] = wb.get("prop")

	var roads: Array = data.get("roads", [])
	result["curbs_mesh"] = _build_curbs_mesh(roads)
	result["roads_mesh"] = _build_roads_mesh(roads)
	result["markings_mesh"] = _build_markings_mesh(roads)
	result["greens_mesh"] = _build_greens_mesh(data.get("greens", []))

	var trees: Array = data.get("trees", [])
	if not trees.is_empty():
		result["tree_multimesh"] = _build_trees_multimesh(trees, faces)

	result["collision_faces"] = faces
	result["npc_spawns"] = _npc_spawn_points(roads, rng)
	result["traffic_paths"] = _traffic_lane_paths(roads, rng)
	return result

func _build_buildings_mesh(buildings: Array, faces: PackedVector3Array, rng: RandomNumberGenerator) -> Dictionary:
	if buildings.is_empty():
		return {}
	var walls := SurfaceTool.new()
	walls.begin(Mesh.PRIMITIVE_TRIANGLES)
	var roofs := SurfaceTool.new()
	roofs.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any_roof := false

	# Pick at most one eligible (simple-footprint) building in this chunk to
	# swap for the real prop model instead of procedural extrusion.
	var prop_index := -1
	if rng.randf() < PROP_CHANCE:
		var best_area := 0.0
		for bi in range(buildings.size()):
			var bpts: Array = buildings[bi]["p"]
			var bn := bpts.size()
			if bn > 1 and bpts[0][0] == bpts[bn - 1][0] and bpts[0][1] == bpts[bn - 1][1]:
				bn -= 1
			if bn < 3 or bn > 12:
				continue
			var area := _poly_area2(bpts, bn)
			if area > best_area:
				best_area = area
				prop_index = bi
	var prop_info: Variant = null

	for bidx in range(buildings.size()):
		var bld: Dictionary = buildings[bidx]
		var pts: Array = bld["p"]
		var height: float = float(bld["h"])
		var n := pts.size()
		if n > 1 and pts[0][0] == pts[n - 1][0] and pts[0][1] == pts[n - 1][1]:
			n -= 1
		if n < 3:
			continue
		if bidx == prop_index:
			var pminx := INF; var pmaxx := -INF; var pminz := INF; var pmaxz := -INF
			var sumx := 0.0; var sumz := 0.0
			for i in range(n):
				var px: float = pts[i][0]
				var pz: float = pts[i][1]
				pminx = minf(pminx, px); pmaxx = maxf(pmaxx, px)
				pminz = minf(pminz, pz); pmaxz = maxf(pmaxz, pz)
				sumx += px; sumz += pz
			var pcx := sumx / n
			var pcz := sumz / n
			var pbase := _height_at(pcx, pcz)
			var pwidth := pmaxx - pminx
			var pdepth := pmaxz - pminz
			var pscale := Vector3(
				clampf(pwidth / PROP_NATIVE_SIZE.x, 0.4, 3.0),
				clampf(height / PROP_NATIVE_SIZE.y, 0.4, 3.0),
				clampf(pdepth / PROP_NATIVE_SIZE.z, 0.4, 3.0))
			prop_info = {"pos": Vector3(pcx, pbase, pcz), "scale": pscale}
			_add_trunk_collision(faces, pcx, pbase, pcz, maxf(pwidth, pdepth) * 0.5, height)
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
			any_roof = true

	var wall_mat := ShaderMaterial.new()
	wall_mat.shader = BUILDING_SHADER
	wall_mat.set_shader_parameter("window_tex", _window_tex)
	wall_mat.set_shader_parameter("uv_scale", Vector3(0.125, 0.125, 0.125))
	walls.set_material(wall_mat)
	walls.generate_normals()

	var out := {"walls": walls.commit(), "prop": prop_info}
	if any_roof:
		var roof_mat := StandardMaterial3D.new()
		roof_mat.vertex_color_use_as_albedo = true
		roof_mat.roughness = 0.95
		roofs.set_material(roof_mat)
		roofs.generate_normals()
		out["roofs"] = roofs.commit()
	return out

func _poly_area2(pts: Array, n: int) -> float:
	var a := 0.0
	for i in range(n):
		var p0: Array = pts[i]
		var p1: Array = pts[(i + 1) % n]
		a += float(p0[0]) * float(p1[1]) - float(p1[0]) * float(p0[1])
	return absf(a) * 0.5

func _build_curbs_mesh(roads: Array) -> Variant:
	if roads.is_empty():
		return null
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
	return st.commit()

func _build_roads_mesh(roads: Array) -> Variant:
	if roads.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in roads:
		_ribbon(st, r["p"], float(r["w"]) * 0.5, 0.11)
	var mat := ShaderMaterial.new()
	mat.shader = ROAD_SHADER
	mat.set_shader_parameter("asphalt_tex", _asphalt_tex)
	mat.set_shader_parameter("uv_scale", Vector2(0.3, 0.3))
	st.set_material(mat)
	st.generate_normals()
	return st.commit()

func _build_markings_mesh(roads: Array) -> Variant:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var dash := 2.5
	var gap := 3.5
	var period := dash + gap
	var mw := 0.16
	var any := false
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
					any = true
					d = e
				else:
					d += period - pos_in
			phase = fmod(phase + L, period)
	if not any:
		return null
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.95, 0.9, 0.5)
	mat.roughness = 0.6
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
	st.generate_normals()
	return st.commit()

func _mark_pt(ax: float, az: float, ux: float, uz: float, d: float) -> Vector3:
	var x := ax + ux * d
	var z := az + uz * d
	return Vector3(x, _height_at(x, z) + 0.15, z)

func _build_greens_mesh(greens: Array) -> Variant:
	if greens.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var grass := Color(0.33, 0.5, 0.26)
	var any := false
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
			any = true
	if not any:
		return null
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	st.set_material(mat)
	st.generate_normals()
	return st.commit()

func _build_trees_multimesh(trees: Array, faces: PackedVector3Array) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _tree_mesh_res
	mm.instance_count = trees.size()
	for i in range(trees.size()):
		var t: Array = trees[i]
		var x: float = t[0]
		var z: float = t[1]
		var s: float = t[2] if t.size() > 2 else 1.0
		var basis := Basis(Vector3.UP, _hash01(x + z) * TAU).scaled(Vector3(s, s, s))
		var y := _height_at(x, z)
		mm.set_instance_transform(i, Transform3D(basis, Vector3(x, y, z)))
		_add_trunk_collision(faces, x, y, z, 0.45 * s, 3.0 * s)
	return mm

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

# --- NPCs / traffic, spawned per chunk instead of once globally --------------

func _npc_spawn_points(roads: Array, rng: RandomNumberGenerator) -> Array:
	if npc_scene == null:
		return []
	var candidates: Array = []
	for r in roads:
		if float(r.get("w", 0.0)) >= 5.0 and r["p"].size() >= 2:
			candidates.append(r)
	if candidates.is_empty():
		return []
	var out: Array = []
	var attempts := 0
	var max_attempts := npcs_per_chunk * 6
	while out.size() < npcs_per_chunk and attempts < max_attempts:
		attempts += 1
		var r: Dictionary = candidates[rng.randi() % candidates.size()]
		var pts: Array = r["p"]
		var idx := rng.randi() % (pts.size() - 1)
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
		if rng.randf() < 0.5:
			sx = -sx
			sz = -sz
		var hw := float(r["w"]) * 0.5 + 0.8
		var off := hw + 1.0
		var ya := _height_at(ax + sx * off, az + sz * off)
		var yb := _height_at(bx + sx * off, bz + sz * off)
		out.append({
			"a": Vector3(ax + sx * off, ya, az + sz * off),
			"b": Vector3(bx + sx * off, yb, bz + sz * off),
		})
	return out

func _traffic_lane_paths(roads: Array, rng: RandomNumberGenerator) -> Array:
	if traffic_scene == null:
		return []
	var candidates: Array = []
	for r in roads:
		if float(r.get("w", 0.0)) >= 6.0 and r["p"].size() >= 2:
			candidates.append(r)
	if candidates.is_empty():
		return []
	var out: Array = []
	var attempts := 0
	var max_attempts := traffic_per_chunk * 6
	while out.size() < traffic_per_chunk and attempts < max_attempts:
		attempts += 1
		var r: Dictionary = candidates[rng.randi() % candidates.size()]
		var lane := _lane_path(r, rng.randf() < 0.5)
		if lane.size() < 2:
			continue
		out.append({"path": lane, "speed": rng.randf_range(4.0, 9.0)})
	return out

func _spawn_npcs_for_chunk(root: Node3D, spawns: Array) -> void:
	if npc_scene == null:
		return
	for s in spawns:
		var npc = npc_scene.instantiate()
		npc.target_a = s["a"]
		npc.target_b = s["b"]
		root.add_child(npc)
		npc.position = npc.target_a

func _spawn_traffic_for_chunk(root: Node3D, paths: Array) -> void:
	if traffic_scene == null:
		return
	for p in paths:
		var car = traffic_scene.instantiate()
		car.path = p["path"]
		car.speed = p["speed"]
		root.add_child(car)
		car.global_position = p["path"][0]

## Builds a lane-offset waypoint path (draped onto the terrain) that follows one
## side of a road's centerline, so traffic drives along real streets rather
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

# --- terrain heightmap (global, built once) ---------------------------------

func _load_terrain(terrain_path: String) -> void:
	var f := FileAccess.open(terrain_path, FileAccess.READ)
	if f == null:
		push_error("Terrain data not found at %s" % terrain_path)
		return
	var t: Dictionary = JSON.parse_string(f.get_as_text())
	f.close()
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

# --- ocean + terrain skirt (beyond the fetched valley data) ------------------

func _build_ocean_and_skirt() -> void:
	if _nx == 0:
		return
	var sea_y := sea_level_offset

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# North edge (i = 0) and south edge (i = _nz - 1), full width.
	for j in range(_nx - 1):
		_skirt_quad(st, _grid_pos(0, j), _grid_pos(0, j + 1), Vector3(0, 0, -1), sea_y)
		_skirt_quad(st, _grid_pos(_nz - 1, j + 1), _grid_pos(_nz - 1, j), Vector3(0, 0, 1), sea_y)
	# West edge (j = 0) and east edge (j = _nx - 1), full height.
	for i in range(_nz - 1):
		_skirt_quad(st, _grid_pos(i + 1, 0), _grid_pos(i, 0), Vector3(-1, 0, 0), sea_y)
		_skirt_quad(st, _grid_pos(i, _nx - 1), _grid_pos(i + 1, _nx - 1), Vector3(1, 0, 0), sea_y)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.3, 0.28, 0.24)
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
	st.generate_normals()
	_add_mesh(st.commit())

	var cx := (_minx + _maxx) * 0.5
	var cz := (_minz + _maxz) * 0.5
	var e := ocean_extent
	var ost := SurfaceTool.new()
	ost.begin(Mesh.PRIMITIVE_TRIANGLES)
	ost.add_vertex(Vector3(cx - e, sea_y, cz - e))
	ost.add_vertex(Vector3(cx - e, sea_y, cz + e))
	ost.add_vertex(Vector3(cx + e, sea_y, cz + e))
	ost.add_vertex(Vector3(cx - e, sea_y, cz - e))
	ost.add_vertex(Vector3(cx + e, sea_y, cz + e))
	ost.add_vertex(Vector3(cx + e, sea_y, cz - e))
	var ocean_mat := ShaderMaterial.new()
	ocean_mat.shader = OCEAN_SHADER
	ost.set_material(ocean_mat)
	ost.generate_normals()
	_add_mesh(ost.commit())

## One skirt quad sloping from a real terrain edge vertex pair down to sea
## level over `skirt_falloff` metres, so the fetched data's edge isn't a cliff.
func _skirt_quad(st: SurfaceTool, edge_a: Vector3, edge_b: Vector3, out_dir: Vector3, sea_y: float) -> void:
	var far := skirt_falloff
	var outer_a := edge_a + out_dir * far
	outer_a.y = sea_y
	var outer_b := edge_b + out_dir * far
	outer_b.y = sea_y
	_quad(st, edge_a, edge_b, outer_b, outer_a)

# --- procedural textures ----------------------------------------------------

func _asphalt_texture() -> ImageTexture:
	var s := 64
	var img := Image.create_empty(s, s, false, Image.FORMAT_RGB8)
	for y in range(s):
		for x in range(s):
			var n := 0.82 + 0.18 * _hash01(float(x) * 1.7 + float(y) * 2.3)
			img.set_pixel(x, y, Color(n, n, n * 1.02))
	return ImageTexture.create_from_image(img)

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
