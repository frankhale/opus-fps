@tool
class_name IslandScene
extends Node3D
## A small island in an open sea: the level in scenes/island.tscn, played with the dev
## console's `scene island`.
## The island is about 85 m across with a ragged, noisy coastline. A sandy beach 10 m wide
## rises gently from the water to grassy hills up to about 4 m high in the middle. Under
## the water the sand shelves away, gently through the shallows and then steeply down to
## about 9 m, so the sea turns from turquoise to deep blue a little way out.
## The ground is one mesh built here from height(), painted like the main level's terrain
## (scripts/terrain.gd): the pack's palette material, dimmed the same, with each face
## mapped onto one swatch as the tiles are: sand on the beach and under the water,
## grass inland, so the grass edge steps along the faces. The sea (materials/sea.gdshader) is a 1.6 km sheet
## at height 0 that reaches the fog on every side, with surf rolling in to shore.
## You can wade out until the water is about 1 m deep, where invisible walls follow the
## coast round. Rocks sit along the shore (the surf foams round them), with a few trees
## and bushes on the grass. The shadow cat roams the island, the lynx ranger and a
## dachshund potter about on it, and the arcane eye and a jellyfish float over it. Everything is built
## when the node enters the tree (also in the editor, apart from the creatures), so the
## scene file stays tiny. The player starts on the south beach, looking out to sea.

const SEED := 2024
## Mean distance from the middle to the waterline, and how far it wanders either way.
const COAST_RADIUS := 42.0
const COAST_WANDER := 7.0
## Width of the beach from the waterline to where the hills begin, and its rise.
const BEACH_WIDTH := 10.0
const BEACH_SLOPE := 0.09
## Height of the inland hills (on average, and their noisy variation either way).
const HILL_HEIGHT := 2.6
const HILL_VARIATION := 1.6
## Slope of the sand under the shallows; past SHELF meters out it drops at DROP_SLOPE.
const SHALLOW_SLOPE := 0.11
const SHELF := 10.0
const DROP_SLOPE := 0.3
const SEA_BED := -9.0
## Height where (on average) sand turns to grass.
const GRASS_LINE := 1.35
## The ground mesh: a square grid this far out from the middle each way, with this
## spacing (the terrain tiles' 1 m). Past it the sea is too deep to see the bottom.
const GROUND_HALF := 72.0
const GROUND_STEP := 1.0
## Palette swatches (column, row) the main level's ground uses: see Terrain.UNIFORM_SWATCH.
## Dimming of the ground's colors, the main level's (Terrain.ground_brightness).
const GROUND_BRIGHTNESS := 0.8
const SAND_SWATCH := Vector2(6, 0)
const GRASS_SWATCH := Vector2(1, 0)
const SEA_SIZE := 1600.0
## The walls stand this far out from the waterline (about 1 m of water there).
const WADE := 9.0
const WALL_SEGMENTS := 72
const WALL_HEIGHT := 10.0
## Where the player starts: on the beach this far up from the waterline, due south.
const SPAWN_INLAND := 6.0

const GROUND_MATERIAL := preload("res://materials/ps1_palette.tres")
const SEA_SHADER := preload("res://materials/sea.gdshader")
const SURF_SOUND := "res://assets/sfx/surf_loop.wav"

## Scenery: model, how many, how far from the waterline (min, max, inland positive),
## scale range, and how deep (m, times the scale) to sink it into the ground.
const PROPS := [
	["rock_large", 4, -4.0, 2.0, 0.9, 1.5, 0.35],
	["rock_cluster", 6, -5.0, 6.0, 0.8, 1.4, 0.15],
	["rock_small", 12, -6.0, 8.0, 0.8, 1.6, 0.08],
	["tree_oak", 4, 17.0, 30.0, 1.0, 1.3, 0.1],
	["tree_pine", 3, 18.0, 32.0, 1.0, 1.25, 0.1],
	["bush_tall", 4, 13.0, 30.0, 0.9, 1.2, 0.05],
	["bush", 8, 11.0, 30.0, 0.9, 1.3, 0.05],
	["grass_tuft", 30, 9.0, 32.0, 1.0, 1.6, 0.02],
]
## Nothing is placed this close to where the player starts.
const SPAWN_CLEAR := 7.0
## The shadow cat starts this far round the coast from the player's start (radians) and
## this far inland, and keeps at least CAT_SHORE meters from the water as it wanders.
const CAT_ANGLE := -0.25
const CAT_INLAND := 10.0
const CAT_SHORE := 3.0
## The arcane eye starts this far round the coast from the player's start (radians) and
## this far inland, and drifts anywhere over the island.
const EYE_ANGLE := 0.4
const EYE_INLAND := 16.0
## The lynx ranger starts this far round the coast from the player's start (radians) and
## this far inland, and keeps at least LYNX_SHORE meters from the water as it strolls.
const LYNX_ANGLE := 0.15
const LYNX_INLAND := 12.0
const LYNX_SHORE := 4.0
## The jellyfish starts this far round the coast from the player's start (radians) and
## this far inland, and swims anywhere over the island and out over the shallows up to
## JELLY_OFFSHORE meters past the waterline.
const JELLY_ANGLE := -0.7
const JELLY_INLAND := 6.0
const JELLY_OFFSHORE := 6.0
## The dachshund starts this far round the coast from the player's start (radians) and
## this far inland, and keeps at least DOG_SHORE meters from the water.
const DOG_ANGLE := -0.25
const DOG_INLAND := 9.0
const DOG_SHORE := 3.0

