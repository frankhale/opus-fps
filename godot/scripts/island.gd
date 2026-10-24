@tool
class_name IslandScene
extends Node3D
## A small island in an open sea: the level in scenes/island.tscn, played with the dev
## console's `scene island`.
## The island is about 85 m across with a ragged, noisy coastline. A sandy beach 10 m wide
## rises gently from the water to grassy hills up to about 4 m high in the middle. Under
## the water the sand shelves away, gently through the shallows and then steeply down to
## about 9 m. The water is a tropical lagoon's: pale aqua over the sand near the shore,
## clear turquoise farther out and a deep sapphire past the drop-off.
## The ground is one mesh built here from height(), painted like the main level's terrain
## (scripts/terrain.gd): the pack's palette material, dimmed the same, with each face
## mapped onto one swatch as the tiles are: sand on the beach and under the water,
## grass inland, so the grass edge steps along the faces. The grassy ground is carpeted
## with clumps of grass (assets/scenery/grass_patch.glb). The sea
## (materials/sea.gdshader) is a 1.6 km sheet at height 0 that reaches the fog on every
## side, with surf rolling in to shore.
## You can wade out until the water is about 1 m deep, where invisible walls follow the
## coast round. All of that (ground, grass, sea, walls and the surf's sound) is built here when
## the node enters the tree, also in the editor.
##
## Everything standing on the island is an ordinary node saved in scenes/island.tscn, to
## move, turn, add or delete in the editor: rocks along the shore (the surf foams round
## them), trees, bushes and grass under Props; the ruins of an overgrown gateway among
## broken walls and columns under Ruins (move the group to move the whole site); the
## creatures (the shadow cat roams the island, the lynx ranger and a dachshund potter
## about on it, the arcane eye and a jellyfish float over it, a pair of lovebirds
## fly about over it, perching on things, a bat flits about over the back of it,
## butterflies flutter about the fountain and the meadow, settling on things, and a
## pumpkin crab scuttles about the beach along from where the player starts); and
## PlayerStart, where the player starts and comes back after dying. They're instances
## of the prefab library (res://prefabs/), so the creatures show their models in the
## editor. The ground is levelled round wherever Ruins stands, and the group settles
## onto that level; after moving it, press Rebuild ground in the Inspector (or reopen
## the scene) to re-level it.

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

const GROUND_MATERIAL := preload("res://materials/ps1_palette.tres")
const SEA_SHADER := preload("res://materials/sea.gdshader")
const SURF_SOUND := "res://assets/sfx/surf_loop.wav"
## Grass (GrassField) grows on the grassy ground, but not under the ruins (their paving
## and walls) or the props named here: the rocks, fallen trees and fountains.
const BARE_PROPS := ["rock", "tree_fallen", "fountain"]

## The ground is levelled for the ruins (the Ruins node), to the natural ground's height
## at the group's origin, out to RUIN_FLAT meters round it, blending back into the hills
## by RUIN_BLEND.
const RUIN_FLAT := 8.0
const RUIN_BLEND := 14.0
## How far the walking creatures keep from the water, and how far past the waterline
## the jellyfish may swim out over the shallows (meters).
const CAT_SHORE := 3.0
const LYNX_SHORE := 4.0
const DOG_SHORE := 3.0
## The pumpkin crab keeps to the beach: this far from the water, and no farther inland
## than CRAB_INLAND (unless it's chasing the player).
const CRAB_SHORE := 1.5
const CRAB_INLAND := 14.0
const JELLY_OFFSHORE := 6.0

## Inspector button: rebuilds the ground (and so re-levels it round the ruins).
@export_tool_button("Rebuild ground", "Reload") var rebuild_ground := build

var _coast := []  # [harmonic, amplitude, phase] for the coastline's wander
var _noise: FastNoiseLite
var _hills: FastNoiseLite
## The ruins' site and the level the ground is flattened to round it (no levelling
## without a Ruins node).
var _ruin_at := Vector2.ZERO
var _ruin_level := 0.0
var _levelled := false


func _ready() -> void:
	build()
	if not Engine.is_editor_hint():
		_place_player.call_deferred()  # once the world around it is ready


