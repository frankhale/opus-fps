extends SceneTree
## Builds the prefab library in res://prefabs/: one ready-to-use scene per object in the
## game, to drag into any level. Each is set up the way the game uses it:
##   prefabs/scenery/  every scenery model at its game size (WORLD_SCALE), with its
##                     behaviour where it has one: barrels you can knock about,
##                     explosive barrels and gas cans that blow up, a burning campfire,
##                     a watchtower with a climbable ladder, a lamp post with its light,
##                     and the portal (set its exit or level, and title, in the Inspector)
##   prefabs/terrain/  the terrain tiles, cliffs and mountains
##   prefabs/pickups/  weapons, ammo, health, gems and the invulnerability powerup
##   prefabs/enemies/  floating eye, golem, spider, shadow cat, treant and pumpkin crab
##   prefabs/creatures/ the harmless island creatures: lynx ranger, dachshund, arcane eye,
##                     jellyfish and lovebird
## Enemies and creatures build their model when the game runs, so each carries an
## EditorPreview showing it in the editor.
##
## Existing prefabs are left alone (they may have been edited); new models get theirs.
## Run after adding models (generate_assets.py, then sync_godot_assets.py and an import):
##   Godot --headless --path godot --script res://tools/build_prefabs.gd
## Add `-- --force` to rebuild every prefab from scratch.

const OUT := "res://prefabs"
const PICKUP := preload("res://scripts/weapons/pickup.gd")

## The asset pack is modelled at strict real-world size, which reads as small and
## cramped in a first-person game, so the levels show scenery bigger (trees and cliffs
## most, like most shooters do); things the player handles stay near human scale. Each
## prefab is made at this size, so it comes into a level ready to use.
const WORLD_SCALE := {
	"tree_pine": 2.4, "tree_pine_tall": 2.2, "tree_oak": 2.0, "tree_dead": 1.8,
	"tree_stump": 1.4, "log_fallen": 1.4, "tree_fallen": 1.4, "bush": 1.5, "bush_short": 1.3, "bush_tall": 1.2, "grass_tuft": 1.4,
	"grass_patch": 1.3,
	"flowers": 1.2, "rock_small": 1.5, "rock_large": 1.6, "rock_cluster": 1.6,
	"terrain_cliff": 2.0, "ruins_arch": 1.6, "ruins_pillar": 1.6, "stone_wall": 1.4,
	"watchtower": 1.5, "cabin": 1.25, "well": 1.15, "tent": 1.2, "campfire": 1.2,
	"lamp_post": 1.3, "signpost": 1.2, "fence_wood": 1.15, "fence_post": 1.15,
	"gas_can": 1.2,
}
## Scenery with a behaviour script on the model.
const SCENERY_SCRIPTS := {
	"barrel": "res://scripts/physics_prop.gd",  # knocked about by shots, thrown by blasts
	"barrel_explosive": "res://scripts/explosive_barrel.gd",  # and blows up like a gas can
	"gas_can": "res://scripts/gas_can.gd",  # shootable: blows up
}
## The watchtower's ladder, on the model's +Z side, climbs to its deck (model units).
const TOWER_LADDER := Vector3(0.0, 0.0, 2.1)
const TOWER_DECK := 4.7
## The lamp post's lantern (model units) and its light.
const LANTERN := Vector3(0.42, 1.98, 0.0)
const LANTERN_COLOR := Color(1.0, 0.72, 0.38)
const LANTERN_ENERGY := 2.2
const LANTERN_RANGE := 9.0

