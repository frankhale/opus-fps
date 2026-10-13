extends SceneTree
## Builds res://scenes/level.tscn: a 184 x 184 m valley of rolling hills ringed by
## cliffs and mountains. The ground is a Terrain node (scripts/terrain.gd) that bends
## the terrain tiles over the hills; settlements and ponds sit on flat ground.
## A dirt road runs north past a village, a campsite and a pond to some ruins, and a
## crossroads south of the start leads west to a military outpost and east to a
## homestead. An overgrown graveyard and a second pond fill the north. Floating eyes
## guard each area and golems the north; weapons, ammo and health are spread around, and gems are tucked
## around every landmark. A pair of linked
## portals joins the west end of the crossroads road to the far north end of the main
## road. A creek crosses the south of the valley from cliff to cliff, under a bridge on
## the main road. Props are dropped onto the terrain surface.
##
## Regenerate with:
##   Godot --headless --path godot --script res://tools/build_level.gd
## (The result is an ordinary scene, so it can also just be edited by hand afterwards.)

const OUT := "res://scenes/level.tscn"
const PICKUP := preload("res://scripts/weapons/pickup.gd")
const EYE := preload("res://scripts/enemies/floating_eye.gd")
const GOLEM := preload("res://scripts/enemies/golem.gd")
const PORTAL := preload("res://scripts/portal.gd")
const CAMPFIRE := preload("res://scripts/campfire.gd")
const TERRAIN := preload("res://scripts/terrain.gd")
const GAS_CAN := preload("res://scripts/gas_can.gd")
const PHYSICS_PROP := preload("res://scripts/physics_prop.gd")
const EXPLOSIVE_BARREL := preload("res://scripts/explosive_barrel.gd")
const TILE := 8.0
const HALF := 11  # tiles from the center to the edge: 23 x 23 tiles
## Half-width of the walkable valley (cliff faces sit just beyond this).
const EXTENT := HALF * TILE + TILE / 2
## z of the east-west road through the crossroads.
const ROAD_Z := 40.0
## z of the creek running east-west across the south of the valley.
const CREEK_Z := 64.0

var level: Node3D
var terrain: Terrain
var groups := {}
var cache := {}
var terrain_faces: Array = []  # [{min: Vector2, max: Vector2, faces: PackedVector3Array}]
var rng := RandomNumberGenerator.new()
## Separate generator for size variation, so changing scales never shuffles the layout.
var size_rng := RandomNumberGenerator.new()

## The asset pack is modelled at strict real-world size, which reads as small and
## cramped in a first-person game. Scenery is scaled up here (trees and cliffs most,
## like most shooters do); things the player interacts with stay near human scale.
const WORLD_SCALE := {
	"tree_pine": 2.4, "tree_pine_tall": 2.2, "tree_oak": 2.0, "tree_dead": 1.8,
	"tree_stump": 1.4, "log_fallen": 1.4, "bush": 1.5, "bush_short": 1.3, "bush_tall": 1.2, "grass_tuft": 1.4, "flowers": 1.2,
	"rock_small": 1.5, "rock_large": 1.6, "rock_cluster": 1.6,
	"terrain_cliff": 2.0, "ruins_arch": 1.6, "ruins_pillar": 1.6, "stone_wall": 1.4,
	"watchtower": 1.5, "cabin": 1.25, "well": 1.15, "tent": 1.2, "campfire": 1.2,
	"lamp_post": 1.3, "signpost": 1.2, "fence_wood": 1.15, "fence_post": 1.15,
	"gas_can": 1.2,
}
## Natural things also get some random size variation.
const VARIED := ["tree_pine", "tree_pine_tall", "tree_oak", "tree_dead", "bush", "bush_short", "bush_tall", "grass_tuft",
	"rock_small", "rock_large", "rock_cluster"]
const LAMP_SCALE := 1.3