var _coast := []  # [harmonic, amplitude, phase] for the coastline's wander
var _noise: FastNoiseLite
var _hills: FastNoiseLite


func _ready() -> void:
	build()
	if not Engine.is_editor_hint():
		_place_player.call_deferred()  # once the world around it is ready


func build() -> void:
	for c in get_children():
		c.free()
	_setup_noise()
	_build_ground()
	_build_sea()
	_build_walls()
	_scatter_props()
	_place_cat()
	_place_lynx()
	_place_dog()
	_place_eye()
	_place_jellyfish()
	if not Engine.is_editor_hint() and ResourceLoader.exists(SURF_SOUND):
		var surf := AudioStreamPlayer.new()
		surf.name = "Surf"
		surf.stream = load(SURF_SOUND)
		surf.volume_db = -10.0
		surf.autoplay = true
		add_child(surf)


func _setup_noise() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED
	_coast.clear()
	var total := 0.0
	for k in range(2, 7):
		var amp := rng.randf_range(0.5, 1.0) / k
		_coast.append([k, amp, rng.randf() * TAU])
		total += amp
	for h in _coast:
		h[1] *= COAST_WANDER / total
	_noise = FastNoiseLite.new()
	_noise.seed = SEED
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 0.09
	_hills = FastNoiseLite.new()
	_hills.seed = SEED + 1
	_hills.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_hills.frequency = 0.035
	_hills.fractal_octaves = 3


## Distance from the middle to the waterline in the direction `angle` (radians, from +X
## toward +Z).
func coast_radius(angle: float) -> float:
	var r := COAST_RADIUS
	for h in _coast:
		r += h[1] * sin(h[0] * angle + h[2])
	return r


## How far (x, z) is inland of the waterline, in meters along the radius (negative out to sea).
func inland(x: float, z: float) -> float:
	return coast_radius(atan2(z, x)) - Vector2(x, z).length()


## Ground height at (x, z), with the sea's surface at 0.
func height(x: float, z: float) -> float:
	var s := inland(x, z)
	var bump := _noise.get_noise_2d(x, z)
	if s >= 0.0:
		var beach := minf(s, BEACH_WIDTH) * BEACH_SLOPE
		var hills := smoothstep(BEACH_WIDTH - 2.0, BEACH_WIDTH + 14.0, s) \
			* (HILL_HEIGHT + _hills.get_noise_2d(x, z) * HILL_VARIATION * 2.0)
		return beach + hills + bump * 0.12 * smoothstep(0.0, 6.0, s)
	var bed := s * SHALLOW_SLOPE if s > -SHELF else -SHELF * SHALLOW_SLOPE + (s + SHELF) * DROP_SLOPE
	return maxf(bed, SEA_BED) + bump * 0.08


## Whether the ground at (x, z), at height h, is grass rather than sand. The line wanders
## a little, so the grass edge isn't a contour.
func _is_grass(x: float, z: float, h: float) -> bool:
	return h > GRASS_LINE + _noise.get_noise_2d(x * 0.6 + 50.0, z * 0.6) * 0.45


## UV of a point in a palette swatch, as the asset generator maps faces
## (tools/generate_assets.py): a face's box seen from above stretches over the swatch's
## inner 12 x 12 texels (16 px swatches with a 2 px margin), so each face picks up the
## swatch's grit like the terrain tiles do. `at` is the point's place in that box, 0 to 1.
func _swatch_uv(swatch: Vector2, at: Vector2) -> Vector2:
	return (swatch * 16.0 + Vector2(2.0, 2.0) + at * 12.0) / Vector2(128.0, 64.0)


