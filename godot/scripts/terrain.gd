@tool
class_name Terrain
extends Node3D
## The level's ground: the asset pack's 8 m terrain tiles (grass, dirt road, sand,
## ponds, hills) laid out on a grid and bent over gently rolling hills, so the land
## rises and falls instead of lying flat. The hills are a smooth noise height field
## added to every tile vertex. They grow taller away from the middle of the map,
## the valley floor sweeps up toward the cliffs at its edge, and they fade out over
## the flat zones (villages, camps, ponds) and soften along the roads.
## The meshes and their collision are built when the node enters the tree (also in
## the editor), so the scene only stores the layout. tools/build_level.gd sets it up
## and calls height() to drop props onto the hills.

const TILE := 8.0
## Tiles per side of each mesh/collision chunk.
const CHUNK := 4

## Tiles from the center to the edge; the grid is (2 * half + 1) tiles square.
@export var half := 11
## One "name:rotation_degrees" per cell, row by row from (-half, -half), x fastest.
@export var tiles := PackedStringArray()
## Areas kept flat, as rectangles in x/z (position = min corner).
@export var flat_rects: Array[Rect2] = []
## Areas kept flat, as circles: (x, z, radius).
@export var flat_circles := PackedVector3Array()
## Straight roads, softened to `road_hill_scale`: x = road along z at that x, y = road
## along x at that z. Use NAN for "none".
@export var road_x := 0.0
@export var road_z := 40.0
@export var road_hill_scale := 0.35
## A creek running along x at this z (NAN for none). The ground is held flat along it,
## the rising rim too, so its water lies level and it cuts a little gorge out to the
## cliffs at each end.
@export var creek_z := NAN
@export var creek_half_width := 4.0
## Distance over which hills fade back in around flat areas, in meters.
@export var flat_falloff := 10.0
@export var noise_seed := 7
## Typical hill height near the middle of the map and out toward the edges, in meters.
@export var inner_hill_height := 2.2
@export var outer_hill_height := 6.0
## How far the valley floor rises toward the cliffs at the edge, in meters.
@export var rim_height := 7.0
## Multiplies the tiles' palette colors, so the sunlit ground doesn't outshine the props.
@export var ground_brightness := 0.8
## Paint the ground in one shade per material (all grass one green, all dirt one brown,
## all sand one tan) instead of the tiles' random per-face mix of light and dark shades.
@export var uniform_ground := true

var _noise: FastNoiseLite
var _tile_cache := {}
## Palette swatch remaps for `uniform_ground`, by column in the nature row (the top row
## in Godot's UVs): dark/light grass -> grass, dark soil -> dirt, light sand -> sand.
const UNIFORM_SWATCH := {0: 1, 2: 1, 4: 5, 7: 6}
## On road tiles the sand flecks become dirt and the olive verges become grass too.
const UNIFORM_ROAD_SWATCH := {0: 1, 2: 1, 3: 1, 4: 5, 6: 5, 7: 5}
const ROAD_TILES := ["terrain_dirt_path", "terrain_path_cross"]
var _material_cache := {}
## World-space triangles of each tile, kept when `keep_faces` is set (level builder).
var keep_faces := false
var tile_faces: Array = []  # [{min: Vector2, max: Vector2, faces: PackedVector3Array}]


func _ready() -> void:
	add_to_group("terrain")
	build()


## Name of the tile at (x, z), e.g. "terrain_grass" or "terrain_pond" ("" off the grid).
func tile_at(x: float, z: float) -> String:
	var n := 2 * half + 1
	var i := roundi(x / TILE) + half
	var j := roundi(z / TILE) + half
	if i < 0 or j < 0 or i >= n or j >= n or tiles.size() != n * n:
		return ""
	return tiles[j * n + i].get_slice(":", 0)


## Edge of the tiled ground, in meters from the center.
func extent() -> float:
	return half * TILE + TILE / 2.0