func _init() -> void:
	rng.seed = 1997
	size_rng.seed = 2024
	level = Node3D.new()
	level.name = "Level"
	for g in ["Terrain", "Backdrop", "Village", "Campsite", "Ruins", "Pond", "Crossroads", "Outpost", "Homestead",
			"Graveyard", "NorthPond", "Nature", "Lights", "Pickups", "Enemies", "Portals"]:
		var n := Node3D.new()
		n.name = g
		level.add_child(n)
		n.owner = level
		groups[g] = n
	build_terrain()
	build_backdrop()
	build_village()
	build_campsite()
	build_ruins()
	build_pond()
	build_crossroads()
	build_creek_crossing()
	build_outpost()
	build_homestead()
	build_graveyard()
	build_north_pond()
	build_nature()
	build_pickups()
	build_enemies()
	build_portals()
	clear_creek()
	var packed := PackedScene.new()
	var err := packed.pack(level)
	if err == OK:
		err = ResourceSaver.save(packed, OUT)
	print("level saved: ", OUT, " (", level.get_child_count(), " groups) err=", err)
	level.free()
	quit()


# ---------------------------------------------------------------------------
# Placement helpers
# ---------------------------------------------------------------------------
func scene(name: String) -> PackedScene:
	if not cache.has(name):
		for cat in ["terrain", "scenery", "pickups", "weapons", "enemies"]:
			var p := "res://assets/%s/%s.glb" % [cat, name]
			if ResourceLoader.exists(p):
				cache[name] = load(p)
				break
	return cache[name]


## `s` overrides the size; otherwise WORLD_SCALE (plus variation) applies.
func place(group: String, name: String, x: float, z: float, rot := 0.0, y = null, s := 0.0) -> Node3D:
	var inst: Node3D = scene(name).instantiate()
	inst.position = Vector3(x, ground(x, z) if y == null else y, z)
	inst.rotation_degrees.y = rot
	if s <= 0.0:
		s = WORLD_SCALE.get(name, 1.0)
		if name in VARIED:
			s *= size_rng.randf_range(0.85, 1.2)
	inst.scale = Vector3.ONE * s
	inst.name = name
	if name == "gas_can":
		inst.set_script(GAS_CAN)  # shootable: blows up
	elif name == "barrel":
		inst.set_script(PHYSICS_PROP)  # knocked about by shots, thrown by blasts
	elif name == "barrel_explosive":
		inst.set_script(EXPLOSIVE_BARREL)  # knocked about, and blows up like a gas can
	groups[group].add_child(inst, true)
	inst.owner = level
	return inst


func ground(x: float, z: float) -> float:
	var from := Vector3(x, 100.0, z)
	var best := 0.0
	for t in terrain_faces:
		if x < t.min.x or x > t.max.x or z < t.min.y or z > t.max.y:
			continue
		var f: PackedVector3Array = t.faces
		for i in range(0, f.size(), 3):
			var hit = Geometry3D.ray_intersects_triangle(from, Vector3.DOWN, f[i], f[i + 1], f[i + 2])
			if hit != null:
				best = hit.y
				return best
	return best


func light(group: String, pos: Vector3, color: Color, energy: float, light_range: float) -> void:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = color
	l.light_energy = energy
	l.omni_range = light_range
	groups[group].add_child(l, true)
	l.owner = level


# Areas kept clear of random trees/rocks.
func is_clear(x: float, z: float) -> bool:
	if absf(x) < 4.0:
		return false  # north-south road
	if absf(z - ROAD_Z) < 4.0:
		return false  # east-west road
	if x > -51 and x < -21 and z > 43 and z < 58:
		return false  # outpost
	if x > 21 and x < 51 and z > 43 and z < 58:
		return false  # homestead
	if x > -50 and x < -23 and z > -56 and z < -29:
		return false  # graveyard
	if Vector2(x - 32, z + 40).length() < 8.0:
		return false  # north pond
	if x > -17 and x < -1 and z > -18 and z < 9:
		return false  # village
	if x > 3 and x < 15 and z > -2 and z < 12:
		return false  # campsite
	if Vector2(x - 16, z + 8).length() < 7.0:
		return false  # pond
	if x > -11 and x < 9 and z > -35 and z < -17:
		return false  # ruins
	if Vector2(x - 20, z - 20).length() < 5.0:
		return false  # watchtower
	return true


## Low-frequency noise that gathers trees into groves, leaving open meadows between.
var groves := FastNoiseLite.new()


