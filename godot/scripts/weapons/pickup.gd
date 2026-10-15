@tool
class_name Pickup
extends Area3D
## A floating, spinning weapon, ammo, health, gem or powerup pickup. Walking into it hands
## it to the player; once taken it disappears and respawns after `respawn_time` seconds with
## a sparkle and a chime. Anything the player can't use (full ammo or health) stays put.
## Loot dropped by enemies is `one_shot` (never respawns) and expires after `lifetime`;
## gems are collectibles, so they are always taken for good, with a sparkle.
## With `random_spot` set, the pickup ignores where it was placed: when the game starts and
## each time it respawns it moves to a random open spot on the ground somewhere in the valley.
## Weapons glow in their projectile color so they stand out from afar: a beam of light
## rises from them and a soft halo surrounds them (materials/pickup_beam.gdshader, both
## widening with distance), the model shimmers and a light pulses.
## (@tool so the model also shows in the editor.)

enum Kind { WEAPON, AMMO, HEALTH, GEM, POWERUP }

const RESPAWN_SOUND := preload("res://assets/sfx/respawn.wav")
const HEAL_SOUND := preload("res://assets/sfx/heal.wav")
## Glow and sparkle color of gems (the gem model's green).
const GEM_COLOR := Color(0.45, 0.85, 0.25)
## Glow and sparkle color of the invulnerability powerup (its orb's cyan).
const POWERUP_COLOR := Color(0.35, 0.9, 1.0)
## Physics layer the player's body is on (bit value 2).
const PLAYER_LAYER := 2
## Random spots keep at least this far (m) from other random-spot pickups...
const SPOT_SPACING := 24.0
## ...and from the player, so nothing (re)appears right under them.
const SPOT_PLAYER_CLEARANCE := 15.0
## Stay this far (m) in from the edge of the ground, off the rising rim below the cliffs.
const SPOT_EDGE_MARGIN := 22.0
## Tiles a random spot may not use (water).
const SPOT_BAD_TILES := ["", "terrain_pond", "terrain_creek"]
const BEAM_SHADER := preload("res://materials/pickup_beam.gdshader")
const BEAM_HEIGHT := 9.0
## Visual layer bit for the beam and halo (layer 4), so the minimap's world-only
## snapshot skips them.
const BEAM_LAYER := 8

@export var kind := Kind.AMMO
@export var weapon: WeaponData
@export_enum("bullets", "shells", "rockets", "cells") var ammo_type := "bullets"
## Ammo rounds, health points for HEALTH pickups, or gems for GEM pickups.
@export var amount := 20
## Ammo/health model; weapons use their own model.
@export var model: PackedScene
@export var model_scale := 1.4
@export var respawn_time := 15.0
@export var hover_height := 0.45
@export var spin_speed := 1.8
## Loot: taken once, never respawns.
@export var one_shot := false
## Seconds before an untaken pickup vanishes (0 = never). It blinks near the end.
@export var lifetime := 0.0
## Moves to a random open spot at start and on every respawn (see the class notes).
@export var random_spot := false
## POWERUP only: what it grants, and for how many seconds.
@export_enum("invulnerability") var powerup := "invulnerability"
@export var duration := 15.0

var _model: Node3D
var _base_scale := Vector3.ONE
var _available := true
var _t := 0.0
var _age := 0.0
var _glow: OmniLight3D
## Weapons only: the beam, the halo, and the additive overlay that makes the model shimmer.
var _beam: MeshInstance3D
var _halo: MeshInstance3D
var _shimmer: StandardMaterial3D


func _ready() -> void:
	collision_layer = 0
	collision_mask = PLAYER_LAYER
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.9
	shape.shape = sphere
	shape.position.y = 0.6
	add_child(shape)

	var scene := weapon.model if kind == Kind.WEAPON and weapon else model
	if scene:
		_model = scene.instantiate()
		_base_scale = Vector3.ONE * (weapon.pickup_scale if kind == Kind.WEAPON and weapon else model_scale)
		_model.scale = _base_scale
		_model.position.y = hover_height
		add_child(_model)
	if kind == Kind.WEAPON and weapon or kind == Kind.GEM or kind == Kind.POWERUP:
		_glow = OmniLight3D.new()
		_glow.light_color = weapon.projectile_color if kind == Kind.WEAPON else _color()
		_glow.omni_range = 2.5
		_glow.light_energy = 0.8
		_glow.position.y = 0.5
		add_child(_glow)
	if kind == Kind.WEAPON and weapon and _model:
		_add_weapon_glow(weapon.projectile_color)
	if kind == Kind.GEM:
		one_shot = true

	if Engine.is_editor_hint():
		return
	_t = randf() * TAU
	body_entered.connect(_try_give)
	if random_spot:
		add_to_group("random_spot_pickups")
		# Hidden until the ground's collision is in the physics world to search.
		_available = false
		if _model:
			_model.visible = false
		await get_tree().physics_frame
		_move_to_random_spot()
		_available = true
		if _model:
			_model.visible = true


