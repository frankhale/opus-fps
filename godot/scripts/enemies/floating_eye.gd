class_name FloatingEye
extends Enemy
## The floating eye: hovers around its home until it sees the player, screeches and
## gives chase, holding a preferred distance while strafing. It telegraphs each
## attack (the eye glows and whines) before spitting a slow, dodgeable bolt.
## Shots flash it red and knock it back; when killed it bursts in gore (loot and
## respawning come from Enemy). Its rigged tentacles are animated procedurally: a
## wave runs down each one, they trail behind as it moves, flare out while it charges
## a shot and twitch when it's hit.

const BOLT := preload("res://weapons/enemy_eye_bolt.tres")
const MODEL := preload("res://assets/enemies/enemy_floating_eye.glb")
const SOUNDS := {
	"alert": preload("res://assets/sfx/eye_alert.wav"),
	"charge": preload("res://assets/sfx/eye_charge.wav"),
	"fire": preload("res://assets/sfx/eye_fire.wav"),
	"hurt": preload("res://assets/sfx/eye_hurt.wav"),
	"die": preload("res://assets/sfx/eye_die.wav"),
}

@export var preferred_distance := 11.0
@export var speed := 4.5
@export var hover_height := 2.6
@export var attack_interval := Vector2(1.6, 2.6)
## Wind-up before each shot (glow and whine), so the player can react.
@export var telegraph_time := 0.45

var _charge := 0.0
var _attack_timer := 0.0
var _wander := Vector3.ZERO
var _wander_timer := 0.0
var _strafe_dir := 1.0
var _skeleton: Skeleton3D
## One entry per tentacle: {"bones": [bone indices, root first], "radial": outward
## direction in skeleton space, "phase": wave offset}.
var _tentacles: Array[Dictionary] = []
## Smoothed velocity in skeleton space, so the tentacles trail behind smoothly.
var _drag := Vector3.ZERO


func _init() -> void:
	model_scale = 1.6


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5 * model_scale
	shape.shape = sphere
	add_child(shape)

	_setup(MODEL, SOUNDS)
	_model.rotation.y = PI  # the eye looks down its +Z; this node "faces" -Z
	_setup_tentacles()
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
	_set_glow(Color(1.0, 0.15, 0.1), maxf(_flash_amount, _charge))


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


func _on_alert() -> void:
	_attack_timer = randf_range(0.8, 1.4)


func _on_lost_sight() -> void:
	_charge = 0.0


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


func _on_death() -> void:
	_charge = 0.0
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