## With `grove` set, only places things where the grove noise is above it (lower = more cover).
func scatter(group: String, names: Array, count: int, margin: float, need_clear := true, rot_jitter := 360.0,
		grove := -INF) -> void:
	var placed := 0
	var tries := 0
	while placed < count and tries < count * 40:
		tries += 1
		var x := rng.randf_range(-EXTENT + 1.0 + margin, EXTENT - 1.0 - margin)
		var z := rng.randf_range(-EXTENT + 1.0 + margin, EXTENT - 1.0 - margin)
		if need_clear and not is_clear(x, z):
			continue
		if groves.get_noise_2d(x, z) < grove:
			continue
		var name: String = names[rng.randi() % names.size()]
		place(group, name, x, z, rng.randf_range(0, rot_jitter))
		placed += 1


# ---------------------------------------------------------------------------
# Areas
# ---------------------------------------------------------------------------
func build_terrain() -> void:
	var special := {
		Vector2i(2, -1): "terrain_pond",
		Vector2i(3, -1): "terrain_sand", Vector2i(3, -2): "terrain_sand", Vector2i(2, -2): "terrain_sand",
		Vector2i(-2, -2): "terrain_hill", Vector2i(-3, 1): "terrain_hill", Vector2i(3, 3): "terrain_hill",
		Vector2i(-3, 3): "terrain_hill", Vector2i(3, 1): "terrain_hill",
		# outer ring
		Vector2i(4, -5): "terrain_pond", Vector2i(3, -5): "terrain_sand", Vector2i(5, -5): "terrain_sand",
		Vector2i(4, -4): "terrain_sand", Vector2i(-4, 6): "terrain_sand", Vector2i(-5, 6): "terrain_sand",
		Vector2i(-6, -1): "terrain_hill", Vector2i(6, 2): "terrain_hill", Vector2i(-6, -6): "terrain_hill",
		Vector2i(6, -2): "terrain_hill", Vector2i(-2, -6): "terrain_hill", Vector2i(2, 7): "terrain_hill",
		Vector2i(-3, 7): "terrain_hill", Vector2i(6, 7): "terrain_hill", Vector2i(-6, 3): "terrain_hill",
		Vector2i(6, -6): "terrain_hill", Vector2i(-1, -6): "terrain_hill",
	}
	var road_j := int(ROAD_Z / TILE)
	var creek_j := int(CREEK_Z / TILE)
	var layout := PackedStringArray()
	for j in range(-HALF, HALF + 1):
		for i in range(-HALF, HALF + 1):
			var name: String = special.get(Vector2i(i, j), "terrain_grass")
			var rot := 0
			if j == creek_j:
				name = "terrain_creek"  # flowing west to east; the main road crosses on a bridge
			elif i == 0:
				name = "terrain_path_cross" if j == road_j else "terrain_dirt_path"
			elif j == road_j:
				name = "terrain_dirt_path"
				rot = 90
			elif name == "terrain_grass" and (i + j) % 2 == 0:
				rot = 180  # rotating plain tiles hides the repetition of the grass pattern
			layout.append("%s:%d" % [name, rot])
	terrain = TERRAIN.new()
	terrain.name = "Ground"
	terrain.half = HALF
	terrain.tiles = layout
	terrain.road_x = 0.0
	terrain.road_z = ROAD_Z
	terrain.creek_z = CREEK_Z
	# Settlements, ponds and the spawn sit on flat ground (the same areas is_clear() keeps
	# free of random trees); the hills fade in around them.
	terrain.flat_rects = [Rect2(-51, 43, 30, 15), Rect2(21, 43, 30, 15), Rect2(-50, -56, 27, 27),
		Rect2(-17, -18, 16, 27), Rect2(3, -2, 12, 14), Rect2(-11, -35, 20, 18)]
	terrain.flat_circles = PackedVector3Array([Vector3(32, -40, 8), Vector3(16, -8, 7), Vector3(20, 20, 5),
		Vector3(0, 30, 6), Vector3(0, ROAD_Z, 6), Vector3(-50, ROAD_Z, 4.5), Vector3(0, -50, 4.5)])
	terrain.keep_faces = true
	terrain.build()
	terrain_faces = terrain.tile_faces
	groups["Terrain"].add_child(terrain)
	terrain.owner = level
	# Cliff walls around the edge, their rock face (the model's +Z side) facing in. They
	# sit a little below the rising valley rim beside them.
	var edge := HALF * TILE + TILE / 2 + 1.5 * WORLD_SCALE["terrain_cliff"]
	var inner := HALF * TILE + TILE / 2 - 0.5
	for k in range(-HALF, HALF + 1):
		var x := k * TILE
		place("Terrain", "terrain_cliff", x, -edge, 0.0, terrain.height(x, -inner) - 1.0)
		place("Terrain", "terrain_cliff", x, edge, 180.0, terrain.height(x, inner) - 1.0)
		place("Terrain", "terrain_cliff", -edge, x, 90.0, terrain.height(-inner, x) - 1.0)
		place("Terrain", "terrain_cliff", edge, x, -90.0, terrain.height(inner, x) - 1.0)
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			place("Terrain", "rock_large", sx * (edge - 1.0), sz * (edge - 1.0), rng.randf_range(0, 360),
				terrain.height(sx * inner, sz * inner) - 0.5, 3.5)