## The beam, the halo, the shimmer overlay on every mesh of the model, and a bigger light.
func _add_weapon_glow(color: Color) -> void:
	_glow.omni_range = 4.0
	_glow.light_energy = 1.5
	_shimmer = StandardMaterial3D.new()
	_shimmer.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_shimmer.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	for g: GeometryInstance3D in _model.find_children("*", "GeometryInstance3D", true, false):
		g.material_overlay = _shimmer

	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.25
	mesh.bottom_radius = 0.4
	mesh.height = BEAM_HEIGHT
	mesh.radial_segments = 12
	mesh.rings = 1
	mesh.cap_top = false
	mesh.cap_bottom = false
	var mat := ShaderMaterial.new()
	mat.shader = BEAM_SHADER
	mat.set_shader_parameter("color", color)
	mat.set_shader_parameter("height", BEAM_HEIGHT)
	_beam = _glow_mesh(mesh, mat)
	_beam.position.y = BEAM_HEIGHT / 2.0

	var quad := QuadMesh.new()
	quad.size = Vector2(2.4, 2.4)
	var halo_mat := mat.duplicate() as ShaderMaterial
	halo_mat.set_shader_parameter("halo", true)
	halo_mat.set_shader_parameter("strength", 0.8)
	_halo = _glow_mesh(quad, halo_mat)
	_halo.position.y = hover_height
	# The billboard moves its vertices in the shader; keep it from being culled early.
	_halo.extra_cull_margin = 8.0


func _glow_mesh(mesh: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.layers = BEAM_LAYER
	add_child(mi)
	return mi


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _model == null:
		return
	_t += delta
	_model.rotate_y(spin_speed * delta)
	_model.position.y = hover_height + sin(_t * 2.0) * 0.1
	if _beam:
		var shown := _available and _model.visible
		var pulse := 0.5 + 0.5 * sin(_t * 2.5)
		_beam.visible = shown
		_halo.visible = shown
		_glow.visible = shown
		_glow.light_energy = 1.1 + 0.8 * pulse
		_beam.material_override.set_shader_parameter("pulse", 0.7 + 0.3 * pulse)
		_halo.material_override.set_shader_parameter("pulse", 0.7 + 0.3 * pulse)
		var c := weapon.projectile_color * (0.35 + 0.35 * pulse)
		_shimmer.albedo_color = Color(c.r, c.g, c.b)
	if lifetime > 0.0 and _available:
		_age += delta
		if _age > lifetime - 3.0:
			_model.visible = fmod(_age * 8.0, 2.0) < 1.3  # blink before vanishing
		if _age > lifetime:
			queue_free()


## Toss the pickup out from `from` and let it drop onto the ground at its position.
func pop_from(from: Vector3) -> void:
	var landing := global_position
	global_position = from
	var tween := create_tween()
	tween.tween_property(self, "global_position", landing + Vector3(0, 0.8, 0), 0.25) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "global_position", landing, 0.3) \
		.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)


func _try_give(body: Node3D) -> void:
	if not _available:
		return
	var taken := false
	match kind:
		Kind.WEAPON, Kind.AMMO:
			var wm := body.get_node_or_null("WeaponManager")
			if wm == null:
				return
			taken = wm.give_weapon(weapon) if kind == Kind.WEAPON else wm.give_ammo(ammo_type, amount)
		Kind.HEALTH:
			if not body.has_method("heal"):
				return
			taken = body.heal(amount)
			if taken:
				_chime(HEAL_SOUND, get_parent())
		Kind.GEM:
			if not body.has_method("add_gems"):
				return
			taken = body.add_gems(amount)
			if taken:
				_chime(RESPAWN_SOUND, get_parent())
				var sparkle := FX.burst(GEM_COLOR, 24, 2.5, 0.08, 0.6, 1.0, 3.0)
				get_parent().add_child(sparkle)
				sparkle.global_position = global_position + Vector3(0, hover_height, 0)
				sparkle.emitting = true
				get_tree().create_timer(1.0).timeout.connect(sparkle.queue_free)
		Kind.POWERUP:
			if not body.has_method("give_powerup"):
				return
			taken = body.give_powerup(powerup, duration)
	if taken:
		_collect()


