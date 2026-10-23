class_name Enemy
extends CharacterBody3D
## What every enemy shares: it idles near home until the player comes within
## `aggro_radius` of it (shown by a see-through dark red ring on the ground) or shoots
## it, then hunts them. It gives up once the player gets `deaggro_range` away (a shot
## from farther keeps it after them for `memory` seconds), stays out of sight for
## `memory` seconds, or it strays `leash` from home, and drifts back. Shots flash it
## and knock it back, and show a health bar over it (EnemyHealthBar) that fades a few
## seconds after the last hit; when killed it hides its model, drops loot (ammo for the player's
## weapons or health, and gems) and respawns at home a while later, out of the player's sight.
## A subclass builds its own body in _ready() (calling _setup() for the model, sounds,
## hit flash and health bar), moves and attacks in _physics_process(), and can hook into the
## events below (_on_alert, _on_lost_sight, _on_death, _on_respawn).

const LOOT_HEALTH_MODEL := preload("res://assets/pickups/pickup_health_vial.glb")
const GEM_MODEL := preload("res://assets/pickups/pickup_gem.glb")
const AMMO_MODELS := {
	"bullets": preload("res://assets/pickups/pickup_ammo_bullets.glb"),
	"shells": preload("res://assets/pickups/pickup_ammo_shells.glb"),
	"rockets": preload("res://assets/pickups/pickup_ammo_rockets.glb"),
	"cells": preload("res://assets/pickups/pickup_ammo_cells.glb"),
}
## Loot amounts are half an ammo box.
const LOOT_AMMO := {"bullets": 15, "shells": 4, "rockets": 2, "cells": 20}
## Physics layer bit for enemies (layer 3).
const ENEMY_LAYER := 4
## Visual layer bit for enemy models and aggro rings (layer 3), so a ring's decal skips
## its enemy and the minimap's world-only snapshot leaves both out.
const ENEMY_VISUAL_LAYER := 4
const RING_COLOR := Color(0.4, 0.02, 0.02)
## Height of the ring's decal box, centered on the ground under the enemy.
const RING_DEPTH := 4.0
## Gap between the top of its model and its health bar (m).
const BAR_GAP := 0.35

@export var max_health := 80.0
## It notices the player within this many meters (across the ground) if it can see them.
@export var aggro_radius := 5.0
## Once hunting, it gives up as soon as the player is this far away (across the ground).
@export var deaggro_range := 20.0
## It also gives up when it hasn't seen the player for this long, and a shot keeps it
## hunting this long however far away the shooter is.
@export var memory := 4.0
## It gives up at once when chasing takes it this far from home.
@export var leash := 30.0
@export var respawn_time := 45.0
@export var model_scale := 1.0
## How far a hit pushes it, per point of damage (heavy enemies barely move).
@export var knockback := 0.15
## Loot dropped on death: at least the first number of pickups, at most the second.
@export var loot_drops := Vector2i(1, 2)
## Gems dropped on death, along with the rest of the loot.
@export var gem_drops := 1
## Seconds before an untaken drop vanishes (it blinks for the last three).
@export var loot_lifetime := 30.0

var health := 0.0
var dead := false
var alerted := false

var _player: Node3D
var _home := Vector3.ZERO
var _model: Node3D
var _meshes: Array[GeometryInstance3D] = []
var _flash: StandardMaterial3D
## Hit flash, 1 on a hit and fading out.
var _flash_amount := 0.0
var _memory_timer := 0.0
## Seconds left of the grace a shot gives it beyond deaggro_range.
var _provoked := 0.0
var _hurt_cooldown := 0.0
var _t := 0.0
var _audio: AudioStreamPlayer3D
var _sounds: Dictionary
var _ring: Decal
var _bar: EnemyHealthBar

static var _ring_texture: Texture2D
## Whether enemies notice the player at all (the console's `aggro`). Off, they don't
## aggro by sight or when shot, give up any hunt and hide their rings. Static, so it
## holds across levels.
static var aggro_enabled := true