func build_backdrop() -> void:
	for k in 18:
		var a := TAU * k / 18.0 + rng.randf_range(-0.1, 0.1)
		var r := rng.randf_range(185.0, 220.0)
		place("Backdrop", "terrain_mountain", cos(a) * r, sin(a) * r, rng.randf_range(0, 360), -4.0,
			rng.randf_range(5.2, 6.8))


func build_village() -> void:
	place("Village", "cabin", -9.5, 0.0, 90.0)
	place("Village", "cabin", -9.5, -11.0, 90.0)
	place("Village", "well", -4.8, -5.5, 15.0)
	var seg := 2.0 * WORLD_SCALE["fence_wood"]
	for k in 4:
		place("Village", "fence_wood", -14.0 + k * seg, 6.5)
	place("Village", "fence_post", -14.0 + 3.5 * seg, 6.5)
	for k in 2:
		place("Village", "fence_wood", -15.5, -16.5 + k * seg, 90.0)
	place("Village", "crate", -5.4, 3.7, 10.0)
	place("Village", "crate", -5.2, 4.9, -12.0)
	place("Village", "barrel", -6.3, 4.6)
	place("Village", "barrel", -5.6, -7.6)
	place("Village", "barrel_explosive", -6.0, -14.8)
	place("Village", "gas_can", -5.3, -15.4, 30.0)
	place("Village", "tree_oak", -14.5, -5.5, 40.0)
	for z in [-18.0, -6.0, 6.0, 18.0]:
		place("Village", "lamp_post", -2.6, z)
		var lantern := Vector3(0.42, 1.98, 0.0) * LAMP_SCALE
		light("Lights", Vector3(-2.6 + lantern.x, ground(-2.6, z) + lantern.y, z), Color(1.0, 0.72, 0.38), 2.2, 9.0)
	place("Village", "signpost", 2.6, 14.0, 160.0)


func build_campsite() -> void:
	campfire("Campsite", 8.5, 4.5)
	place("Campsite", "tent", 12.0, 2.0, -60.0)
	place("Campsite", "tent", 11.5, 8.0, -125.0)
	place("Campsite", "log_fallen", 6.4, 6.6, 35.0)
	place("Campsite", "tree_stump", 6.0, 2.4)
	place("Campsite", "crate", 13.6, 5.0, 20.0)
	place("Campsite", "watchtower", 20.0, 20.0, -20.0)


func build_ruins() -> void:
	place("Ruins", "ruins_arch", 0.0, -24.0)
	for p in [Vector3(-5.5, 0, -27.0), Vector3(5.0, 0, -29.0), Vector3(-3.5, 0, -31.5), Vector3(3.0, 0, -33.0)]:
		place("Ruins", "ruins_pillar", p.x, p.z, rng.randf_range(0, 360))
	place("Ruins", "stone_wall", -7.5, -22.5, 90.0)
	place("Ruins", "stone_wall", 7.0, -26.0, 75.0)
	place("Ruins", "stone_wall", -2.0, -34.0, 5.0)
	place("Ruins", "skull_pile", -3.0, -27.5)
	place("Ruins", "tree_dead", 6.5, -21.5, 70.0)
	place("Ruins", "rock_cluster", -9.0, -31.0, 30.0)
	place("Ruins", "barbed_wire", 8.5, -30.0, 130.0)
	place("Ruins", "barbed_wire", -6.5, -35.5, 280.0)