## Builds the ground, sea and walls (freeing any built before; the saved nodes stay), sets
## the ruins on their levelled ground, and in the game keeps the creatures to where they
## may go.
func build() -> void:
	for c in get_children():
		if c.owner == null:  # built here, not saved in the scene
			c.free()
	_setup_noise()
	var ruins := get_node_or_null("Ruins") as Node3D
	_levelled = ruins != null
	if ruins:
		_ruin_at = Vector2(ruins.position.x, ruins.position.z)
		_ruin_level = _natural_height(ruins.position.x, ruins.position.z)
		ruins.position.y = _ruin_level
	_build_ground()
	_build_grass()
	_build_sea()
	_build_walls()
	if not Engine.is_editor_hint():
		for c in get_children():
			if c is CharacterBody3D:
				_keep_on_island(c)
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


## Ground height at (x, z), with the sea's surface at 0: the island's natural ground,
## levelled round the ruins.
func height(x: float, z: float) -> float:
	var h := _natural_height(x, z)
	var d := Vector2(x, z).distance_to(_ruin_at)
	if _levelled and d < RUIN_BLEND:
		h = lerpf(h, _ruin_level, smoothstep(RUIN_BLEND, RUIN_FLAT, d))
	return h


func _natural_height(x: float, z: float) -> float:
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


## Scatters grass over the grassy ground, the same every time (it's seeded).
func _build_grass() -> void:
	var keep_off: Array[Node] = []
	var ruins := get_node_or_null("Ruins")
	if ruins:
		keep_off.append(ruins)
	var props := get_node_or_null("Props")
	if props:
		keep_off.append_array(props.get_children().filter(func(c: Node) -> bool:
			return BARE_PROPS.any(func(p: String) -> bool: return c.name.begins_with(p))))
	var ground := func(x: float, z: float) -> float:
		var h := height(x, z)
		return h if _is_grass(x, z, h) else NAN
	var grass := GrassField.build(Rect2(-GROUND_HALF, -GROUND_HALF, GROUND_HALF * 2.0, GROUND_HALF * 2.0),
		SEED + 7, ground, GrassField.bare_under(keep_off))
	if grass:
		add_child(grass)


func _build_sea() -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(SEA_SIZE, SEA_SIZE)
	# Smaller faces, so the vertex snapping behaves close to the camera.
	plane.subdivide_width = 63
	plane.subdivide_depth = 63
	var mat := ShaderMaterial.new()
	mat.shader = SEA_SHADER
	mat.render_priority = 1  # after the other see-through things, like the creek
	# The sea bed's height over the ground mesh's grid: the shader's water depth and
	# waterline come from it, steady where the snapping ground would make them flicker.
	var n := int(GROUND_HALF * 2.0 / GROUND_STEP) + 1
	var img := Image.create(n, n, false, Image.FORMAT_RF)
	for j in n:
		for i in n:
			img.set_pixel(i, j, Color(height(-GROUND_HALF + i * GROUND_STEP, -GROUND_HALF + j * GROUND_STEP), 0.0, 0.0))
	mat.set_shader_parameter("bed_map", ImageTexture.create_from_image(img))
	mat.set_shader_parameter("bed_origin", Vector2(-GROUND_HALF, -GROUND_HALF))
	mat.set_shader_parameter("bed_step", GROUND_STEP)
	mat.set_shader_parameter("bed_floor", SEA_BED)
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


## Keeps a creature to where it may go: the walkers on dry land, clear of the water, and
## the floaters over the island (the jellyfish also out over the shallows).
func _keep_on_island(creature: Node) -> void:
	if creature is Jellyfish:
		creature.can_hover = func(p: Vector3) -> bool: return inland(p.x, p.z) > -JELLY_OFFSHORE
	elif creature is ArcaneEye or creature is Lovebird or creature is Bat or creature is Butterfly:
		creature.can_hover = func(p: Vector3) -> bool: return inland(p.x, p.z) > 0.0
	elif creature is PumpkinCrab:
		creature.can_stand = func(p: Vector3) -> bool:
			var s := inland(p.x, p.z)
			return s > CRAB_SHORE and (s < CRAB_INLAND or creature.alerted)
	else:
		var shore := LYNX_SHORE if creature is LynxRanger else DOG_SHORE if creature is Dachshund else CAT_SHORE
		creature.can_stand = func(p: Vector3) -> bool: return inland(p.x, p.z) > shore


## Puts the player at PlayerStart (on the ground there, facing the way it faces), and
## makes that where they come back after dying.
func _place_player() -> void:
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var start := get_node_or_null("PlayerStart") as Node3D
	if player == null or start == null:
		return
	var at := start.global_position
	at.y = height(at.x, at.z) + 0.1
	player.set_spawn(Transform3D(Basis(Vector3.UP, start.global_rotation.y), at))