func _collect() -> void:
	_available = false
	var tween := create_tween()
	tween.tween_property(_model, "scale", _base_scale * 1.3, 0.06)
	tween.tween_property(_model, "scale", Vector3.ZERO, 0.1)
	if one_shot:
		tween.tween_callback(queue_free)
		return
	tween.tween_callback(func(): _model.visible = false)
	get_tree().create_timer(respawn_time).timeout.connect(_respawn)


func _respawn() -> void:
	if random_spot:
		_move_to_random_spot()
	_available = true
	_model.visible = true
	_model.scale = Vector3.ZERO
	create_tween().tween_property(_model, "scale", _base_scale, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var color := weapon.projectile_color if kind == Kind.WEAPON and weapon else _color()
	var sparkle := FX.burst(color, 24, 2.5, 0.08, 0.6, 1.0, 3.0)
	sparkle.position.y = hover_height
	add_child(sparkle)
	sparkle.emitting = true
	get_tree().create_timer(1.0).timeout.connect(sparkle.queue_free)
	_chime(RESPAWN_SOUND, self)
	# The player may already be standing on the spot.
	for body in get_overlapping_bodies():
		_try_give(body)


## 3D sound at the pickup; parented to `holder` so it outlives a freed pickup.
func _chime(stream: AudioStream, holder: Node) -> void:
	var s := AudioStreamPlayer3D.new()
	s.stream = stream
	s.unit_size = 4.0
	s.volume_db = -6.0
	holder.add_child(s)
	s.global_position = global_position
	s.play()
	s.finished.connect(s.queue_free)


func _color() -> Color:
	match kind:
		Kind.GEM:
			return GEM_COLOR
		Kind.POWERUP:
			return POWERUP_COLOR
	return Color(1.0, 0.85, 0.4)


## Picks a random spot on open, fairly level ground: not in water, under a roof or tree,
## or up against anything solid, and spread out from the other random-spot pickups and
## the player. Stays put if nothing fits.
func _move_to_random_spot() -> void:
	var terrain := get_tree().get_first_node_in_group("terrain") as Terrain
	if terrain == null:
		return
	var space := get_world_3d().direct_space_state
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var reach := terrain.extent() - SPOT_EDGE_MARGIN
	var spacing := SPOT_SPACING
	var probe := PhysicsShapeQueryParameters3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 1.0
	probe.shape = sphere
	for attempt in 400:
		if attempt > 0 and attempt % 100 == 0:
			spacing *= 0.6  # crowded: let them sit closer together
		var x := randf_range(-reach, reach)
		var z := randf_range(-reach, reach)
		if terrain.tile_at(x, z) in SPOT_BAD_TILES:
			continue
		# Straight down from high up: the first thing hit must be the ground itself.
		var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(x, 80.0, z), Vector3(x, -30.0, z)))
		if hit.is_empty() or not terrain.is_ancestor_of(hit.collider) or hit.normal.y < 0.9:
			continue
		var spot: Vector3 = hit.position
		if player and _flat_distance(spot, player.global_position) < SPOT_PLAYER_CLEARANCE:
			continue
		if _crowded(spot, spacing):
			continue
		probe.transform = Transform3D(Basis(), spot + Vector3(0, 1.3, 0))
		var blocked := false
		for r in space.intersect_shape(probe, 8):
			if not terrain.is_ancestor_of(r.collider) and not r.collider is CharacterBody3D:
				blocked = true
				break
		if blocked:
			continue
		global_position = spot
		return


func _crowded(spot: Vector3, spacing: float) -> bool:
	for other in get_tree().get_nodes_in_group("random_spot_pickups"):
		if other != self and _flat_distance(spot, other.global_position) < spacing:
			return true
	return false


static func _flat_distance(a: Vector3, b: Vector3) -> float:
	return Vector2(a.x - b.x, a.z - b.z).length()