func build_pond() -> void:
	place("Pond", "bridge_wood", 16.0, -8.0, 0.0, 0.08)
	place("Pond", "tree_dead", 21.0, -4.0, 200.0)
	place("Pond", "rock_cluster", 11.5, -12.5, 140.0)
	place("Pond", "rock_small", 19.5, -12.0, 30.0)
	for k in 6:
		var a := TAU * k / 6.0 + 0.4
		place("Pond", "grass_tuft", 16.0 + cos(a) * 3.6, -8.0 + sin(a) * 3.6, rng.randf_range(0, 360))


## A campfire model with its burning effect (flames, embers, smoke and firelight).
func campfire(group: String, x: float, z: float) -> void:
	var model := place(group, "campfire", x, z)
	var fire := Node3D.new()
	fire.set_script(CAMPFIRE)
	fire.name = "Fire"
	model.add_child(fire)
	fire.owner = level
	fire.scale = Vector3.ONE / model.scale  # the effect is sized in world meters


func lamp(group: String, x: float, z: float, rot := 0.0) -> void:
	place(group, "lamp_post", x, z, rot)
	var lantern := Basis(Vector3.UP, deg_to_rad(rot)) * (Vector3(0.42, 1.98, 0.0) * LAMP_SCALE)
	light("Lights", Vector3(x + lantern.x, ground(x, z) + lantern.y, z + lantern.z), Color(1.0, 0.72, 0.38), 2.2, 9.0)


func fence_line(group: String, x0: float, z: float, count: int, skip := -1) -> void:
	var seg := 2.0 * WORLD_SCALE["fence_wood"]
	for k in count:
		if k != skip:
			place(group, "fence_wood", x0 + k * seg, z)
	place(group, "fence_post", x0 + (count - 0.5) * seg, z)


func build_crossroads() -> void:
	place("Crossroads", "signpost", 2.6, ROAD_Z + 2.6, 200.0)
	for x in [-14.0, 14.0, -30.0, 30.0]:
		lamp("Crossroads", x, ROAD_Z - 2.6)
	place("Crossroads", "rock_large", -6.0, ROAD_Z + 7.0, 30.0)
	place("Crossroads", "log_fallen", 8.0, ROAD_Z + 5.0, 80.0)
	# A wire roadblock on the west road, narrowing the way toward the outpost.
	place("Crossroads", "barbed_wire", -16.0, ROAD_Z - 3.0, 200.0)
	place("Crossroads", "barbed_wire", -16.4, ROAD_Z + 3.0, 45.0)


## A wooden bridge carries the main road over the creek.
func build_creek_crossing() -> void:
	place("Crossroads", "bridge_wood", 0.0, CREEK_Z, 0.0, 0.08, 1.3)


## Removes the scattered nature that landed in the creek. Done afterwards rather than by
## skipping those spots while scattering, so everything else keeps its place.
func clear_creek() -> void:
	for n: Node3D in groups["Nature"].get_children():
		if absf(n.position.z - CREEK_Z) < 4.5:
			groups["Nature"].remove_child(n)
			n.free()


## Abandoned military outpost: tents, a watchtower, supply stacks, shipping containers
## and a fenced yard ringed with barbed wire.
func build_outpost() -> void:
	var g := "Outpost"
	place(g, "watchtower", -46.0, 52.0, 15.0)
	place(g, "tent", -30.0, 52.0, 30.0)
	place(g, "tent", -35.0, 54.5, -15.0)
	place(g, "tent", -41.0, 48.0, 90.0)
	campfire(g, -35.0, 48.5)
	for c in [[-27.0, 46.0, 10.0], [-27.2, 47.3, -8.0], [-26.0, 46.6, 25.0], [-43.5, 55.0, 5.0]]:
		place(g, "crate", c[0], c[1], c[2])
	place(g, "crate", -26.8, 46.7, 40.0, ground(-26.8, 46.7) + 1.0)  # stacked
	for b in [Vector2(-28.6, 45.2), Vector2(-29.5, 45.8), Vector2(-24.8, 48.5)]:
		place(g, "barrel", b.x, b.y)
	for b in [Vector2(-44.0, 45.0), Vector2(-44.9, 45.7), Vector2(-31.0, 56.0)]:
		place(g, "barrel_explosive", b.x, b.y)
	fence_line(g, -49.0, 43.6, 11, 5)  # gap in the middle faces the road
	lamp(g, -24.5, 44.5)
	lamp(g, -48.0, 44.5)
	place(g, "stone_wall", -38.0, 57.0, 0.0)
	place(g, "stone_wall", -28.0, 57.0, 4.0)
	place(g, "skull_pile", -32.5, 49.5)
	# Shipping containers: a stack of two by the supply barrels on the east side, and one
	# behind the watchtower with its doors (+X) facing into the camp.
	place(g, "conex", -22.6, 51.0, 90.0)
	place(g, "conex", -22.5, 51.3, 93.0, ground(-22.6, 51.0) + 2.59)
	place(g, "conex", -47.0, 56.5, 0.0)
	# Barbed wire: coils in pairs along the front of the fence (the gateway left open) and
	# along the open west side.
	for c in [[-47.6, 42.2, 10.0], [-46.2, 42.3, 140.0], [-43.2, 42.1, 75.0], [-41.8, 42.3, 220.0],
			[-39.4, 42.2, 300.0], [-33.2, 42.2, 35.0], [-31.8, 42.1, 190.0], [-28.4, 42.3, 260.0],
			[-26.9, 42.2, 110.0], [-50.6, 46.5, 250.0], [-50.7, 49.0, 20.0], [-50.6, 54.5, 160.0]]:
		place(g, "barbed_wire", c[0], c[1], c[2])
	# Gas cans: a few by the supply barrels and a pair at the foot of the container stack.
	for c in [[-27.9, 44.7, 20.0], [-28.7, 44.5, -35.0], [-30.0, 45.0, 160.0], [-24.3, 49.0, 80.0],
			[-24.4, 49.7, 100.0]]:
		place(g, "gas_can", c[0], c[1], c[2])


