class_name Spider
extends Enemy
## The giant spider: creeps around its home until the player comes near, then
## scuttles in, keeping a few meters off and skittering sideways. Every few seconds it
## stops, rears up with its eyes glowing and a hiss (the warning), and sprays a stream
## of milky white toxin at the player (see ToxinSpray). Shots flash it and knock it back;
## when killed it bursts (loot and respawning come from Enemy).
##
## Its legs are rigged (two bones each, see the asset generator) and walk procedurally:
## each toe stays planted where it touched down until the body has moved on too far from
## it, then steps in a quick arc to a spot ahead of where it would rest, landed on the
## ground below. The legs step in two alternating sets of four, like a real spider's
## gait, and each knee bends to reach its toe (two-bone IK). The body bobs with the
## steps and settles to the height of its feet.

const MODEL := preload("res://assets/enemies/enemy_spider.glb")
const SOUNDS := {
	"alert": preload("res://assets/sfx/spider_alert.wav"),
	"charge": preload("res://assets/sfx/spider_charge.wav"),
	"fire": preload("res://assets/sfx/spider_spit.wav"),
	"hurt": preload("res://assets/sfx/spider_hurt.wav"),
	"die": preload("res://assets/sfx/spider_die.wav"),
	"step": preload("res://assets/sfx/spider_step.wav"),
}
## The mouth, between the fangs, in the model's own space (+Z is its front).
const MOUTH := Vector3(0.0, 0.4, 0.58)

@export var speed := 5.5
@export var wander_speed := 1.4
## It keeps about this far from the player (across the ground) while hunting.
@export var preferred_distance := 7.0
## It only spits at a player within this range.
@export var spit_range := 13.0
@export var attack_interval := Vector2(2.2, 3.6)
## The warning before each spray: it rears up, its eyes glow and it hisses.
@export var telegraph_time := 0.55
@export var spray_time := 0.65

@export_group("Legs")
## How far (model units) a toe may fall behind its resting spot before it steps.
@export var stride := 0.38
@export var step_time := 0.14
@export var step_height := 0.22

var _charge := 0.0
var _attack_timer := 0.0
## Seconds left of the current spray (it holds still and keeps its head up).
var _spraying := 0.0
var _wander := Vector3.ZERO
var _wander_timer := 0.0
var _strafe_dir := 1.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

var _skeleton: Skeleton3D
var _body_bone := -1
var _body_rest: Transform3D
## One entry per leg: bones, rest points (skeleton space), segment lengths, the planted
## toe (world), and the step in progress.
var _legs: Array[Dictionary] = []
## The current body offset from the rest pose (bob, settling, rearing), skeleton space.
var _body_pose := Transform3D.IDENTITY
var _lift := 0.0
var _rear := 0.0


func _init() -> void:
	model_scale = 1.25
	max_health = 70.0
	knockback = 0.12


func _ready() -> void:
	floor_snap_length = 0.4
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5 * model_scale
	shape.shape = sphere
	shape.position.y = 0.55 * model_scale
	add_child(shape)

	_setup(MODEL, SOUNDS)
	_model.rotation.y = PI  # the model faces its +Z; this node faces -Z
	_setup_legs()
	_strafe_dir = 1.0 if randf() < 0.5 else -1.0


func _physics_process(delta: float) -> void:
	if dead:
		return
	_t += delta
	_hurt_cooldown -= delta
	_spraying = maxf(_spraying - delta, 0.0)
	_update_awareness(delta)

	var desired := Vector3.ZERO
	var to_player := _player_center() - global_position if _player else Vector3.ZERO
	var flat := Vector3(to_player.x, 0.0, to_player.z)
	if alerted and _player:
		var dist := flat.length()
		var dir := flat / maxf(dist, 0.01)
		if _charge > 0.0 or _spraying > 0.0:
			desired = Vector3.ZERO  # plants itself to spit
		else:
			var approach := clampf((dist - preferred_distance) * 0.6, -1.0, 1.0)
			if randf() < delta * 0.5:
				_strafe_dir = -_strafe_dir
			var side := dir.cross(Vector3.UP) * _strafe_dir * 0.8
			desired = (dir * approach + side).limit_length(1.0) * speed
		_face(to_player, delta, 7.0)
		_update_attack(delta, dist)
	else:
		_wander_timer -= delta
		if _wander_timer <= 0.0 or global_position.distance_to(_wander) < 1.0:
			var a := randf() * TAU
			_wander = _home + Vector3(cos(a), 0.0, sin(a)) * randf_range(2.0, 7.0)
			_wander_timer = randf_range(3.0, 7.0)
		var w := _wander - global_position
		w.y = 0.0
		# Creeps in short spurts, pausing now and then like a spider does.
		var creep := wander_speed if fmod(_t * 0.6, 1.0) < 0.65 else 0.0
		desired = w.limit_length(1.0) * creep
		if w.length() > 0.5:
			_face(w, delta, 3.0)

	var hv := Vector3(velocity.x, 0.0, velocity.z).lerp(desired, 1.0 - exp(-8.0 * delta))
	velocity.x = hv.x
	velocity.z = hv.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
	move_and_slide()

	_animate_legs(delta)
	_flash_amount = move_toward(_flash_amount, 0.0, delta * 6.0)
	_set_glow(Color(0.85, 0.95, 1.0), maxf(_flash_amount, _charge * 0.3))


