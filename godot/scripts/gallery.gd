@tool
class_name ModelGallery
extends Node3D
## Lays every model in the asset pack out on a grassy field so they can be looked at.
## Each category gets its own row (wrapping onto extra lines when long), with the
## category name written large above the middle of it and each model's name over it. Models
## are sorted by name, stand on the floor and keep their real size, except that the
## small categories are shown enlarged (see SCALE; the heading says by how much).
## The layout is built when the node enters the tree (also in the editor), straight
## from the files in res://assets/, so new models show up without editing anything.
## The player starts at z = 30 looking toward -Z: the first row is nearest. The ground is
## a Terrain node (scripts/terrain.gd) of grass tiles, square since that's what Terrain
## builds; every model, name and heading is dropped onto its gentle bumps. A wooden fence
## runs round the edge, backed by invisible walls so you can't jump it and fall off.
## The air is clear: in the game it turns off the world's fog, haze and ground mist.

## Rows from front to back: small things first so the big ones don't hide them.
const CATEGORIES := ["weapons", "pickups", "ammo", "viewmodel", "enemies", "scenery", "terrain"]
const SCALE := {"weapons": 2.0, "pickups": 1.5, "ammo": 4.0, "viewmodel": 2.0}
## Turned about Y (degrees) so they're seen side-on: weapons point their barrels -Z.
const TURN := {"weapons": 90.0}
## The campfire burns as it does in the game (scripts/campfire.gd), whose fire is sized
## for the model at its level scale.
const CAMPFIRE := preload("res://scripts/campfire.gd")
const CAMPFIRE_LEVEL_SCALE := 1.2
## The golem floats on its electric arcs (scripts/enemies/electric_arcs.gd) at the
## height it hovers in the game.
const GOLEM_HOVER := 0.85
## Gap between neighbouring models and between rows, in meters.
const GAP := 1.2
const ROW_GAP := 8.0
## A row wraps onto a new line past this width.
const MAX_WIDTH := 70.0
## z of the front edge of the first row.
const START_Z := 22.0

## Length of one fence_wood segment, in meters (it divides the 8 m ground tiles).
const FENCE_SEGMENT := 2.0
## Height of the invisible walls behind the fence.
const WALL_HEIGHT := 4.0
const HEADING_COLOR := Color(0.95, 0.85, 0.55)
const HEADING_SIZE := 96
const HEADING_PIXEL := 0.009
const NAME_SIZE := 48
const NAME_PIXEL := 0.004


func _ready() -> void:
	build()
	if not Engine.is_editor_hint():
		_clear_air.call_deferred()  # once the world around it is ready


## Turns off the world's distance fog, volumetric haze and ground mist, so the far rows
## are as easy to see as the near ones. Works on a copy of the environment, so the game's
## own stays as it is.
func _clear_air() -> void:
	var world := get_parent()
	var we := world.find_child("WorldEnvironment", false, false) as WorldEnvironment
	if we and we.environment:
		var env: Environment = we.environment.duplicate()
		env.fog_enabled = false
		env.volumetric_fog_enabled = false
		we.environment = env
	var mist := world.find_child("GroundMist", false, false) as FogVolume
	if mist:
		mist.visible = false