## A lonely homestead: two cabins facing the road, a well, a fenced yard and oaks.
func build_homestead() -> void:
	var g := "Homestead"
	place(g, "cabin", 32.0, 51.0, 180.0)
	place(g, "cabin", 43.0, 52.5, 165.0)
	place(g, "well", 37.5, 46.0, 30.0)
	fence_line(g, 25.0, 57.0, 11)
	for z in [45.0, 47.3, 49.6, 51.9]:
		place(g, "fence_wood", 24.0, z, 90.0)
	place(g, "tree_oak", 27.5, 45.5, 60.0)
	place(g, "tree_oak", 48.0, 46.0, 200.0)
	place(g, "crate", 35.6, 55.0, 15.0)
	place(g, "barrel", 28.6, 55.0)
	place(g, "gas_can", 29.3, 55.5, -20.0)
	place(g, "barrel", 47.0, 55.5)
	place(g, "log_fallen", 40.0, 47.5, 10.0)
	place(g, "tree_stump", 45.0, 44.5)
	lamp(g, 36.0, 43.8)
	lamp(g, 29.0, 47.0, 180.0)


## Overgrown graveyard of broken ruins, skulls and dead trees.
func build_graveyard() -> void:
	var g := "Graveyard"
	place(g, "ruins_arch", -36.0, -31.0, 0.0)
	for p in [Vector2(-30, -38), Vector2(-42, -38), Vector2(-30, -48), Vector2(-42, -48), Vector2(-36, -51)]:
		place(g, "ruins_pillar", p.x, p.y, rng.randf_range(0, 360))
	place(g, "stone_wall", -45.0, -42.0, 90.0)
	place(g, "stone_wall", -27.0, -43.0, 85.0)
	place(g, "stone_wall", -36.0, -54.0, 0.0)
	place(g, "stone_wall", -40.0, -33.5, 8.0)
	for p in [Vector2(-35, -40), Vector2(-38.5, -45), Vector2(-33, -46.5), Vector2(-41, -51)]:
		place(g, "skull_pile", p.x, p.y, rng.randf_range(0, 360))
	for p in [Vector2(-40, -36), Vector2(-31, -35), Vector2(-46, -50), Vector2(-27, -51), Vector2(-36, -45)]:
		place(g, "tree_dead", p.x, p.y, rng.randf_range(0, 360))
	place(g, "rock_cluster", -48.0, -33.0, 20.0)
	place(g, "rock_large", -25.0, -55.0, 70.0)