## Adds the model and the sound player, and makes the hit-flash overlay. `sounds` maps
## "alert", "hurt" and "die" (plus any of the subclass's own) to streams.
func _setup(model: PackedScene, sounds: Dictionary) -> void:
	add_to_group("enemies")
	collision_layer = ENEMY_LAYER
	collision_mask = 1
	_sounds = sounds
	_model = model.instantiate()
	_model.scale = Vector3.ONE * model_scale
	add_child(_model)
	for g in _model.find_children("*", "GeometryInstance3D", true, false):
		_meshes.append(g)
		g.layers = ENEMY_VISUAL_LAYER
	_flash = StandardMaterial3D.new()
	_flash.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_flash.albedo_color = Color(0, 0, 0)

	_audio = AudioStreamPlayer3D.new()
	_audio.unit_size = 6.0
	_audio.max_polyphony = 3
	add_child(_audio)

	_ring = Decal.new()
	_ring.texture_albedo = _make_ring_texture()
	_ring.size = Vector3(aggro_radius * 2.0, RING_DEPTH, aggro_radius * 2.0)
	_ring.modulate = RING_COLOR
	_ring.cull_mask &= ~ENEMY_VISUAL_LAYER
	_ring.layers = ENEMY_VISUAL_LAYER
	_ring.upper_fade = 0.5
	_ring.lower_fade = 0.5
	_ring.top_level = true
	add_child(_ring)

	# The health bar, just over the top of the model.
	var top := -INF
	var to_self := global_transform.affine_inverse()
	for g in _meshes:
		var box: AABB = (to_self * g.global_transform) * g.get_aabb()
		top = maxf(top, box.end.y)
	_bar = EnemyHealthBar.new()
	_bar.position.y = (top if top > -INF else 1.5) + BAR_GAP
	add_child(_bar)

	_home = global_position
	health = max_health
	_t = randf() * TAU


## A soft filled disc with a stronger rim, white so the decal's modulate colors it.
## Shared by every enemy.
static func _make_ring_texture() -> Texture2D:
	if _ring_texture:
		return _ring_texture
	const N := 128
	var img := Image.create(N, N, false, Image.FORMAT_RGBA8)
	for y in N:
		for x in N:
			var r := Vector2(x + 0.5 - N / 2.0, y + 0.5 - N / 2.0).length() / (N / 2.0)
			var a := 0.0
			if r < 1.0:
				a = 0.22 + 0.5 * smoothstep(0.9, 0.97, r) * (1.0 - smoothstep(0.97, 1.0, r))
			img.set_pixel(x, y, Color(1, 1, 1, a))
	_ring_texture = ImageTexture.create_from_image(img)
	return _ring_texture


## Where it sees from and aims from.
func _eye_point() -> Vector3:
	return global_position


func _player_center() -> Vector3:
	return _player.global_position + Vector3(0.0, 1.3, 0.0)


func _update_awareness(delta: float) -> void:
	if _player == null:
		# Looked up lazily: the level (and its enemies) is ready before the player is.
		_player = get_tree().get_first_node_in_group("player")
	_ring.global_position = Vector3(global_position.x, _ground_y(), global_position.z)
	_ring.visible = aggro_enabled
	if _player == null or _player.get("dead") or not aggro_enabled:
		if alerted:
			_lose_interest()
		return
	var off := _player.global_position - global_position
	var dist := Vector2(off.x, off.z).length()
	if not alerted:
		if dist < aggro_radius and _line_of_sight():
			_alert()
			_memory_timer = memory
		return
	_provoked -= delta
	var home_off := global_position - _home
	if Vector2(home_off.x, home_off.z).length() > leash or (dist > deaggro_range and _provoked <= 0.0):
		_lose_interest()
	elif _line_of_sight():
		_memory_timer = memory
	else:
		_memory_timer -= delta
		if _memory_timer <= 0.0:
			_lose_interest()


func _lose_interest() -> void:
	alerted = false
	_on_lost_sight()


func _alert() -> void:
	alerted = true
	_on_alert()
	_play("alert", 2.0)


## Just spotted the player (or was shot).
func _on_alert() -> void:
	pass


## Gave up the hunt: the player got away or died, or it strayed too far from home.
func _on_lost_sight() -> void:
	pass


