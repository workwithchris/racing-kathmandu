@tool
extends MeshInstance3D
## Procedurally sculpts the car's lower body (bumpers/hood/windshield-rake/
## trunk/underbody) from a 2D side-profile swept across the car's width --
## the same "cheap procedural mesh instead of an asset" approach used for the
## rest of the map (buildings/roads/ocean). The cabin greenhouse sits on top
## as a separate flat-topped box (see car.tscn), same as the original design,
## just resting on a properly sculpted body instead of a plain box.

@export var body_color := Color(0.85, 0.13, 0.13)
@export var half_width := 0.85
@export var metallic := 0.7
@export var roughness := 0.28

# Side profile in (z, y): front bumper -> hood -> windshield base -> flat
# beltline (the cabin box sits on this) -> rear window base -> trunk ->
# rear bumper -> flat underbody, closing back to the start.
const PROFILE := [
	Vector2(-1.95, 0.05), Vector2(-1.95, 0.32), Vector2(-1.72, 0.44),
	Vector2(-0.85, 0.55), Vector2(0.85, 0.55), Vector2(1.55, 0.46),
	Vector2(1.95, 0.30), Vector2(1.95, 0.05),
]

func _ready() -> void:
	mesh = _build()

func _build() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hw := half_width
	var poly := PackedVector2Array(PROFILE)
	var n := poly.size()
	var idx := Geometry2D.triangulate_polygon(poly)

	# Left cap (x = -hw) and right cap (x = +hw): the two flat side panels.
	for k in range(0, idx.size(), 3):
		var p0 := poly[idx[k]]
		var p1 := poly[idx[k + 1]]
		var p2 := poly[idx[k + 2]]
		_tri(st, Vector3(-hw, p0.y, p0.x), Vector3(-hw, p2.y, p2.x), Vector3(-hw, p1.y, p1.x))
		_tri(st, Vector3(hw, p0.y, p0.x), Vector3(hw, p1.y, p1.x), Vector3(hw, p2.y, p2.x))

	# Wraparound strip (hood/windshield/beltline/rear-window/trunk/bumpers/underbody).
	for i in range(n):
		var a := poly[i]
		var b := poly[(i + 1) % n]
		var a0 := Vector3(-hw, a.y, a.x)
		var b0 := Vector3(-hw, b.y, b.x)
		var a1 := Vector3(hw, a.y, a.x)
		var b1 := Vector3(hw, b.y, b.x)
		_tri(st, a0, b0, b1)
		_tri(st, a0, b1, a1)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = body_color
	mat.metallic = metallic
	mat.metallic_specular = 0.6
	mat.roughness = roughness
	mat.clearcoat_enabled = true
	mat.clearcoat = 1.0
	mat.clearcoat_roughness = 0.04
	mat.rim_enabled = true
	mat.rim = 0.25
	mat.rim_tint = 0.5
	# Hand-derived winding above should already face outward; disabling culling
	# is a cheap safety net for a dozen-triangle mesh (matches the same
	## arbitrary-winding safeguard used for building walls elsewhere).
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)
	st.generate_normals()
	return st.commit()

func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a); st.add_vertex(b); st.add_vertex(c)