func _on_alert() -> void:
	_attack_timer = randf_range(1.0, 1.8)


func _on_lost_sight() -> void:
	_charge = 0.0


func _update_attack(delta: float, dist: float) -> void:
	if _spraying > 0.0:
		return
	if dist > spit_range or not _line_of_sight():
		_charge = move_toward(_charge, 0.0, delta * 3.0)
		_attack_timer = maxf(_attack_timer, telegraph_time + 0.2)
		return
	_attack_timer -= delta
	if _attack_timer <= telegraph_time and _charge == 0.0 and _attack_timer > 0.0:
		_play("charge", 0.0)
	if _attack_timer <= telegraph_time:
		_charge = clampf(1.0 - _attack_timer / telegraph_time, 0.0, 1.0)
	if _attack_timer <= 0.0:
		_spit()
		_charge = 0.0
		_attack_timer = randf_range(attack_interval.x, attack_interval.y) + spray_time


func _spit() -> void:
	_spraying = spray_time
	var spray := ToxinSpray.new()
	spray.duration = spray_time
	spray.exclude = [get_rid()]
	spray.mouth = _mouth_point
	spray.target = func(): return _player_center() - Vector3(0, 0.25, 0) if is_instance_valid(_player) else _mouth_point()
	get_parent().add_child(spray)
	_play("fire", 2.0)


## The mouth in world space, following the body as it rears.
func _mouth_point() -> Vector3:
	if _skeleton == null or dead:
		return global_position + Vector3.UP * 0.5
	return _skeleton.global_transform * (_body_pose * MOUTH)


func _eye_point() -> Vector3:
	return global_position + Vector3.UP * 0.7 * model_scale


# ---------------------------------------------------------------------------
# Legs
# ---------------------------------------------------------------------------
## Bones are leg_<side>_<k>_<j>: side l or r, k = 0 (front) to 3, j = 0 hip to knee and
## 1 knee to toe (see the asset generator). The toe is where the shin meets the ground.
func _setup_legs() -> void:
	var found := _model.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		return
	_skeleton = found[0]
	_body_bone = _skeleton.find_bone("body")
	_body_rest = _skeleton.get_bone_global_rest(_body_bone)
	for side in ["l", "r"]:
		for k in 4:
			var hip := _skeleton.find_bone("leg_%s_%d_0" % [side, k])
			var shin := _skeleton.find_bone("leg_%s_%d_1" % [side, k])
			if hip < 0 or shin < 0:
				continue
			var h := _skeleton.get_bone_global_rest(hip)
			var s := _skeleton.get_bone_global_rest(shin)
			var down := s.basis.y.normalized()
			var toe := s.origin + down * (s.origin.y / -down.y)
			var leg := {
				"hip": hip, "shin": shin,
				"hip_rest": h, "shin_rest": s,
				"rest_hip": h.origin, "rest_knee": s.origin, "rest_toe": toe,
				"l1": h.origin.distance_to(s.origin), "l2": s.origin.distance_to(toe),
				# Alternating sets: front-left steps with the second-right, and so on.
				"set": (k + (0 if side == "l" else 1)) % 2,
				"t": 1.0,
			}
			leg.foot = _skeleton.global_transform * toe
			leg.from = leg.foot
			leg.to = leg.foot
			_legs.append(leg)