## Clear if nothing but the player (whose body is on layer 1 too) is in the way.
func _line_of_sight() -> bool:
	var q := PhysicsRayQueryParameters3D.create(_eye_point(), _player_center(), 1, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.is_empty() or hit.collider == _player


func _ground_y() -> float:
	var from := global_position + Vector3.UP * 2.0
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 60.0, 1, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if hit else 0.0


## Turns toward `dir` (only about Y; this node faces -Z).
func _face(dir: Vector3, delta: float, rate: float) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length() < 0.01:
		return
	var target := atan2(-flat.x, -flat.z)
	rotation.y = lerp_angle(rotation.y, target, 1.0 - exp(-rate * delta))


## Lights the model with `color` scaled by `amount` (the hit flash, attack glows), or
## clears it at 0.
func _set_glow(color: Color, amount: float) -> void:
	_flash.albedo_color = Color(color.r * amount, color.g * amount, color.b * amount)
	for m in _meshes:
		m.material_overlay = _flash if amount > 0.01 else null


func take_damage(amount: float, _at := Vector3.ZERO, dir := Vector3.ZERO) -> void:
	if dead:
		return
	health -= amount
	_bar.set_health(health, max_health)
	_flash_amount = 1.0
	velocity += dir * clampf(amount * knockback, knockback * 6.0, knockback * 53.0)
	if not alerted and aggro_enabled:
		_alert()
	_memory_timer = memory
	_provoked = memory
	if health <= 0.0:
		_die()
	elif _hurt_cooldown <= 0.0:
		_hurt_cooldown = 0.25
		_play("hurt", 0.0)


func _die() -> void:
	dead = true
	alerted = false
	collision_layer = 0
	_model.visible = false
	_ring.visible = false
	_bar.reset()
	_flash_amount = 0.0
	_set_glow(Color.BLACK, 0.0)
	_on_death()
	_play("die", 4.0)
	_drop_loot()
	get_tree().create_timer(respawn_time).timeout.connect(_try_respawn)


## The death effect (the model is already hidden).
func _on_death() -> void:
	pass


## Ammo for a weapon the player owns, or health, plus gem_drops gems.
func _drop_loot() -> void:
	var drops := randi_range(loot_drops.x, loot_drops.y)
	var wm: WeaponManager = _player.get_node_or_null("WeaponManager") if _player else null
	var owned_types: Array[String] = []
	if wm:
		for w in wm.weapons:
			if not owned_types.has(w.ammo_type):
				owned_types.append(w.ammo_type)
	if owned_types.is_empty():
		owned_types.append("bullets")
	var ground := _ground_y()
	for i in drops + gem_drops:
		var pk := Pickup.new()
		if i >= drops:
			pk.kind = Pickup.Kind.GEM
			pk.amount = 1
			pk.model = GEM_MODEL
			pk.model_scale = 1.6
		elif randf() < 0.35:
			pk.kind = Pickup.Kind.HEALTH
			pk.amount = 15
			pk.model = LOOT_HEALTH_MODEL
			pk.model_scale = 2.0
		else:
			var t: String = owned_types[randi() % owned_types.size()]
			pk.kind = Pickup.Kind.AMMO
			pk.ammo_type = t
			pk.amount = LOOT_AMMO[t]
			pk.model = AMMO_MODELS[t]
		pk.one_shot = true
		pk.lifetime = loot_lifetime
		var a := randf() * TAU
		var r := randf_range(0.8, 1.8)
		var land := Vector3(global_position.x + cos(a) * r, ground, global_position.z + sin(a) * r)
		get_parent().add_child(pk)
		pk.global_position = land
		pk.pop_from(global_position)


func _try_respawn() -> void:
	# Don't pop back in right in front of the player.
	if _player and _player.global_position.distance_to(_home) < 18.0:
		get_tree().create_timer(5.0).timeout.connect(_try_respawn)
		return
	global_position = _home
	velocity = Vector3.ZERO
	health = max_health
	dead = false
	collision_layer = ENEMY_LAYER
	_model.visible = true
	_ring.visible = true
	_model.scale = Vector3.ZERO
	create_tween().tween_property(_model, "scale", Vector3.ONE * model_scale, 0.6) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_on_respawn()


## Back at home after dying (the model is growing back in).
func _on_respawn() -> void:
	pass


func _play(sound: String, db: float) -> void:
	_audio.stream = _sounds[sound]
	_audio.volume_db = db
	_audio.pitch_scale = randf_range(0.92, 1.08)
	_audio.play()
