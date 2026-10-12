class_name FloatingEye
extends CharacterBody3D
## The floating eye: hovers around its home until it sees the player, screeches and
## gives chase, holding a preferred distance while strafing. It telegraphs each
## attack (the eye glows and whines) before spitting a slow, dodgeable bolt.
## Shots flash it red and knock it back; when killed it bursts, drops loot and
## respawns at home a while later (out of the player's sight). Its rigged tentacles
## are animated procedurally: a wave runs down each one, they trail behind as it
## moves, flare out while it charges a shot and twitch when it's hit.

const BOLT := preload("res://weapons/enemy_eye_bolt.tres")
const MODEL := preload("res://assets/enemies/enemy_floating_eye.glb")
const SOUNDS := {
	"alert": preload("res://assets/sfx/eye_alert.wav"),
	"charge": preload("res://assets/sfx/eye_charge.wav"),
	"fire": preload("res://assets/sfx/eye_fire.wav"),
	"hurt": preload("res://assets/sfx/eye_hurt.wav"),
	"die": preload("res://assets/sfx/eye_die.wav"),
}
const LOOT_HEALTH_MODEL := preload("res://assets/pickups/pickup_health_vial.glb")
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

@export var max_health := 80.0
@export var sight_range := 26.0
## Once alerted it keeps chasing this long after losing sight of the player.
@export var memory := 4.0
@export var preferred_distance := 11.0
@export var speed := 4.5
@export var hover_height := 2.6
@export var attack_interval := Vector2(1.6, 2.6)
## Wind-up before each shot (glow and whine), so the player can react.
@export var telegraph_time := 0.45
@export var respawn_time := 45.0
@export var model_scale := 1.6

var health := 0.0
var dead := false
var alerted := false

var _player: Node3D
var _home := Vector3.ZERO
var _model: Node3D
var _meshes: Array[GeometryInstance3D] = []
var _flash: StandardMaterial3D
var _flash_amount := 0.0
var _charge := 0.0
var _attack_timer := 0.0
var _memory_timer := 0.0
var _wander := Vector3.ZERO
var _wander_timer := 0.0
var _strafe_dir := 1.0
var _hurt_cooldown := 0.0
var _t := 0.0
var _audio: AudioStreamPlayer3D
var _skeleton: Skeleton3D
## One entry per tentacle: {"bones": [bone indices, root first], "radial": outward
## direction in skeleton space, "phase": wave offset}.
var _tentacles: Array[Dictionary] = []
## Smoothed velocity in skeleton space, so the tentacles trail behind smoothly.
var _drag := Vector3.ZERO


func _ready() -> void:
	add_to_group("enemies")
	collision_layer = ENEMY_LAYER
	collision_mask = 1
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5 * model_scale
	shape.shape = sphere
	add_child(shape)

	_model = MODEL.instantiate()
	_model.scale = Vector3.ONE * model_scale
	_model.rotation.y = PI  # the eye looks down its +Z; this node "faces" -Z
	add_child(_model)
	for g in _model.find_children("*", "GeometryInstance3D", true, false):
		_meshes.append(g)
	_setup_tentacles()
	_flash = StandardMaterial3D.new()
	_flash.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_flash.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_flash.albedo_color = Color(0, 0, 0)

	_audio = AudioStreamPlayer3D.new()
	_audio.unit_size = 6.0
	_audio.max_polyphony = 3
	add_child(_audio)

	_home = global_position
	health = max_health
	_t = randf() * TAU
	_strafe_dir = 1.0 if randf() < 0.5 else -1.0


