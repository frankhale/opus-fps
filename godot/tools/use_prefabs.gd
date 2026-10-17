extends SceneTree
## Converts scenes to use the prefab library (res://prefabs/, see build_prefabs.gd):
## every object placed straight from a model (res://assets/...glb) or set up by hand from
## a script (pickups, enemies, creatures, portals) becomes an instance of its prefab, with
## the same name, transform and settings. Anything added under an object in the scene
## carries over: onto the prefab's own part of the same name (a watchtower's Ladder, a
## campfire's Fire), or moved across with it. A lamp post's separate light, at its
## lantern, is dropped, since the lamp prefab has its own.
##   Godot --headless --path godot --script res://tools/use_prefabs.gd -- res://scenes/level.tscn [...]

const PREFABS := "res://prefabs"
const PICKUP := preload("res://scripts/weapons/pickup.gd")
## Scripted objects: script file -> prefab (pickups are sorted by what they give).
const SCRIPTED := {
	"portal.gd": "scenery/portal",
	"floating_eye.gd": "enemies/floating_eye", "golem.gd": "enemies/golem", "spider.gd": "enemies/spider",
	"shadow_cat.gd": "enemies/shadow_cat", "lynx_ranger.gd": "creatures/lynx_ranger",
	"dachshund.gd": "creatures/dachshund", "arcane_eye.gd": "creatures/arcane_eye",
	"jellyfish.gd": "creatures/jellyfish",
}

var _converted := 0


func _initialize() -> void:
	for path in OS.get_cmdline_user_args():
		_convert(path)
	quit()


func _convert(path: String) -> void:
	var root := (load(path) as PackedScene).instantiate()
	_converted = 0
	var lamps: Array[Node3D] = []
	for node in _owned(root):
		if not is_instance_valid(node):
			continue  # a part of an object already replaced, which its prefab supplies
		var prefab := _prefab_for(node)
		if prefab != "":
			var made := _replace(root, node, prefab)
			if prefab.ends_with("/lamp_post.tscn"):
				lamps.append(made)
	var dropped := _drop_lamp_lights(root, lamps)
	var scene := PackedScene.new()
	var err := scene.pack(root)
	if err == OK:
		err = ResourceSaver.save(scene, path)
	print("%s: %d objects now prefabs, %d lamp lights folded into their lamps (err %d)" % [path, _converted, dropped, err])
	root.free()


## The scene's own nodes (not the insides of instanced scenes), parents before children.
func _owned(root: Node) -> Array[Node]:
	var out: Array[Node] = []
	var queue: Array[Node] = [root]
	while not queue.is_empty():
		var n: Node = queue.pop_front()
		if n != root:
			out.append(n)
		for c in n.get_children():
			if c.owner == root:
				queue.append(c)
	return out


## The prefab for a node, or "" if it isn't an object with one.
func _prefab_for(node: Node) -> String:
	var file := node.scene_file_path
	if file.begins_with("res://assets/") and file.ends_with(".glb"):
		var p := "%s/%s/%s.tscn" % [PREFABS, file.get_base_dir().get_file(), file.get_file().get_basename()]
		return p if ResourceLoader.exists(p) else ""
	if file != "" or node.get_script() == null:
		return ""
	var script_file: String = node.get_script().resource_path.get_file()
	if script_file == "pickup.gd":
		return "%s/pickups/%s.tscn" % [PREFABS, _pickup_name(node)]
	return "%s/%s.tscn" % [PREFABS, SCRIPTED[script_file]] if SCRIPTED.has(script_file) else ""


func _pickup_name(pk: Node) -> String:
	match pk.kind:
		PICKUP.Kind.WEAPON:
			return "weapon_" + pk.weapon.resource_path.get_file().get_basename()
		PICKUP.Kind.AMMO:
			return "ammo_" + pk.ammo_type
		PICKUP.Kind.HEALTH:
			return "health_medkit" if pk.model.resource_path.ends_with("pickup_medkit.glb") else "health_vial"
		PICKUP.Kind.GEM:
			return "gem"
	return "powerup_" + pk.powerup


## Puts an instance of `prefab` in place of `old`, keeping its name, transform, settings
## and anything added under it.
func _replace(root: Node, old: Node, prefab: String) -> Node:
	var made := (load(prefab) as PackedScene).instantiate()
	_copy_settings(old, made)
	if old is Node3D:
		made.transform = old.transform
	var parent := old.get_parent()
	parent.add_child(made)
	parent.move_child(made, old.get_index())
	made.owner = root
	for c in old.get_children():
		if c.owner != root:
			continue  # part of the old model itself
		var part := made.get_node_or_null(NodePath(c.name))
		if part and part.get_class() == c.get_class() and part.get_script() == c.get_script():
			_copy_settings(c, part)  # the prefab has this part: keep the scene's tweaks to it
			if c is Node3D:
				part.transform = c.transform
		else:
			# Moved across with its own nodes, owned by the scene again once moved.
			var moved: Array[Node] = [c]
			moved.append_array(c.find_children("*", "", true, false).filter(func(n: Node) -> bool: return n.owner == root))
			for n in moved:
				n.owner = null
			c.reparent(made, false)
			for n in moved:
				n.owner = root
	var node_name := old.name
	parent.remove_child(old)
	old.free()
	made.name = node_name
	_converted += 1
	return made


## Copies `from`'s script settings (its exported variables) onto `to`, where they differ.
func _copy_settings(from: Node, to: Node) -> void:
	if from.get_script() == null:
		return
	for p in from.get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE and p.usage & PROPERTY_USAGE_STORAGE and p.name in to:
			if to.get(p.name) != from.get(p.name):
				to.set(p.name, from.get(p.name))


## Removes standalone lights sitting at a lamp post's lantern (the lamp prefab has its
## own light there), and their group if that leaves it empty. Returns how many.
func _drop_lamp_lights(root: Node, lamps: Array[Node3D]) -> int:
	var dropped := 0
	var spots: Array[Vector3] = []
	for lamp in lamps:
		var light := lamp.get_node("Light") as Node3D
		spots.append(_global(root, lamp) * light.position)
	for node in _owned(root):
		if node is OmniLight3D:  # (the lamps' own lights are the prefab's, not the scene's)
			var at := _global(root, node).origin
			for spot in spots:
				if at.distance_to(spot) < 0.05:
					var group := node.get_parent()
					group.remove_child(node)
					node.free()
					dropped += 1
					if group != root and group.get_child_count() == 0 and group.get_script() == null:
						group.get_parent().remove_child(group)
						group.free()
					break
	return dropped


## A node's transform relative to the scene's root (the scene isn't in a tree).
func _global(root: Node, node: Node3D) -> Transform3D:
	var xf := node.transform
	var p := node.get_parent()
	while p != root and p is Node3D:
		xf = p.transform * xf
		p = p.get_parent()
	return xf