## Pickups: name -> its settings (Pickup's exported properties).
const PICKUPS := {
	"weapon_pistol": {"kind": "WEAPON", "weapon": "pistol"},
	"weapon_shotgun": {"kind": "WEAPON", "weapon": "shotgun"},
	"weapon_rifle": {"kind": "WEAPON", "weapon": "rifle"},
	"weapon_plasma_rifle": {"kind": "WEAPON", "weapon": "plasma_rifle"},
	"weapon_rocket_launcher": {"kind": "WEAPON", "weapon": "rocket_launcher"},
	"ammo_bullets": {"kind": "AMMO", "ammo_type": "bullets", "amount": 30, "model": "pickup_ammo_bullets"},
	"ammo_shells": {"kind": "AMMO", "ammo_type": "shells", "amount": 8, "model": "pickup_ammo_shells"},
	"ammo_rockets": {"kind": "AMMO", "ammo_type": "rockets", "amount": 3, "model": "pickup_ammo_rockets"},
	"ammo_cells": {"kind": "AMMO", "ammo_type": "cells", "amount": 40, "model": "pickup_ammo_cells"},
	"health_medkit": {"kind": "HEALTH", "amount": 40, "model": "pickup_medkit", "model_scale": 1.4,
		"respawn_time": 25.0},
	"health_vial": {"kind": "HEALTH", "amount": 15, "model": "pickup_health_vial", "model_scale": 2.0,
		"respawn_time": 25.0},
	"gem": {"kind": "GEM", "amount": 1, "model": "pickup_gem", "model_scale": 1.6, "one_shot": true},
	"powerup_invulnerability": {"kind": "POWERUP", "powerup": "invulnerability", "duration": 15.0,
		"model": "powerup_invulnerability", "model_scale": 1.6, "respawn_time": 60.0},
}
## Enemies and creatures: name -> [category, script, its model's scale and whether it's
## turned round (as the script sets the model up when the game runs)].
const ACTORS := {
	"floating_eye": ["enemies", "res://scripts/enemies/floating_eye.gd", 1.6, true],
	"golem": ["enemies", "res://scripts/enemies/golem.gd", 1.15, true],
	"spider": ["enemies", "res://scripts/enemies/spider.gd", 1.25, true],
	"shadow_cat": ["enemies", "res://scripts/enemies/shadow_cat.gd", 1.0, true],
	"treant": ["enemies", "res://scripts/enemies/treant.gd", 1.15, true],
	"pumpkin_crab": ["enemies", "res://scripts/enemies/pumpkin_crab.gd", 1.0, true],
	"lynx_ranger": ["creatures", "res://scripts/enemies/lynx_ranger.gd", 1.0, true],
	"dachshund": ["creatures", "res://scripts/enemies/dachshund.gd", 1.0, true],
	"arcane_eye": ["creatures", "res://scripts/enemies/arcane_eye.gd", 1.3, true],
	"jellyfish": ["creatures", "res://scripts/enemies/jellyfish.gd", 1.0, false],
	"lovebird": ["creatures", "res://scripts/enemies/lovebird.gd", 1.0, true],
}

var force := false
var made := 0
var kept := 0


func _initialize() -> void:
	force = "--force" in OS.get_cmdline_user_args()
	for cat in ["scenery", "terrain"]:
		for f in DirAccess.get_files_at("res://assets/%s" % cat):
			if f.ends_with(".glb"):
				var name := f.get_basename()
				if name == "portal":
					_save("scenery", name, _portal())
				else:
					_save_model(cat, name)
	for name in PICKUPS:
		_save("pickups", name, _pickup(name))
	for name in ACTORS:
		_save(ACTORS[name][0], name, _actor(name))
	print("prefabs: %d made, %d already there (kept)" % [made, kept])
	quit()


## Packs `root` into prefabs/<cat>/<name>.tscn (unless it's there and not --force).
func _save(cat: String, name: String, root: Node) -> void:
	var path := "%s/%s/%s.tscn" % [OUT, cat, name]
	if ResourceLoader.exists(path) and not force:
		kept += 1
		root.free()
		return
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	root.name = name
	var scene := PackedScene.new()
	var err := scene.pack(root)
	if err == OK:
		err = ResourceSaver.save(scene, path)
	if err != OK:
		push_error("couldn't save %s (%d)" % [path, err])
	made += 1
	root.free()


## A child of the prefab's root, saved with it.
func _add(root: Node, child: Node) -> Node:
	root.add_child(child)
	child.owner = root
	return child