func _physics_process(delta: float) -> void:
	if dead:
		return
	_t += delta
	_hurt_cooldown -= delta
	_update_awareness(delta)

	var desired := Vector3.ZERO
	var to_player := _player_center() - global_position if _player else Vector3.ZERO
	var flat := Vector3(to_player.x, 0.0, to_player.z)
	if alerted and _player:
		var dist := flat.length()
		var dir := flat / maxf(dist, 0.01)
		var approach := clampf((dist - preferred_distance) * 0.5, -1.0, 1.0)
		if randf() < delta * 0.25:
			_strafe_dir = -_strafe_dir
		var side := dir.cross(Vector3.UP) * _strafe_dir * 0.7
		desired = (dir * approach + side) * speed
		_face(to_player, delta, 6.0)
		_update_attack(delta)
	else:
		_wander_timer -= delta
		if _wander_timer <= 0.0 or global_position.distance_to(_wander) < 1.0:
			var a := randf() * TAU
			_wander = _home + Vector3(cos(a), 0.0, sin(a)) * randf_range(2.0, 8.0)
			_wander_timer = randf_range(3.0, 6.0)
		var w := _wander - global_position
		w.y = 0.0
		desired = w.limit_length(1.0) * speed * 0.35
		if w.length() > 0.5:
			_face(w, delta, 2.0)

	# Hold a hovering height over whatever is below, with a gentle bob.
	var target_y := _ground_y() + hover_height + sin(_t * 1.7) * 0.25
	desired.y = clampf((target_y - global_position.y) * 2.0, -3.0, 3.0)
	velocity = velocity.lerp(desired, 1.0 - exp(-3.0 * delta))
	move_and_slide()

	# Model sway, hit flash and attack glow.
	_model.rotation.x = sin(_t * 1.3) * 0.08
	_model.rotation.z = sin(_t * 0.9) * 0.06
	_animate_tentacles(delta)
	_flash_amount = move_toward(_flash_amount, 0.0, delta * 6.0)
	var glow := maxf(_flash_amount, _charge)
	_flash.albedo_color = Color(glow, glow * 0.15, glow * 0.1)
	for m in _meshes:
		m.material_overlay = _flash if glow > 0.01 else null


## Tentacle bones are named tentacle_<k>_<j>, j = 0 at the root (see the asset
## generator); each tentacle's outward direction comes from where its root sits.
func _setup_tentacles() -> void:
	var found := _model.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		return
	_skeleton = found[0]
	var chains := {}
	for i in _skeleton.get_bone_count():
		var parts := _skeleton.get_bone_name(i).split("_")
		if parts.size() == 3 and parts[0] == "tentacle":
			chains.get_or_add(int(parts[1]), {})[int(parts[2])] = i
	for k in chains:
		var bones: Array[int] = []
		for j in range((chains[k] as Dictionary).size()):
			bones.append(chains[k][j])
		var root := _skeleton.get_bone_global_rest(bones[0]).origin
		_tentacles.append({
			"bones": bones,
			"radial": Vector3(root.x, 0.0, root.z).normalized(),
			"phase": randf() * TAU,
		})


func _animate_tentacles(delta: float) -> void:
	if _skeleton == null:
		return
	var to_skeleton := _skeleton.global_basis.orthonormalized().inverse()
	_drag = _drag.lerp(to_skeleton * velocity, 1.0 - exp(-4.0 * delta))
	var flex := 1.6 if alerted else 1.0  # livelier once it's hunting
	var flare := _charge * 0.35 + _flash_amount * 0.5
	# Trail: tilt the hanging tentacles away from the direction of travel.
	var trail := Quaternion.IDENTITY
	var drag_flat := Vector3(_drag.x, 0.0, _drag.z)
	if drag_flat.length() > 0.05:
		trail = Quaternion(Vector3.DOWN.cross(-drag_flat).normalized(), clampf(drag_flat.length() * 0.09, 0.0, 0.7))
	for t in _tentacles:
		var radial: Vector3 = t.radial
		var swing_axis := Vector3.DOWN.cross(radial).normalized()  # turning about it swings the tip outward
		var bones: Array[int] = t.bones
		for j in bones.size():
			var wave: float = _t * (1.6 + flex * 0.6) - j * 0.9 + t.phase
			var q := Quaternion(swing_axis, sin(wave) * 0.16 * flex + flare / bones.size() * (j + 1)) \
				* Quaternion(radial, cos(wave * 0.7) * 0.1 * flex)
			if j == 0:
				q = trail * q
			# Rotations above are in skeleton space; express them in the bone's own frame.
			var rest := _skeleton.get_bone_global_rest(bones[j]).basis.get_rotation_quaternion()
			var local_rest := _skeleton.get_bone_rest(bones[j]).basis.get_rotation_quaternion()
			_skeleton.set_bone_pose_rotation(bones[j], local_rest * (rest.inverse() * q * rest))


func _player_center() -> Vector3:
	return _player.global_position + Vector3(0.0, 1.3, 0.0)