func build_north_pond() -> void:
	var g := "NorthPond"
	place(g, "bridge_wood", 32.0, -40.0, 90.0, 0.08)
	place(g, "tree_dead", 37.5, -35.0, 140.0)
	place(g, "tree_dead", 26.0, -45.5, 20.0)
	place(g, "rock_cluster", 39.0, -46.0, 200.0)
	place(g, "rock_small", 25.5, -35.5, 60.0)
	place(g, "log_fallen", 27.0, -33.0, 25.0)
	for k in 8:
		var a := TAU * k / 8.0 + 0.2
		place(g, "grass_tuft", 32.0 + cos(a) * 3.7, -40.0 + sin(a) * 3.7, rng.randf_range(0, 360))


func build_nature() -> void:
	# Counts scale roughly with the map's area (2.35x the original 120 m valley); grass and
	# flowers less so, to keep the number of instances in check.
	groves.seed = 11
	groves.frequency = 0.03
	# Pines grow in groves; oaks stand alone out in the meadows.
	scatter("Nature", ["tree_pine", "tree_pine", "tree_pine_tall"], 230, 2.5, true, 360.0, 0.0)
	scatter("Nature", ["tree_oak"], 40, 3.5)
	scatter("Nature", ["tree_dead", "tree_stump", "log_fallen"], 36, 3.0)
	scatter("Nature", ["rock_small", "rock_small", "rock_large", "rock_cluster"], 110, 2.0)
	scatter("Nature", ["bush"], 200, 1.0)
	scatter("Nature", ["grass_tuft"], 600, 0.5, false)
	scatter("Nature", ["flowers"], 150, 0.5, false)
	# Shrubs: tall ones as undergrowth in and around the pine groves, short berry bushes
	# out in the open. Their own random state, so the rest of the layout stays put.
	var state := rng.state
	rng.seed = 4242
	scatter("Nature", ["bush_tall"], 70, 1.5, true, 360.0, -0.1)
	scatter("Nature", ["bush_short"], 120, 1.0)
	rng.state = state


func build_pickups() -> void:
	# Weapons: one per landmark, roughly in the order you reach them from the spawn.
	var weapons := [
		["pistol", 0.0, 24.0], ["shotgun", -4.2, -1.5], ["rifle", 9.5, 0.5],
		["plasma_rifle", 16.0, -8.0], ["rocket_launcher", 0.0, -28.5],
	]
	for it in weapons:
		var y := 0.08 if it[0] == "plasma_rifle" else ground(it[1], it[2])  # on the bridge deck
		var pk := pickup(it[1], it[2], y)
		pk.kind = PICKUP.Kind.WEAPON
		pk.weapon = load("res://weapons/%s.tres" % it[0])
		pk.respawn_time = 30.0
		pk.name = "weapon_" + it[0]
	# Ammo: [type, amount, model, positions]
	var ammo := [
		["bullets", 30, "pickup_ammo_bullets", [Vector2(2.5, 19), Vector2(-3, 9), Vector2(6, -13), Vector2(-12, 12), Vector2(22, 9)]],
		["shells", 8, "pickup_ammo_shells", [Vector2(-7.5, -7), Vector2(-14, 4), Vector2(4, -20), Vector2(13, -18)]],
		["rockets", 3, "pickup_ammo_rockets", [Vector2(-4.5, -30), Vector2(9, -27), Vector2(21, 25)]],
		["cells", 40, "pickup_ammo_cells", [Vector2(12, -11), Vector2(21, -13), Vector2(-20, -18), Vector2(-22, 20)]],
		# outer areas
		["bullets", 30, "pickup_ammo_bullets", [Vector2(-24, 37), Vector2(24, 37), Vector2(0, -44), Vector2(44, -24), Vector2(-46, 8)]],
		["shells", 8, "pickup_ammo_shells", [Vector2(-40, 51.5), Vector2(34, 54.5), Vector2(-30, -29)]],
		["rockets", 3, "pickup_ammo_rockets", [Vector2(-44, 48.5), Vector2(-38.5, -49)]],
		["cells", 40, "pickup_ammo_cells", [Vector2(36, -44.5), Vector2(-26, -46), Vector2(48, 8)]],
	]
	for a in ammo:
		for v in a[3]:
			var pk := pickup(v.x, v.y, ground(v.x, v.y))
			pk.kind = PICKUP.Kind.AMMO
			pk.ammo_type = a[0]
			pk.amount = a[1]
			pk.model = scene(a[2])
			pk.respawn_time = 15.0
			pk.name = "ammo_" + a[0]
	# Health: [amount, model, scale, positions]
	var health := [
		[40, "pickup_medkit", 1.4, [Vector2(-30, 46.5), Vector2(-36, -46.5), Vector2(40, 54.5), Vector2(-6.5, 1.5)]],
		[15, "pickup_health_vial", 2.0, [Vector2(12, -15), Vector2(1.5, -40), Vector2(24, 30), Vector2(-20, 30),
			Vector2(-14, -24), Vector2(44, 20)]],
	]
	for h in health:
		for v in h[3]:
			var pk := pickup(v.x, v.y, ground(v.x, v.y))
			pk.kind = PICKUP.Kind.HEALTH
			pk.amount = h[0]
			pk.model = scene(h[1])
			pk.model_scale = h[2]
			pk.respawn_time = 25.0
			pk.name = "health"
	# Gems: collectibles tucked around every landmark (and a few out in the wilds), taken
	# for good. A y of -1 means on the ground; otherwise on a bridge deck.
	var gems := [
		[-9.0, -16.0, -1], [-15.5, 3.0, -1],  # village
		[12.5, 11.0, -1], [4.5, -0.5, -1],  # campsite
		[20.0, 24.5, -1],  # under the watchtower
		[16.0, -6.5, 0.08], [21.5, -9.5, -1],  # pond
		[0.0, -31.0, -1], [-8.5, -25.0, -1],  # ruins
		[-45.0, -52.5, -1], [-28.5, -34.0, -1], [-37.0, -42.5, -1],  # graveyard
		[32.0, -40.0, 0.08], [38.5, -41.0, -1],  # north pond
		[-41.5, 51.0, -1], [-33.0, 55.5, -1],  # outpost
		[37.5, 49.5, -1], [46.0, 59.5, -1],  # homestead
		[6.0, 35.5, -1],  # crossroads
		[-20.0, 64.0, -1], [22.0, 64.5, -1],  # in the creek
	]
	for gm in gems:
		var y: float = ground(gm[0], gm[1]) if gm[2] < 0 else gm[2]
		var pk := pickup(gm[0], gm[1], y)
		pk.kind = PICKUP.Kind.GEM
		pk.amount = 1
		pk.model = scene("pickup_gem")
		pk.model_scale = 1.6
		pk.one_shot = true
		pk.name = "gem"