func build() -> void:
	for c in get_children():
		c.free()
	var z := START_Z
	var min_x := 0.0
	var max_x := 0.0
	# Everything standing on the ground, with the x/z area under it, to drop onto the
	# terrain once it's built: [[node, footprint], ...].
	var standing := []
	for cat in CATEGORIES:
		var names := _model_names(cat)
		if names.is_empty():
			continue
		var s: float = SCALE.get(cat, 1.0)
		var row := Node3D.new()
		row.name = cat.capitalize()
		add_child(row)
		# Instance everything first so each line's width and depth are known.
		var items := []
		for n in names:
			var inst: Node3D = load("res://assets/%s/%s.glb" % [cat, n]).instantiate()
			inst.name = n
			inst.scale = Vector3.ONE * s
			inst.rotation_degrees.y = TURN.get(cat, 0.0)
			var box := Transform3D(Basis(Vector3.UP, inst.rotation.y)) * _bounds(inst)
			if n == "enemy_golem":
				box = _float_golem(inst, box, s)
			# Each model gets a slot at least as wide as its name label.
			var label_w := ThemeDB.fallback_font.get_string_size(n, HORIZONTAL_ALIGNMENT_LEFT, -1,
				NAME_SIZE).x * NAME_PIXEL
			items.append({"node": inst, "box": AABB(box.position * s, box.size * s),
				"slot": maxf(box.size.x * s, label_w)})
			if n == "campfire":
				var fire := Node3D.new()
				fire.set_script(CAMPFIRE)
				fire.name = "Fire"
				fire.size = s / CAMPFIRE_LEVEL_SCALE
				fire.scale = Vector3.ONE / s  # the effect is sized in world meters
				inst.add_child(fire)
		var lines := [[]]
		var width := 0.0
		for it in items:
			var w: float = it.slot
			if width > 0.0 and width + w > MAX_WIDTH:
				lines.append([])
				width = 0.0
			lines[-1].append(it)
			width += w + GAP
		var first := true
		for line in lines:
			var line_w := -GAP
			var depth := 0.0
			var height := 0.0
			for it in line:
				line_w += it.slot + GAP
				depth = maxf(depth, it.box.size.z)
				height = maxf(height, minf(it.box.size.y, 8.0))
			var x := -line_w / 2.0
			var cz := z - depth / 2.0
			if first:
				var title: String = cat.to_upper() + ("" if s == 1.0 else "  (shown %s×)" % _num(s))
				var heading := _heading(row, title, Vector3(0.0, height + 1.4, z - depth))
				standing.append([heading, Rect2(0.0, z - depth, 0.0, 0.0)])
				first = false
			for it in line:
				var box: AABB = it.box
				var inst: Node3D = it.node
				# Center each model in its slot and stand it on the floor.
				var mid: float = x + it.slot / 2.0
				inst.position = Vector3(mid - (box.position.x + box.size.x / 2.0), -box.position.y,
					cz - (box.position.z + box.size.z / 2.0))
				row.add_child(inst)
				var footprint := Rect2(mid - box.size.x / 2.0, cz - box.size.z / 2.0, box.size.x, box.size.z)
				standing.append([inst, footprint])
				var label := _name_label(row, inst.name, Vector3(mid, minf(box.size.y, 8.0) + 0.3, cz))
				standing.append([label, footprint])
				x += it.slot + GAP
			min_x = minf(min_x, -line_w / 2.0)
			max_x = maxf(max_x, line_w / 2.0)
			z -= depth + ROW_GAP
	var area := Rect2(min_x - 10.0, z - 10.0, max_x - min_x + 20.0, START_Z + 30.0 - z)
	var ground := _ground(area)
	# The ground is a whole number of 8 m tiles, so the fence's 2 m segments fit it exactly.
	_fence(Rect2(ground.position.x - ground.extent(), ground.position.z - ground.extent(),
		2.0 * ground.extent(), 2.0 * ground.extent()))
	for s in standing:
		(s[0] as Node3D).position.y += _ground_height(ground, s[1])


## Hangs the arcs under the golem and returns its bounds stretched down to the ground,
## so it is laid out (and its name placed) floating at its in-game height.
func _float_golem(inst: Node3D, box: AABB, s: float) -> AABB:
	var arcs := ElectricArcs.new()
	arcs.name = "Arcs"
	arcs.color = Golem.CHARGE_COLOR
	arcs.drop = GOLEM_HOVER / s
	arcs.spread = Golem.ARC_SPREAD / s
	var points := PackedVector3Array()
	for p: Vector3 in Golem.LEG_POINTS:
		points.append(p)
	arcs.sources = points
	inst.add_child(arcs)
	var hover := GOLEM_HOVER / s
	return AABB(box.position - Vector3(0.0, hover, 0.0), box.size + Vector3(0.0, hover, 0.0))


## Model names in a category folder, sorted.
func _model_names(cat: String) -> Array:
	var out := []
	for f in DirAccess.get_files_at("res://assets/%s" % cat):
		# Exported builds only list the .import files.
		f = f.trim_suffix(".import")
		if f.ends_with(".glb") and not out.has(f.get_basename()):
			out.append(f.get_basename())
	out.sort()
	return out


## Bounding box of every mesh under `root`, in root's (unscaled) space.
func _bounds(root: Node3D) -> AABB:
	var box := AABB()
	var found := false
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		var xf := Transform3D.IDENTITY
		var n: Node = mi
		while n != root:
			xf = (n as Node3D).transform * xf
			n = n.get_parent()
		var b := xf * mi.get_aabb()
		box = b if not found else box.merge(b)
		found = true
	return box


## The category name, standing over the back of its row's first line.
func _heading(row: Node3D, text: String, at: Vector3) -> Label3D:
	var label := _label(text, HEADING_SIZE, HEADING_PIXEL, HEADING_COLOR)
	label.name = "Heading"
	label.position = at
	row.add_child(label)
	return label


func _name_label(row: Node3D, text: String, at: Vector3) -> Label3D:
	var label := _label(text, NAME_SIZE, NAME_PIXEL, Color(0.92, 0.92, 0.9))
	label.name = text + "_label"
	label.position = at
	row.add_child(label)
	return label