func _build_ground() -> void:
	var n := int(GROUND_HALF * 2.0 / GROUND_STEP)
	var w := n + 3  # one extra row all round for the normals
	var heights := PackedFloat32Array()
	heights.resize(w * w)
	for j in w:
		for i in w:
			heights[j * w + i] = height(-GROUND_HALF + (i - 1) * GROUND_STEP, -GROUND_HALF + (j - 1) * GROUND_STEP)
	var points := PackedVector3Array()
	var point_normals := PackedVector3Array()
	for j in n + 1:
		for i in n + 1:
			var k := (j + 1) * w + i + 1
			points.append(Vector3(-GROUND_HALF + i * GROUND_STEP, heights[k], -GROUND_HALF + j * GROUND_STEP))
			point_normals.append(Vector3(heights[k - 1] - heights[k + 1], GROUND_STEP * 2.0,
				heights[k - w] - heights[k + w]).normalized())
	# Each face gets its own vertices so it can sit in one swatch, as the terrain tiles do.
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	for j in n:
		for i in n:
			var a := j * (n + 1) + i
			# Both triangles' boxes are the whole grid cell.
			var corner := points[a]
			for tri in [[a, a + 1, a + n + 1], [a + 1, a + n + 2, a + n + 1]]:
				var c: Vector3 = (points[tri[0]] + points[tri[1]] + points[tri[2]]) / 3.0
				var swatch := GRASS_SWATCH if _is_grass(c.x, c.z, c.y) else SAND_SWATCH
				for v in tri:
					verts.append(points[v])
					normals.append(point_normals[v])
					var p := points[v]
					uvs.append(_swatch_uv(swatch, Vector2(p.x - corner.x, p.z - corner.z) / GROUND_STEP))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat: ShaderMaterial = GROUND_MATERIAL.duplicate()
	mat.set_shader_parameter("albedo_scale", GROUND_BRIGHTNESS)
	mesh.surface_set_material(0, mat)

	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = mesh
	add_child(ground)
	var body := StaticBody3D.new()
	body.name = "Collision"
	var shape := CollisionShape3D.new()
	shape.shape = mesh.create_trimesh_shape()
	body.add_child(shape)
	ground.add_child(body)


func _build_sea() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(SEA_SIZE, SEA_SIZE)
	# Smaller faces, so the vertex snapping behaves close to the camera.
	plane.subdivide_width = 63
	plane.subdivide_depth = 63
	var mat := ShaderMaterial.new()
	mat.shader = SEA_SHADER
	mat.render_priority = 1  # after the other see-through things, like the creek
	plane.material = mat
	var sea := MeshInstance3D.new()
	sea.name = "Sea"
	sea.mesh = plane
	sea.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sea)


## Invisible walls round the coast, WADE meters out from the waterline.
func _build_walls() -> void:
	var walls := StaticBody3D.new()
	walls.name = "Walls"
	add_child(walls)
	var points := []
	for i in WALL_SEGMENTS:
		var angle := TAU * i / WALL_SEGMENTS
		points.append(Vector2(cos(angle), sin(angle)) * (coast_radius(angle) + WADE))
	for i in WALL_SEGMENTS:
		var a: Vector2 = points[i]
		var b: Vector2 = points[(i + 1) % WALL_SEGMENTS]
		var box := BoxShape3D.new()
		box.size = Vector3(a.distance_to(b) + 0.6, WALL_HEIGHT, 0.5)  # overlap so there are no gaps
		var shape := CollisionShape3D.new()
		shape.shape = box
		var mid := (a + b) * 0.5
		shape.position = Vector3(mid.x, WALL_HEIGHT * 0.5 - 2.0, mid.y)
		shape.rotation.y = -(b - a).angle()
		walls.add_child(shape)


func _spawn_point() -> Vector3:
	var angle := PI * 0.5  # due south (+Z)
	var r := coast_radius(angle) - SPAWN_INLAND
	return Vector3(0.0, 0.0, r)


func _scatter_props() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = SEED + 2
	var spawn := _spawn_point()
	var props := Node3D.new()
	props.name = "Props"
	add_child(props)
	for p in PROPS:
		var scene: PackedScene = load("res://assets/scenery/%s.glb" % p[0])
		var placed := 0
		var tries := 0
		while placed < p[1] and tries < 200:
			tries += 1
			var angle := rng.randf() * TAU
			var r := coast_radius(angle) - rng.randf_range(p[2], p[3])
			var x := cos(angle) * r
			var z := sin(angle) * r
			if Vector2(x - spawn.x, z - spawn.z).length() < SPAWN_CLEAR:
				continue
			var s := rng.randf_range(p[4], p[5])
			var inst := scene.instantiate() as Node3D
			inst.name = "%s_%d" % [p[0], placed]
			inst.position = Vector3(x, height(x, z) - p[6] * s, z)
			inst.rotation.y = rng.randf() * TAU
			inst.scale = Vector3.ONE * s
			props.add_child(inst)
			placed += 1