func pickup(x: float, z: float, y: float) -> Area3D:
	var pk := Area3D.new()
	pk.set_script(PICKUP)
	pk.position = Vector3(x, y, z)
	groups["Pickups"].add_child(pk, true)
	pk.owner = level
	return pk


## Floating eyes, roughly one per area, and three golems in the far north (the ruins,
## the graveyard and the north pond). None can see the spawn point, so the player has
## time to grab the pistol first.
func build_enemies() -> void:
	for v in [Vector2(0, -30), Vector2(16, -14), Vector2(26, 12), Vector2(-26, 12), Vector2(-36, 50),
			Vector2(38, 48), Vector2(-36, -42), Vector2(-30, -49), Vector2(32, -40)]:
		var eye := CharacterBody3D.new()
		eye.set_script(EYE)
		eye.name = "FloatingEye"
		eye.position = Vector3(v.x, ground(v.x, v.y) + 2.6, v.y)
		groups["Enemies"].add_child(eye, true)
		eye.owner = level
	for v in [Vector2(1.5, -29.0), Vector2(-36.0, -44.0), Vector2(32.0, -31.0)]:
		var golem := CharacterBody3D.new()
		golem.set_script(GOLEM)
		golem.name = "Golem"
		golem.position = Vector3(v.x, ground(v.x, v.y) + 0.85, v.y)
		groups["Enemies"].add_child(golem, true)
		golem.owner = level


## Two linked portals, each facing (+Z) back along its road: one at the west end of the
## crossroads road, one past the ruins at the north end of the main road.
func build_portals() -> void:
	var spots := {"PortalWest": [-50.0, ROAD_Z, 90.0], "PortalNorth": [0.0, -50.0, 0.0]}
	for n in spots:
		var s: Array = spots[n]
		var p := Node3D.new()
		p.set_script(PORTAL)
		p.name = n
		p.position = Vector3(s[0], ground(s[0], s[1]), s[1])
		p.rotation_degrees.y = s[2]
		p.exit_path = NodePath("../" + ("PortalNorth" if n == "PortalWest" else "PortalWest"))
		groups["Portals"].add_child(p)
		p.owner = level