## Height of the rolling hills at (x, z); the tiles' own shapes (ponds, hillocks) add to it.
func height(x: float, z: float) -> float:
	if _noise == null:
		_noise = FastNoiseLite.new()
		_noise.seed = noise_seed
		_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_noise.frequency = 0.016
		_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		_noise.fractal_octaves = 3
		_noise.fractal_gain = 0.4
	var r := Vector2(x, z).length()
	var amp := lerpf(inner_hill_height, outer_hill_height, smoothstep(25.0, 85.0, r))
	var hills := _noise.get_noise_2d(x, z) * 1.6 * amp
	var edge := maxf(absf(x), absf(z))
	var rim := smoothstep(extent() - 30.0, extent() + 2.0, edge) * rim_height
	var h := hills * _flatness(x, z) + rim
	if not is_nan(creek_z):
		h *= smoothstep(creek_half_width, creek_half_width + flat_falloff, absf(z - creek_z))
	return h


## 0 inside flat zones, 1 in open country, `road_hill_scale` on the roads.
func _flatness(x: float, z: float) -> float:
	var d := INF
	for rect in flat_rects:
		var dx := maxf(maxf(rect.position.x - x, x - rect.end.x), 0.0)
		var dz := maxf(maxf(rect.position.y - z, z - rect.end.y), 0.0)
		d = minf(d, Vector2(dx, dz).length())
	for c in flat_circles:
		d = minf(d, maxf(Vector2(x - c.x, z - c.y).length() - c.z, 0.0))
	var f := smoothstep(0.0, flat_falloff, d)
	var road := INF
	if not is_nan(road_x):
		road = absf(x - road_x)
	if not is_nan(road_z):
		road = minf(road, absf(z - road_z))
	return f * lerpf(road_hill_scale, 1.0, smoothstep(3.0, 14.0, road))


func build() -> void:
	for c in get_children():
		if c.has_meta("generated"):
			c.free()
	tile_faces.clear()
	if tiles.is_empty():
		return
	var n := 2 * half + 1
	# chunk -> material -> [vertices, normals, uvs]
	var chunks := {}
	var heights := {}
	for j in n:
		for i in n:
			var entry := tiles[j * n + i].split(":")
			var origin := Vector3((i - half) * TILE, 0.0, (j - half) * TILE)
			var xf := Transform3D(Basis(Vector3.UP, deg_to_rad(float(entry[1]))), origin)
			@warning_ignore("integer_division")
			var key := Vector2i(i / CHUNK, j / CHUNK)
			if not chunks.has(key):
				chunks[key] = {}
			var faces := PackedVector3Array()
			for surf in _tile_surfaces(entry[0]):
				var mat: Material = surf[0]
				var water := _is_water(mat)
				if not chunks[key].has(mat):
					chunks[key][mat] = [PackedVector3Array(), PackedVector3Array(), PackedVector2Array()]
				var out: Array = chunks[key][mat]
				var src_v: PackedVector3Array = surf[1]
				var src_n: PackedVector3Array = surf[2]
				var src_uv: PackedVector2Array = surf[3]
				for t in range(0, src_v.size(), 3):
					var tri: Array[Vector3] = []
					for k in 3:
						var p := xf * src_v[t + k]
						# Shared edges between tiles must get identical heights.
						var hk := Vector2i(roundi(p.x * 64.0), roundi(p.z * 64.0))
						if not heights.has(hk):
							heights[hk] = height(p.x, p.z)
						p.y += heights[hk]
						tri.append(p)
					var nrm := (tri[1] - tri[0]).cross(tri[2] - tri[0]).normalized()
					if nrm.dot(xf.basis * src_n[t]) < 0.0:
						nrm = -nrm
					for k in 3:
						out[0].append(tri[k])
						out[1].append(nrm)
						out[2].append(src_uv[t + k])
						if keep_faces and not water:
							faces.append(tri[k])
			if keep_faces:
				tile_faces.append({"min": Vector2(origin.x - TILE / 2, origin.z - TILE / 2),
					"max": Vector2(origin.x + TILE / 2, origin.z + TILE / 2), "faces": faces})
	for key in chunks:
		var mesh := ArrayMesh.new()
		var all := PackedVector3Array()
		for mat in chunks[key]:
			var a := []
			a.resize(Mesh.ARRAY_MAX)
			a[Mesh.ARRAY_VERTEX] = chunks[key][mat][0]
			a[Mesh.ARRAY_NORMAL] = chunks[key][mat][1]
			a[Mesh.ARRAY_TEX_UV] = chunks[key][mat][2]
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
			mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
			if not _is_water(mat):  # creek water is walk-through: you wade on the bed
				all.append_array(chunks[key][mat][0])
		var mi := MeshInstance3D.new()
		mi.name = "Chunk_%d_%d" % [key.x, key.y]
		mi.mesh = mesh
		mi.set_meta("generated", true)
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		var concave := ConcavePolygonShape3D.new()
		concave.set_faces(all)
		shape.shape = concave
		body.add_child(shape)
		mi.add_child(body)
		add_child(mi)


