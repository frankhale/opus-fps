class_name GrassField
## Grass carpeting a level's grassy ground: clumps of grass (assets/scenery/grass_patch.glb)
## about every SPACING meters (jittered, turned at random and SIZE times their real size),
## scattered the same way every time for a seed, in square MultiMesh chunks CHUNK meters
## across (one draw each) that are each drawn only within RANGE meters, where the grass
## material has sunk them into the ground anyway. Used by the island and the hub.

const MODEL := "res://assets/scenery/grass_patch.glb"
const SPACING := 0.7
const SIZE := Vector2(1.2, 1.7)
const CHUNK := 12.0
const RANGE := 45.0


## Grass over `area` (an x/z rectangle), scattered by `seed`. `ground` gives the ground's
## height at (x, z), or NAN where no grass grows there, and none grows inside `bare`
## (rectangles seen from above, see bare_under()). Returns a node named Grass holding the
## chunks, or null without the grass model.
static func build(area: Rect2, seed: int, ground: Callable, bare: Array[Rect2] = []) -> Node3D:
	if not ResourceLoader.exists(MODEL):
		return null
	var model: Node = (load(MODEL) as PackedScene).instantiate()
	var found := model.find_children("*", "MeshInstance3D", true, false)
	var mesh: Mesh = (found[0] as MeshInstance3D).mesh if found else null
	model.free()
	if mesh == null:
		return null
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var chunks := {}  # chunk (x, z) -> the clumps' transforms
	for j in int(area.size.y / SPACING):
		for i in int(area.size.x / SPACING):
			var x := area.position.x + (i + rng.randf()) * SPACING
			var z := area.position.y + (j + rng.randf()) * SPACING
			var turn := rng.randf() * TAU
			var size := rng.randf_range(SIZE.x, SIZE.y)
			var h: float = ground.call(x, z)
			if is_nan(h) or bare.any(func(r: Rect2) -> bool: return r.has_point(Vector2(x, z))):
				continue
			var key := Vector2i(floori(x / CHUNK), floori(z / CHUNK))
			if not chunks.has(key):
				chunks[key] = []
			chunks[key].append(Transform3D(Basis(Vector3.UP, turn).scaled(Vector3.ONE * size), Vector3(x, h - 0.02, z)))
	var grass := Node3D.new()
	grass.name = "Grass"
	for key: Vector2i in chunks:
		var clumps: Array = chunks[key]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = clumps.size()
		# All the transforms in one go (setting them one by one is slow by the thousand):
		# each is its basis's rows, each followed by that row's part of the origin.
		var buffer := PackedFloat32Array()
		buffer.resize(clumps.size() * 12)
		for k in clumps.size():
			var t: Transform3D = clumps[k]
			var o := k * 12
			for r in 3:
				buffer[o + r * 4] = t.basis.x[r]
				buffer[o + r * 4 + 1] = t.basis.y[r]
				buffer[o + r * 4 + 2] = t.basis.z[r]
				buffer[o + r * 4 + 3] = t.origin[r]
		mm.buffer = buffer
		var chunk := MultiMeshInstance3D.new()
		chunk.multimesh = mm
		chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		chunk.visibility_range_end = RANGE
		chunk.visibility_range_end_margin = 5.0
		chunk.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		grass.add_child(chunk)
	return grass


## The ground taken up by `nodes` (everything drawn in them), as boxes seen from above,
## for build()'s `bare`.
static func bare_under(nodes: Array[Node]) -> Array[Rect2]:
	var bare: Array[Rect2] = []
	for node in nodes:
		for g: GeometryInstance3D in node.find_children("*", "GeometryInstance3D", true, false):
			var box: AABB = g.global_transform * g.get_aabb()
			if box.size.x > 0.2 and box.size.z > 0.2:  # thinner would vanish when shrunk
				bare.append(Rect2(box.position.x, box.position.z, box.size.x, box.size.z).grow(-0.1))
	return bare