func _update_awareness(delta: float) -> void:
	if _player == null:
		# Looked up lazily: the level (and its enemies) is ready before the player is.
		_player = get_tree().get_first_node_in_group("player")
	if _player == null or _player.get("dead"):
		alerted = false
		return
	var sees := global_position.distance_to(_player_center()) < sight_range and _line_of_sight()
	if sees:
		if not alerted:
			_alert()
		_memory_timer = memory
	elif alerted:
		_memory_timer -= delta
		if _memory_timer <= 0.0:
			alerted = false
			_charge = 0.0


func _alert() -> void:
	alerted = true
	_attack_timer = randf_range(0.8, 1.4)
	_play("alert", 2.0)


## Clear if nothing but the player (whose body is on layer 1 too) is in the way.
func _line_of_sight() -> bool:
	var q := PhysicsRayQueryParameters3D.create(global_position, _player_center(), 1, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.is_empty() or hit.collider == _player


func _ground_y() -> float:
	var from := global_position + Vector3.UP * 2.0
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 60.0, 1, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if hit else 0.0


func _face(dir: Vector3, delta: float, rate: float) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length() < 0.01:
		return
	var target := atan2(-flat.x, -flat.z)
	rotation.y = lerp_angle(rotation.y, target, 1.0 - exp(-rate * delta))


func _update_attack(delta: float) -> void:
	if not _line_of_sight():
		_charge = move_toward(_charge, 0.0, delta * 3.0)
		return
	_attack_timer -= delta
	if _attack_timer <= telegraph_time and _charge == 0.0 and _attack_timer > 0.0:
		_play("charge", -2.0)
	if _attack_timer <= telegraph_time:
		_charge = clampf(1.0 - _attack_timer / telegraph_time, 0.0, 1.0) * 1.4
	if _attack_timer <= 0.0:
		_fire()
		_charge = 0.0
		_attack_timer = randf_range(attack_interval.x, attack_interval.y)


func _fire() -> void:
	var from := global_position + (-global_basis.z) * (0.55 * model_scale)
	var p := Projectile.new()
	p.data = BOLT
	p.exclude = [get_rid()]
	p.collision_mask = 1 | 2  # world and player
	p.velocity = (_player_center() - from).normalized() * BOLT.projectile_speed
	get_parent().add_child(p)
	p.global_position = from
	velocity -= (-global_basis.z) * 2.0  # recoil
	_play("fire", 0.0)


func take_damage(amount: float, _at := Vector3.ZERO, dir := Vector3.ZERO) -> void:
	if dead:
		return
	health -= amount
	_flash_amount = 1.0
	velocity += dir * clampf(amount * 0.15, 1.0, 8.0)
	if not alerted:
		_alert()
	_memory_timer = memory
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
	_charge = 0.0
	for m in _meshes:
		m.material_overlay = null

	var boom := Explosion.new()
	boom.size = 0.9
	boom.color = Color(0.7, 0.12, 0.2)
	get_parent().add_child(boom)
	boom.global_position = global_position
	for c in [Color(0.75, 0.05, 0.05), Color(0.75, 0.69, 0.55), Color(0.31, 0.16, 0.42)]:
		var gore := FX.burst(c, 14, 6.0, 0.12, 0.9, -9.8, 1.0)
		add_child(gore)
		gore.emitting = true
		get_tree().create_timer(1.2).timeout.connect(gore.queue_free)
	_play("die", 4.0)
	_drop_loot()
	get_tree().create_timer(respawn_time).timeout.connect(_try_respawn)


func _drop_loot() -> void:
	var drops := 1 if randf() < 0.6 else 2
	var wm: WeaponManager = _player.get_node_or_null("WeaponManager") if _player else null
	var owned_types: Array[String] = []
	if wm:
		for w in wm.weapons:
			if not owned_types.has(w.ammo_type):
				owned_types.append(w.ammo_type)
	if owned_types.is_empty():
		owned_types.append("bullets")
	var ground := _ground_y()
	for i in drops:
		var pk := Pickup.new()
		if randf() < 0.35:
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
		pk.lifetime = 30.0
		var a := randf() * TAU
		var land := Vector3(global_position.x + cos(a) * 1.2, ground, global_position.z + sin(a) * 1.2)
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
	_model.scale = Vector3.ZERO
	create_tween().tween_property(_model, "scale", Vector3.ONE * model_scale, 0.6) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _play(sound: String, db: float) -> void:
	_audio.stream = SOUNDS[sound]
	_audio.volume_db = db
	_audio.pitch_scale = randf_range(0.92, 1.08)
	_audio.play()
