extends StaticBody3D
## Procedurally builds a smooth curved race track (road + barrier walls + collision)
## from the parametric centerline in `_centerline()`. Edit that function to reshape
## the circuit; everything else regenerates automatically.

## Half the width of the drivable road, in metres.
@export var track_half_width := 9.0
## Height of the barrier walls on each edge.
@export var wall_height := 1.6
## How many segments around the loop. More = smoother curves.
@export var segments := 240

## Nodes to place at the start line when the track is built.
@export var car_path: NodePath
@export var camera_path: NodePath

## Where the start line sits along the loop (0.0 = start of the curve).
@export var start_offset := 0.0

func _ready() -> void:
	_build()
	_place_start(_centerline(0.0), _tangent(0.0))

## The track centerline. t is an angle in radians over [0, TAU).
## Tweak these expressions to reshape the circuit.
func _centerline(t: float) -> Vector3:
	var x := 95.0 * cos(t) + 12.0 * cos(2.0 * t)
	var z := 62.0 * sin(t) + 22.0 * sin(2.0 * t)
	return Vector3(x, 0.0, z)

## Forward (travel) direction of the track at t, flattened to the ground plane.
func _tangent(t: float) -> Vector3:
	var ahead := _centerline(t + 0.01) - _centerline(t)
	ahead.y = 0.0
	return ahead.normalized()

func _build() -> void:
	var road := SurfaceTool.new()
	road.begin(Mesh.PRIMITIVE_TRIANGLES)
	var walls := SurfaceTool.new()
	walls.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stripe := SurfaceTool.new()
	stripe.begin(Mesh.PRIMITIVE_TRIANGLES)

	var faces := PackedVector3Array()
	var up := Vector3(0.0, wall_height, 0.0)

	# Precompute the two road edges at every step around the loop.
	var edge_a := PackedVector3Array()
	var edge_b := PackedVector3Array()
	for i in range(segments):
		var t := TAU * float(i) / float(segments)
		var c := _centerline(t)
		var side := _tangent(t)
		# Perpendicular to travel, in the ground plane.
		side = Vector3(side.z, 0.0, -side.x)
		edge_a.append(c + side * track_half_width)
		edge_b.append(c - side * track_half_width)

	for i in range(segments):
		var j := (i + 1) % segments
		var ai := edge_a[i]
		var bi := edge_b[i]
		var aj := edge_a[j]
		var bj := edge_b[j]

		# Road surface (two triangles, wound so the normal points up).
		_tri(road, faces, ai, bi, bj)
		_tri(road, faces, ai, bj, aj)

		# Barrier wall on edge A.
		_tri(walls, faces, ai, ai + up, aj + up)
		_tri(walls, faces, ai, aj + up, aj)
		# Barrier wall on edge B.
		_tri(walls, faces, bi, bi + up, bj + up)
		_tri(walls, faces, bi, bj + up, bj)

	# Start/finish stripe: a white band across the first few segments.
	var lift := Vector3(0.0, 0.03, 0.0)
	var k := 3 % segments
	_tri(stripe, faces, edge_a[0] + lift, edge_b[0] + lift, edge_b[k] + lift, false)
	_tri(stripe, faces, edge_a[0] + lift, edge_b[k] + lift, edge_a[k] + lift, false)

	# Materials.
	var road_mat := StandardMaterial3D.new()
	road_mat.albedo_color = Color(0.14, 0.14, 0.16)
	road_mat.roughness = 0.95
	road.set_material(road_mat)
	road.generate_normals()

	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.85, 0.16, 0.16)
	wall_mat.roughness = 0.6
	wall_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	walls.set_material(wall_mat)
	walls.generate_normals()

	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = Color(0.95, 0.95, 0.95)
	stripe_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	stripe.set_material(stripe_mat)
	stripe.generate_normals()

	var mesh := ArrayMesh.new()
	road.commit(mesh)
	walls.commit(mesh)
	stripe.commit(mesh)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	add_child(mi)

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var cs := CollisionShape3D.new()
	cs.shape = shape
	add_child(cs)

## Adds a triangle to a SurfaceTool, and (optionally) to the collision face list.
func _tri(st: SurfaceTool, faces: PackedVector3Array, a: Vector3, b: Vector3, c: Vector3, collide := true) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	if collide:
		faces.push_back(a)
		faces.push_back(b)
		faces.push_back(c)

## Drops the car (and camera) onto the start line, facing along the track.
func _place_start(pos: Vector3, travel: Vector3) -> void:
	var car := get_node_or_null(car_path)
	if car is Node3D:
		# The car drives nose-first (-Z), so its local -Z must point along travel.
		var z_axis := -travel
		var x_axis := Vector3.UP.cross(z_axis).normalized()
		var basis := Basis(x_axis, Vector3.UP, z_axis)
		car.global_transform = Transform3D(basis, pos + Vector3.UP * 1.0)
		if "linear_velocity" in car:
			car.linear_velocity = Vector3.ZERO
			car.angular_velocity = Vector3.ZERO
		var cam := get_node_or_null(camera_path)
		if cam is Node3D:
			cam.global_position = pos + z_axis * 8.0 + Vector3.UP * 4.0