func _label(text: String, size: int, pixel: float, color: Color) -> Label3D:
	var label := Label3D.new()
	label.text = text
	label.font_size = size
	label.pixel_size = pixel
	label.modulate = color
	label.outline_size = size / 6
	label.outline_modulate = Color(0.05, 0.05, 0.06)
	label.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	return label


## Grass ground covering `area` (x/z rectangle): a Terrain of terrain_grass tiles with
## the hills turned off, the smallest square of tiles around the area's center.
func _ground(area: Rect2) -> Terrain:
	var tiles := ceili(maxf(area.size.x, area.size.y) / Terrain.TILE)
	var half := ceili((tiles - 1) / 2.0)  # Terrain grids are 2 * half + 1 tiles across
	var t := Terrain.new()
	t.name = "Ground"
	t.half = half
	t.inner_hill_height = 0.0
	t.outer_hill_height = 0.0
	t.rim_height = 0.0
	t.road_x = NAN
	t.road_z = NAN
	t.keep_faces = true
	var layout := PackedStringArray()
	for j in 2 * half + 1:
		for i in 2 * half + 1:
			# Turning every other tile hides the repetition of the grass pattern.
			layout.append("terrain_grass:%d" % (180 if (i + j) % 2 == 0 else 0))
	t.tiles = layout
	t.position = Vector3(area.get_center().x, 0.0, area.get_center().y)
	add_child(t)  # builds the meshes and collision
	return t


## Highest point of the ground over a footprint (x/z rectangle), so a model set there
## stands on the bumps instead of sinking into them.
func _ground_height(ground: Terrain, footprint: Rect2) -> float:
	var best := -INF
	for u in [0.0, 0.5, 1.0]:
		for v in [0.0, 0.5, 1.0]:
			var p := footprint.position + footprint.size * Vector2(u, v)
			best = maxf(best, _height_at(ground, p.x - ground.position.x, p.y - ground.position.z))
	return best


## Ground height at (x, z) in the terrain's own space, from its tile triangles.
func _height_at(ground: Terrain, x: float, z: float) -> float:
	var from := Vector3(x, 100.0, z)
	for t in ground.tile_faces:
		if x < t.min.x or x > t.max.x or z < t.min.y or z > t.max.y:
			continue
		var f: PackedVector3Array = t.faces
		for i in range(0, f.size(), 3):
			var hit = Geometry3D.ray_intersects_triangle(from, Vector3.DOWN, f[i], f[i + 1], f[i + 2])
			if hit != null:
				return hit.y
	return 0.0


## A wooden fence along the edge of `area` (x/z rectangle) and an invisible wall just
## outside each side.
func _fence(area: Rect2) -> void:
	var fence := Node3D.new()
	fence.name = "Fence"
	add_child(fence)
	var fence_wood: PackedScene = load("res://assets/scenery/fence_wood.glb")
	var a := area.position
	var b := area.end
	# Each side: start corner, direction and length. A segment's own post is at its -X end,
	# so laying each side from its start corner puts a post at every joint and corner.
	for side in [[Vector2(a.x, a.y), Vector2.RIGHT, area.size.x], [Vector2(b.x, a.y), Vector2.DOWN, area.size.y],
			[Vector2(b.x, b.y), Vector2.LEFT, area.size.x], [Vector2(a.x, b.y), Vector2.UP, area.size.y]]:
		var start: Vector2 = side[0]
		var dir: Vector2 = side[1]
		var count := roundi(side[2] / FENCE_SEGMENT)
		for k in count:
			var at: Vector2 = start + dir * FENCE_SEGMENT * (k + 0.5)
			var seg: Node3D = fence_wood.instantiate()
			seg.position = Vector3(at.x, 0.0, at.y)
			seg.rotation.y = -dir.angle()  # the segment runs along its local +X
			fence.add_child(seg)
	var walls := StaticBody3D.new()
	walls.name = "EdgeWalls"
	add_child(walls)
	var c := area.get_center()
	for w in [[Vector3(c.x, 0.0, a.y - 0.3), Vector3(area.size.x + 1.2, WALL_HEIGHT, 0.6)],
			[Vector3(c.x, 0.0, b.y + 0.3), Vector3(area.size.x + 1.2, WALL_HEIGHT, 0.6)],
			[Vector3(a.x - 0.3, 0.0, c.y), Vector3(0.6, WALL_HEIGHT, area.size.y + 1.2)],
			[Vector3(b.x + 0.3, 0.0, c.y), Vector3(0.6, WALL_HEIGHT, area.size.y + 1.2)]]:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = w[1]
		shape.shape = box
		shape.position = w[0] + Vector3(0.0, WALL_HEIGHT / 2.0, 0.0)
		walls.add_child(shape)


func _num(v: float) -> String:
	return str(int(v)) if v == floorf(v) else str(v)