## The shadow cat (scripts/enemies/shadow_cat.gd), wandering the island on dry land.
func _place_cat() -> void:
	if Engine.is_editor_hint():
		return  # an Enemy: it only runs in the game
	var angle := PI * 0.5 + CAT_ANGLE
	var r := coast_radius(angle) - CAT_INLAND
	var x := cos(angle) * r
	var z := sin(angle) * r
	var cat := ShadowCat.new()
	cat.name = "ShadowCat"
	cat.position = Vector3(x, height(x, z) + 0.05, z)
	cat.wander_radius = COAST_RADIUS
	cat.can_stand = func(p: Vector3) -> bool: return inland(p.x, p.z) > CAT_SHORE
	add_child(cat)


## The lynx ranger (scripts/enemies/lynx_ranger.gd), strolling about on dry land.
func _place_lynx() -> void:
	if Engine.is_editor_hint():
		return  # it only runs in the game
	var angle := PI * 0.5 + LYNX_ANGLE
	var r := coast_radius(angle) - LYNX_INLAND
	var x := cos(angle) * r
	var z := sin(angle) * r
	var lynx := LynxRanger.new()
	lynx.name = "LynxRanger"
	lynx.position = Vector3(x, height(x, z) + 0.05, z)
	lynx.wander_radius = COAST_RADIUS
	lynx.can_stand = func(p: Vector3) -> bool: return inland(p.x, p.z) > LYNX_SHORE
	add_child(lynx)


## The dachshund (scripts/enemies/dachshund.gd), trotting about on dry land.
func _place_dog() -> void:
	if Engine.is_editor_hint():
		return  # it only runs in the game
	var angle := PI * 0.5 + DOG_ANGLE
	var r := coast_radius(angle) - DOG_INLAND
	var x := cos(angle) * r
	var z := sin(angle) * r
	var dog := Dachshund.new()
	dog.name = "Dachshund"
	dog.position = Vector3(x, height(x, z) + 0.05, z)
	dog.wander_radius = COAST_RADIUS
	dog.can_stand = func(p: Vector3) -> bool: return inland(p.x, p.z) > DOG_SHORE
	add_child(dog)


## The arcane eye (scripts/enemies/arcane_eye.gd), floating about over the island.
func _place_eye() -> void:
	if Engine.is_editor_hint():
		return  # it only runs in the game
	var angle := PI * 0.5 + EYE_ANGLE
	var r := coast_radius(angle) - EYE_INLAND
	var x := cos(angle) * r
	var z := sin(angle) * r
	var eye := ArcaneEye.new()
	eye.name = "ArcaneEye"
	eye.position = Vector3(x, height(x, z) + eye.hover_height, z)
	eye.wander_radius = COAST_RADIUS
	eye.can_hover = func(p: Vector3) -> bool: return inland(p.x, p.z) > 0.0
	add_child(eye)


## The jellyfish (scripts/enemies/jellyfish.gd), swimming through the air over the island
## and the shallows, above the waves when it's out over the sea (at height 0).
func _place_jellyfish() -> void:
	if Engine.is_editor_hint():
		return  # it only runs in the game
	var angle := PI * 0.5 + JELLY_ANGLE
	var r := coast_radius(angle) - JELLY_INLAND
	var x := cos(angle) * r
	var z := sin(angle) * r
	var jelly := Jellyfish.new()
	jelly.name = "Jellyfish"
	jelly.floor_min = 0.0
	jelly.position = Vector3(x, maxf(height(x, z), 0.0) + jelly.hover_height, z)
	jelly.wander_radius = COAST_RADIUS
	jelly.can_hover = func(p: Vector3) -> bool: return inland(p.x, p.z) > -JELLY_OFFSHORE
	add_child(jelly)


## Puts the player on the south beach looking out to sea (slightly along the shore),
## and makes that where they come back after dying.
func _place_player() -> void:
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player == null:
		return
	var at := _spawn_point()
	at.y = height(at.x, at.z) + 0.1
	player.set_spawn(Transform3D(Basis(Vector3.UP, PI + 0.45), at))