## A tile model's surfaces as flat triangle lists: [material, vertices, normals, uvs].
func _tile_surfaces(tile_name: String) -> Array:
	if _tile_cache.has(tile_name):
		return _tile_cache[tile_name]
	var surfaces := []
	var swatches: Dictionary = UNIFORM_ROAD_SWATCH if tile_name in ROAD_TILES else UNIFORM_SWATCH
	var inst: Node3D = load("res://assets/terrain/%s.glb" % tile_name).instantiate()
	for mi: MeshInstance3D in inst.find_children("*", "MeshInstance3D", true, false):
		var xf := mi.transform
		for s in mi.mesh.get_surface_count():
			var arr := mi.mesh.surface_get_arrays(s)
			var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var nr: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
			var uv: PackedVector2Array = arr[Mesh.ARRAY_TEX_UV]
			# Only palette surfaces get the uniform-ground remap; water UVs are flow coordinates.
			var palette := not _is_water(mi.get_active_material(s))
			var idx: PackedInt32Array = arr[Mesh.ARRAY_INDEX] if arr[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			var ov := PackedVector3Array()
			var on := PackedVector3Array()
			var ouv := PackedVector2Array()
			var count := idx.size() if idx.size() > 0 else v.size()
			for k in count:
				var vi := idx[k] if idx.size() > 0 else k
				ov.append(xf * v[vi])
				on.append(xf.basis * nr[vi])
				ouv.append(_uniform_uv(uv[vi], swatches) if uniform_ground and palette else uv[vi])
			surfaces.append([_ground_material(mi.get_active_material(s)), ov, on, ouv])
	inst.free()
	_tile_cache[tile_name] = surfaces
	return surfaces


func _is_water(mat: Material) -> bool:
	return mat != null and mat.resource_name == "PS1_Water"


## The tile material dimmed by `ground_brightness` (shared per source material).
func _ground_material(mat: Material) -> Material:
	if not mat is ShaderMaterial or _is_water(mat) or is_equal_approx(ground_brightness, 1.0):
		return mat
	if not _material_cache.has(mat):
		var dim: ShaderMaterial = mat.duplicate()
		dim.set_shader_parameter("albedo_scale", ground_brightness)
		_material_cache[mat] = dim
	return _material_cache[mat]


## Moves a UV in a dark or light ground swatch over to its base shade's swatch.
func _uniform_uv(uv: Vector2, swatches: Dictionary) -> Vector2:
	var col := floori(uv.x * 8.0)
	if floori(uv.y * 4.0) != 0 or not swatches.has(col):
		return uv
	return Vector2(uv.x + (swatches[col] - col) / 8.0, uv.y)
