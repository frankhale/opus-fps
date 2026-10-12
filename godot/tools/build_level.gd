extends SceneTree
## Builds res://scenes/level.tscn: a 72 x 72 m valley ringed by cliffs and mountains,
## with a dirt path running north to some ruins, a small village, a campsite, a pond
## with a bridge and a forest. Props are dropped onto the terrain surface.
##
## Regenerate with:
##   Godot --headless --path godot --script res://tools/build_level.gd
## (The result is an ordinary scene, so it can also just be edited by hand afterwards.)

const OUT := "res://scenes/level.tscn"
const PICKUP := preload("res://scripts/weapons/pickup.gd")
const TILE := 8.0
const HALF := 4  # tiles from the center to the edge: 9 x 9 tiles

var level: Node3D
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
	"tree_stump": 1.4, "log_fallen": 1.4, "bush": 1.5, "grass_tuft": 1.4, "flowers": 1.2,
	"rock_small": 1.5, "rock_large": 1.6, "rock_cluster": 1.6,
	"terrain_cliff": 2.0, "ruins_arch": 1.6, "ruins_pillar": 1.6, "stone_wall": 1.4,
	"watchtower": 1.5, "cabin": 1.25, "well": 1.15, "tent": 1.2, "campfire": 1.2,
	"lamp_post": 1.3, "signpost": 1.2, "fence_wood": 1.15, "fence_post": 1.15,
}
## Natural things also get some random size variation.
const VARIED := ["tree_pine", "tree_pine_tall", "tree_oak", "tree_dead", "bush", "grass_tuft",
	"rock_small", "rock_large", "rock_cluster"]
const LAMP_SCALE := 1.3


func _init() -> void:
	rng.seed = 1997
	size_rng.seed = 2024
	level = Node3D.new()
	level.name = "Level"
	for g in ["Terrain", "Backdrop", "Village", "Campsite", "Ruins", "Pond", "Nature", "Lights", "Pickups"]:
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
	build_nature()
	build_pickups()
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


func register_terrain(inst: Node3D) -> void:
	var mi: MeshInstance3D = inst.find_children("*", "MeshInstance3D", true, false)[0]
	var xf := inst.transform * mi.transform
	var raw := mi.mesh.get_faces()
	var faces := PackedVector3Array()
	faces.resize(raw.size())
	for i in raw.size():
		faces[i] = xf * raw[i]
	var p := inst.position
	terrain_faces.append({"min": Vector2(p.x - TILE / 2, p.z - TILE / 2),
		"max": Vector2(p.x + TILE / 2, p.z + TILE / 2), "faces": faces})


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
		return false  # path
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


func scatter(group: String, names: Array, count: int, margin: float, need_clear := true, rot_jitter := 360.0) -> void:
	var placed := 0
	var tries := 0
	while placed < count and tries < count * 40:
		tries += 1
		var x := rng.randf_range(-35.0 + margin, 35.0 - margin)
		var z := rng.randf_range(-35.0 + margin, 35.0 - margin)
		if need_clear and not is_clear(x, z):
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
	}
	for i in range(-HALF, HALF + 1):
		for j in range(-HALF, HALF + 1):
			var name: String = "terrain_dirt_path" if i == 0 else special.get(Vector2i(i, j), "terrain_grass")
			# Rotating plain tiles by 180 degrees hides the repetition of the grass pattern.
			var rot := 180.0 if (i + j) % 2 == 0 and name == "terrain_grass" else 0.0
			var t := place("Terrain", name, i * TILE, j * TILE, rot, 0.0)
			register_terrain(t)
	# Cliff walls around the edge; their rock face is the model's +Z side.
	var edge := HALF * TILE + TILE / 2 + 1.5 * WORLD_SCALE["terrain_cliff"]
	for k in range(-HALF, HALF + 1):
		place("Terrain", "terrain_cliff", k * TILE, -edge, 0.0, 0.0)
		place("Terrain", "terrain_cliff", k * TILE, edge, 180.0, 0.0)
		place("Terrain", "terrain_cliff", -edge, k * TILE, 90.0, 0.0)
		place("Terrain", "terrain_cliff", edge, k * TILE, -90.0, 0.0)
	for sx in [-1, 1]:
		for sz in [-1, 1]:
			place("Terrain", "rock_large", sx * (edge - 1.0), sz * (edge - 1.0), rng.randf_range(0, 360), -0.5, 3.5)


func build_backdrop() -> void:
	for k in 14:
		var a := TAU * k / 14.0 + rng.randf_range(-0.1, 0.1)
		var r := rng.randf_range(88.0, 108.0)
		place("Backdrop", "terrain_mountain", cos(a) * r, sin(a) * r, rng.randf_range(0, 360), -3.0,
			rng.randf_range(2.6, 3.6))


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
	place("Village", "tree_oak", -14.5, -5.5, 40.0)
	for z in [-18.0, -6.0, 6.0, 18.0]:
		place("Village", "lamp_post", -2.6, z)
		var lantern := Vector3(0.42, 1.98, 0.0) * LAMP_SCALE
		light("Lights", Vector3(-2.6 + lantern.x, ground(-2.6, z) + lantern.y, z), Color(1.0, 0.72, 0.38), 2.2, 9.0)
	place("Village", "signpost", 2.6, 14.0, 160.0)


func build_campsite() -> void:
	place("Campsite", "campfire", 8.5, 4.5)
	light("Lights", Vector3(8.5, ground(8.5, 4.5) + 0.7, 4.5), Color(1.0, 0.5, 0.18), 3.2, 11.0)
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


func build_pond() -> void:
	place("Pond", "bridge_wood", 16.0, -8.0, 0.0, 0.08)
	place("Pond", "tree_dead", 21.0, -4.0, 200.0)
	place("Pond", "rock_cluster", 11.5, -12.5, 140.0)
	place("Pond", "rock_small", 19.5, -12.0, 30.0)
	for k in 6:
		var a := TAU * k / 6.0 + 0.4
		place("Pond", "grass_tuft", 16.0 + cos(a) * 3.6, -8.0 + sin(a) * 3.6, rng.randf_range(0, 360))


func build_nature() -> void:
	scatter("Nature", ["tree_pine", "tree_pine", "tree_pine_tall"], 55, 2.5)
	scatter("Nature", ["tree_oak"], 8, 3.5)
	scatter("Nature", ["tree_dead", "tree_stump", "log_fallen"], 8, 3.0)
	scatter("Nature", ["rock_small", "rock_small", "rock_large", "rock_cluster"], 22, 2.0)
	scatter("Nature", ["bush"], 45, 1.0)
	scatter("Nature", ["grass_tuft"], 160, 0.5, false)
	scatter("Nature", ["flowers"], 40, 0.5, false)


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


func pickup(x: float, z: float, y: float) -> Area3D:
	var pk := Area3D.new()
	pk.set_script(PICKUP)
	pk.position = Vector3(x, y, z)
	groups["Pickups"].add_child(pk, true)
	pk.owner = level
	return pk
