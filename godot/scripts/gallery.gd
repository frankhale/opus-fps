@tool
class_name ModelGallery
extends Node3D
## Lays every model in the asset pack out on a flat floor so they can be looked at.
## Each category gets its own row (wrapping onto extra lines when long), with the
## category name written large above the middle of it and each model's name over it. Models
## are sorted by name, stand on the floor and keep their real size, except that the
## small categories are shown enlarged (see SCALE; the heading says by how much).
## The layout is built when the node enters the tree (also in the editor), straight
## from the files in res://assets/, so new models show up without editing anything.
## The player starts at z = 30 looking toward -Z: the first row is nearest.

## Rows from front to back: small things first so the big ones don't hide them.
const CATEGORIES := ["weapons", "pickups", "ammo", "viewmodel", "enemies", "scenery", "terrain"]
const SCALE := {"weapons": 2.0, "pickups": 1.5, "ammo": 4.0, "viewmodel": 2.0}
## Turned about Y (degrees) so they're seen side-on: weapons point their barrels -Z.
const TURN := {"weapons": 90.0}
## Gap between neighbouring models and between rows, in meters.
const GAP := 1.2
const ROW_GAP := 8.0
## A row wraps onto a new line past this width.
const MAX_WIDTH := 70.0
## z of the front edge of the first row.
const START_Z := 22.0

const FLOOR_COLOR := Color(0.36, 0.37, 0.36)
const HEADING_COLOR := Color(0.95, 0.85, 0.55)
const HEADING_SIZE := 96
const HEADING_PIXEL := 0.009
const NAME_SIZE := 48
const NAME_PIXEL := 0.004


func _ready() -> void:
	build()


func build() -> void:
	for c in get_children():
		c.free()
	var z := START_Z
	var min_x := 0.0
	var max_x := 0.0
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
			# Each model gets a slot at least as wide as its name label.
			var label_w := ThemeDB.fallback_font.get_string_size(n, HORIZONTAL_ALIGNMENT_LEFT, -1,
				NAME_SIZE).x * NAME_PIXEL
			items.append({"node": inst, "box": AABB(box.position * s, box.size * s),
				"slot": maxf(box.size.x * s, label_w)})
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
				_heading(row, title, Vector3(0.0, height + 1.4, z - depth))
				first = false
			for it in line:
				var box: AABB = it.box
				var inst: Node3D = it.node
				# Center each model in its slot and stand it on the floor.
				var mid: float = x + it.slot / 2.0
				inst.position = Vector3(mid - (box.position.x + box.size.x / 2.0), -box.position.y,
					cz - (box.position.z + box.size.z / 2.0))
				row.add_child(inst)
				_name_label(row, inst.name, Vector3(mid, minf(box.size.y, 8.0) + 0.3, cz))
				x += it.slot + GAP
			min_x = minf(min_x, -line_w / 2.0)
			max_x = maxf(max_x, line_w / 2.0)
			z -= depth + ROW_GAP
	_floor(Rect2(min_x - 10.0, z - 10.0, max_x - min_x + 20.0, START_Z + 30.0 - z))


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
func _heading(row: Node3D, text: String, at: Vector3) -> void:
	var label := _label(text, HEADING_SIZE, HEADING_PIXEL, HEADING_COLOR)
	label.name = "Heading"
	label.position = at
	row.add_child(label)


func _name_label(row: Node3D, text: String, at: Vector3) -> void:
	var label := _label(text, NAME_SIZE, NAME_PIXEL, Color(0.92, 0.92, 0.9))
	label.name = text + "_label"
	label.position = at
	row.add_child(label)


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


## A flat grey floor (x/z rectangle) with collision.
func _floor(area: Rect2) -> void:
	var body := StaticBody3D.new()
	body.name = "Floor"
	var mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = area.size
	var mat := StandardMaterial3D.new()
	mat.albedo_color = FLOOR_COLOR
	mat.roughness = 1.0
	plane.material = mat
	mesh.mesh = plane
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(area.size.x, 1.0, area.size.y)
	shape.shape = box
	shape.position.y = -0.5
	body.add_child(mesh)
	body.add_child(shape)
	body.position = Vector3(area.get_center().x, 0.0, area.get_center().y)
	add_child(body)


func _num(v: float) -> String:
	return str(int(v)) if v == floorf(v) else str(v)