## A scenery or terrain model at its game size, with its behaviour if it has one. It's
## written as an inherited scene of the model, so the prefab links to the model (and
## follows it when it's regenerated) rather than keeping a copy of it.
func _save_model(cat: String, name: String) -> void:
	var path := "%s/%s/%s.tscn" % [OUT, cat, name]
	if ResourceLoader.exists(path) and not force:
		kept += 1
		return
	var s: float = WORLD_SCALE.get(name, 1.0)
	var res := ['[ext_resource type="PackedScene" path="res://assets/%s/%s.glb" id="model"]' % [cat, name]]
	var root := ['[node name="%s" instance=ExtResource("model")]' % name, "transform = " + _xf(Vector3.ONE * s, Vector3.ZERO)]
	if SCENERY_SCRIPTS.has(name):
		res.append('[ext_resource type="Script" path="%s" id="script"]' % SCENERY_SCRIPTS[name])
		root.append('script = ExtResource("script")')
	var nodes := ["\n".join(root)]
	match name:
		"campfire":
			# Flames, embers, smoke and firelight; the effect is sized in world meters.
			res.append('[ext_resource type="Script" path="res://scripts/campfire.gd" id="fire"]')
			nodes.append("\n".join(['[node name="Fire" type="Node3D" parent="."]',
				"transform = " + _xf(Vector3.ONE / s, Vector3.ZERO), 'script = ExtResource("fire")']))
		"watchtower":
			res.append('[ext_resource type="Script" path="res://scripts/ladder.gd" id="ladder"]')
			nodes.append("\n".join(['[node name="Ladder" type="Area3D" parent="."]',
				"transform = " + _xf(Vector3.ONE, TOWER_LADDER), 'script = ExtResource("ladder")',
				"height = %s" % TOWER_DECK]))
		"lamp_post":
			# Counter-scaled, so its range is the same in meters whatever the lamp's size.
			nodes.append("\n".join(['[node name="Light" type="OmniLight3D" parent="."]',
				"transform = " + _xf(Vector3.ONE / s, LANTERN), "light_color = Color(%s, %s, %s, 1)" % [_n(LANTERN_COLOR.r),
				_n(LANTERN_COLOR.g), _n(LANTERN_COLOR.b)], "light_energy = %s" % LANTERN_ENERGY, "omni_range = %s" % LANTERN_RANGE]))
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("[gd_scene format=3]\n\n" + "\n".join(res) + "\n\n" + "\n\n".join(nodes) + "\n")
	f.close()
	if not (load(path) is PackedScene):
		push_error("couldn't load %s back" % path)
	made += 1


## A transform for a .tscn: a uniform scale and a position.
func _xf(scale: Vector3, pos: Vector3) -> String:
	return "Transform3D(%s, 0, 0, 0, %s, 0, 0, 0, %s, %s, %s, %s)" % [_n(scale.x), _n(scale.y), _n(scale.z),
		_n(pos.x), _n(pos.y), _n(pos.z)]


## A number for a .tscn, without float noise (1.3, not 1.29999995).
func _n(v: float) -> String:
	return str(snappedf(v, 0.000001))


## A portal (scripts/portal.gd): set its exit, or a level and title, where it's used.
func _portal() -> Node3D:
	var root := Node3D.new()
	root.set_script(load("res://scripts/portal.gd"))
	return root


func _pickup(name: String) -> Area3D:
	var root := Area3D.new()
	root.set_script(PICKUP)
	var cfg: Dictionary = PICKUPS[name]
	for key in cfg:
		var v = cfg[key]
		match key:
			"kind":
				v = PICKUP.Kind[v]
			"weapon":
				v = load("res://weapons/%s.tres" % v)
			"model":
				v = load("res://assets/pickups/%s.glb" % v)
		root.set(key, v)
	if cfg["kind"] == "WEAPON":
		root.respawn_time = 30.0
	return root


## An enemy or creature, with an editor-only preview of its model.
func _actor(name: String) -> CharacterBody3D:
	var cfg: Array = ACTORS[name]
	var root := CharacterBody3D.new()
	var script: GDScript = load(cfg[1])
	root.set_script(script)
	var preview := Node3D.new()
	preview.name = "EditorPreview"
	preview.set_script(load("res://scripts/editor_preview.gd"))
	preview.model = script.get_script_constant_map()["MODEL"]
	preview.scale = Vector3.ONE * cfg[2]
	if cfg[3]:
		preview.rotation.y = PI  # the models face their +Z; the actors face -Z
	_add(root, preview)
	return root