func _animate_legs(delta: float) -> void:
	if _skeleton == null:
		return
	var sk := _skeleton.global_transform
	var to_sk := sk.affine_inverse()
	var size := sk.basis.get_scale().x
	var flat_v := Vector3(velocity.x, 0.0, velocity.z)
	var moving := flat_v.length()
	var step_t := step_time * clampf(4.0 / maxf(moving, 2.5), 0.8, 1.6)

	# Which set may step: the other must have all its feet down.
	var stepping := [false, false]
	for leg in _legs:
		if leg.t < 1.0:
			stepping[leg.set] = true
	var space := get_world_3d().direct_space_state
	var feet_y := 0.0
	var bob := 0.0
	for leg in _legs:
		# Where this toe would rest now, pushed ahead along the movement so it lands
		# in front and isn't left behind straight away.
		var home: Vector3 = sk * leg.rest_toe + flat_v * step_t * 1.6
		var ground := _ground_at(space, home)
		home.y = ground
		var off: Vector3 = home - leg.foot
		off.y = 0.0
		if leg.t >= 1.0:
			if off.length() > stride * size * 3.5:
				leg.foot = home  # knocked far out of place: just put it down
			elif off.length() > stride * size and not stepping[1 - leg.set]:
				leg.from = leg.foot
				leg.to = home
				leg.t = 0.0
				stepping[leg.set] = true
		else:
			leg.to = home  # keep aiming at the moving resting spot
			leg.t = minf(leg.t + delta / step_t, 1.0)
			var e: float = leg.t * leg.t * (3.0 - 2.0 * leg.t)
			leg.foot = (leg.from as Vector3).lerp(leg.to, e) + Vector3.UP * sin(leg.t * PI) * step_height * size
			bob += sin(leg.t * PI)
			if leg.t >= 1.0 and leg.set == 0 and moving > 2.0 and randf() < 0.5:
				_play_step()
		feet_y += (to_sk * leg.foot).y

	# Body: settle to the feet's height, bob with the steps, rear up to spit.
	feet_y /= maxf(_legs.size(), 1)
	_lift = lerpf(_lift, feet_y - bob * 0.012, 1.0 - exp(-10.0 * delta))
	var rear_target := 1.0 if (_charge > 0.0 or _spraying > 0.0) else 0.0
	_rear = lerpf(_rear, rear_target, 1.0 - exp(-9.0 * delta))
	var breathe := sin(_t * 2.2) * 0.012
	_body_pose = Transform3D(Basis(Vector3.RIGHT, -0.42 * _rear), Vector3(0.0, _lift + breathe + 0.12 * _rear, 0.0))
	# The rest pose is around the body's own origin; turn about that point.
	_body_pose = Transform3D(_body_pose.basis, _body_pose.origin + _body_rest.origin - _body_pose.basis * _body_rest.origin)
	_skeleton.set_bone_global_pose(_body_bone, _body_pose * _body_rest)

	for leg in _legs:
		_solve_leg(leg, to_sk * (leg.foot as Vector3))


## Two-bone IK: bend the knee (up and out, as at rest) so the toe reaches `toe`
## (skeleton space).
func _solve_leg(leg: Dictionary, toe: Vector3) -> void:
	var hip: Vector3 = _body_pose * (leg.rest_hip as Vector3)
	var l1: float = leg.l1
	var l2: float = leg.l2
	var d := toe - hip
	var dist := clampf(d.length(), absf(l1 - l2) + 0.01, l1 + l2 - 0.001)
	var dir := d.normalized()
	var a := (l1 * l1 - l2 * l2 + dist * dist) / (2.0 * dist)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var pole: Vector3 = _body_pose.basis * ((leg.rest_knee as Vector3) - (leg.rest_hip as Vector3))
	pole = (pole - dir * pole.dot(dir)).normalized()
	var knee := hip + dir * a + pole * h
	var reach := hip + dir * dist
	_aim_bone(leg.hip, leg.hip_rest, hip, knee)
	_aim_bone(leg.shin, leg.shin_rest, knee, reach)


## Poses a bone at `from` pointing (its +Y) at `to`, turned from its rest orientation
## (carried along by the body) by the shortest rotation.
func _aim_bone(bone: int, rest: Transform3D, from: Vector3, to: Vector3) -> void:
	var base := (_body_pose.basis * rest.basis).orthonormalized()
	var want := (to - from).normalized()
	var turn := Quaternion(base.y.normalized(), want) if base.y.normalized().dot(want) > -0.999 else Quaternion.IDENTITY
	_skeleton.set_bone_global_pose(bone, Transform3D(Basis(turn) * base, from))


func _ground_at(space: PhysicsDirectSpaceState3D, p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.5, p + Vector3.DOWN * 2.5, 1, [get_rid()])
	var hit := space.intersect_ray(q)
	return hit.position.y if hit else global_position.y


func _play_step() -> void:
	if not _audio.playing:
		_audio.stream = _sounds["step"]
		_audio.volume_db = -8.0
		_audio.pitch_scale = randf_range(0.85, 1.2)
		_audio.play()


func _on_death() -> void:
	_charge = 0.0
	_spraying = 0.0
	var boom := Explosion.new()
	boom.size = 0.8
	boom.color = Color(0.55, 0.75, 0.25)
	get_parent().add_child(boom)
	boom.global_position = global_position + Vector3.UP * 0.6
	for c in [Color(0.12, 0.1, 0.08), Color(0.45, 0.7, 0.2), Color(0.9, 0.92, 0.9)]:
		var gore := FX.burst(c, 14, 5.0, 0.12, 0.9, -9.8, 1.0)
		add_child(gore)
		gore.position.y = 0.6
		gore.emitting = true
		get_tree().create_timer(1.2).timeout.connect(gore.queue_free)


func _on_respawn() -> void:
	# Feet start under the body again.
	if _skeleton:
		for leg in _legs:
			leg.foot = _skeleton.global_transform * (leg.rest_toe as Vector3)
			leg.t = 1.0
