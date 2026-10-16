class_name LynxRanger
extends CharacterBody3D
## The lynx ranger (assets/enemies/enemy_lynx_ranger.glb): a chibi lynx kit in a navy
## ranger's coat who lives on the island. It's harmless, like the arcane eye: no aggro
## ring, health or attack. It's solid (shots stop on it) and stays off the minimap.
##
## It potters about near home: it stands a few seconds (`idle_time`), then strolls off
## somewhere a few meters away (`walk_distance`) at a little waddle, never off dry land
## (`can_stand`). While it stands it breathes, glances about now and then, twitches its
## ears and lets its arms hang and sway. When the player comes within `watch_range` it
## turns its head (and a little of its chest) to watch them, and turns to face them if
## they go round behind it.
##
## It's animated procedurally on its rig (see enemy_lynx_ranger in the asset generator).
## The walk cycle advances with the distance covered: each leg swings forward and back
## from the hip, the knee lifting as it comes through and the foot kept flat, while the
## arms swing against the legs. The body bobs twice a cycle and rolls from foot to foot,
## and the ears flop with each step.

const MODEL := preload("res://assets/enemies/enemy_lynx_ranger.glb")
## Meters covered per full walk cycle (two steps).
const CYCLE_LENGTH := 0.55
## How far each leg swings either side of straight down, and how far the knee lifts
## (radians).
const LEG_SWING := 0.42
const KNEE_LIFT := 0.7
## Arm swing either way, and the elbows' slight bend (radians).
const ARM_SWING := 0.32
const ELBOW_BEND := 0.2
## Body bob (m) and roll (radians) while walking.
const BOB := 0.025
const ROLL := 0.06

@export var walk_speed := 0.9
@export var turn_speed := 4.0
## It stays within this far of where it started (across the ground).
@export var wander_radius := 18.0
## How far each stroll goes, at least and at most.
@export var walk_distance := Vector2(3.0, 8.0)
## Seconds it stands between strolls.
@export var idle_time := Vector2(3.0, 8.0)
## It watches the player within this distance.
@export var watch_range := 8.0

## Where it may go: (world point) -> bool. Set by the level (the island keeps it on dry
## land); by default anywhere within wander_radius of home.
var can_stand: Callable

var _home := Vector3.ZERO
var _target := Vector3.ZERO
var _walking := false
var _timer := 0.0
var _stuck_timer := 0.0
var _stuck_from := Vector3.ZERO
var _t := 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

var _model: Node3D
var _skeleton: Skeleton3D
var _bones := {}
## Walk cycle position (one per two steps) and how much it's walking, 0 to 1, easing
## the legs into and out of the stride.
var _phase := 0.0
var _moving := 0.0
## Head look (yaw, pitch) in radians, and where it wants to look.
var _look := Vector2.ZERO
var _look_want := Vector2.ZERO
var _glance_timer := 2.0
## Per ear: the current twitch (radians) and seconds until the next.
var _ear_twitch := {"l": 0.0, "r": 0.0}
var _ear_timer := {"l": 1.5, "r": 3.0}


func _ready() -> void:
	floor_snap_length = 0.3
	collision_layer = Enemy.ENEMY_LAYER  # shots stop on it
	collision_mask = 1
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.32
	capsule.height = 1.25
	shape.shape = capsule
	shape.position.y = 0.625
	add_child(shape)

	_model = MODEL.instantiate()
	_model.rotation.y = PI  # the model faces its +Z; this node faces -Z
	add_child(_model)
	# Kept out of the minimap's snapshot of the level, like the enemies.
	for g: GeometryInstance3D in _model.find_children("*", "GeometryInstance3D", true, false):
		g.layers = Enemy.ENEMY_VISUAL_LAYER
	var found := _model.find_children("*", "Skeleton3D", true, false)
	if not found.is_empty():
		_skeleton = found[0]
		for i in _skeleton.get_bone_count():
			_bones[_skeleton.get_bone_name(i)] = i

	_home = global_position
	_t = randf() * 10.0
	_timer = randf_range(idle_time.x, idle_time.y)


func _physics_process(delta: float) -> void:
	_t += delta
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var watching: bool = player != null and not player.get("dead") \
			and global_position.distance_to(player.global_position) < watch_range

	var desired := Vector3.ZERO
	_timer -= delta
	if _walking:
		var to := _target - global_position
		to.y = 0.0
		_stuck_timer -= delta
		if _stuck_timer <= 0.0:
			if global_position.distance_to(_stuck_from) < 0.3:
				_stop()  # ran into something; it'll pick somewhere else
			_stuck_timer = 1.5
			_stuck_from = global_position
		if to.length() < 0.4 or (can_stand.is_valid() and not can_stand.call(global_position + to.normalized() * 0.6)):
			_stop()
		else:
			desired = to.normalized() * walk_speed
			_face(to, delta, turn_speed)
	elif _timer <= 0.0:
		set_out()
	elif watching:
		# Turns to face the player once they're too far round for its head to follow.
		var off := player.global_position - global_position
		var ahead := -global_basis.z
		if absf(ahead.signed_angle_to(Vector3(off.x, 0.0, off.z), Vector3.UP)) > 0.9:
			_face(off, delta, 2.0)

	var hv := Vector3(velocity.x, 0.0, velocity.z).lerp(desired, 1.0 - exp(-6.0 * delta))
	velocity.x = hv.x
	velocity.z = hv.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
	var before := global_position
	move_and_slide()
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	_animate(delta, moved, player if watching else null)


## Strolls off somewhere nearby on dry land. Returns false if it couldn't find anywhere.
func set_out() -> bool:
	var allowed := can_stand if can_stand.is_valid() else func(_p: Vector3) -> bool: return true
	for i in 32:
		var a := randf() * TAU
		var p := global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(walk_distance.x, walk_distance.y)
		if Vector2(p.x - _home.x, p.z - _home.z).length() < wander_radius and allowed.call(p):
			_target = p
			_walking = true
			_stuck_timer = 1.5
			_stuck_from = global_position
			return true
	_stop()
	return false


func _stop() -> void:
	_walking = false
	_timer = randf_range(idle_time.x, idle_time.y)


## Turns toward `dir` about Y (this node faces -Z).
func _face(dir: Vector3, delta: float, rate: float) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(-flat.x, -flat.z), 1.0 - exp(-rate * delta))


# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------
func _animate(delta: float, moved: float, watched: Node3D) -> void:
	if _skeleton == null:
		return
	_moving = move_toward(_moving, 1.0 if _walking and moved > 0.002 else 0.0, delta * 3.0)
	_phase = fmod(_phase + moved / CYCLE_LENGTH, 1.0)
	var phi := _phase * TAU

	# Body: bobs twice a cycle (lowest as each foot lands) and rolls toward the foot it's on.
	_model.position.y = -BOB * absf(cos(phi)) * _moving
	_model.rotation = Vector3(0.04 * _moving, PI, sin(phi) * ROLL * _moving)
	var breath := sin(_t * 1.7) * 0.025
	_turn("chest", Quaternion(Vector3.UP, _look.x * 0.25) * Quaternion(Vector3.RIGHT, breath))

	for side in ["l", "r"]:
		var s := 1.0 if side == "l" else -1.0
		var p := phi if side == "l" else phi + PI
		# Legs: forward is a negative turn about X; the knee bends back as the leg swings
		# through, and the foot turns to stay flat.
		var swing := LEG_SWING * sin(p) * _moving
		var bend := KNEE_LIFT * maxf(cos(p), 0.0) * _moving
		_turn("leg_%s_0" % side, Quaternion(Vector3.RIGHT, -swing))
		_turn("leg_%s_1" % side, Quaternion(Vector3.RIGHT, bend))
		_turn("foot_%s" % side, Quaternion(Vector3.RIGHT, swing - bend))
		# Arms swing against the legs; standing, they hang and sway a little.
		var arm := -ARM_SWING * sin(p) * _moving + sin(_t * 1.3 + s) * 0.04 * (1.0 - _moving)
		_turn("arm_%s_0" % side, Quaternion(Vector3.FORWARD, s * -0.08) * Quaternion(Vector3.RIGHT, -arm))
		_turn("arm_%s_1" % side, Quaternion(Vector3.RIGHT, -ELBOW_BEND * (0.5 + 0.5 * _moving)))
	_animate_head(delta, watched)
	_animate_ears(delta, phi)


func _animate_head(delta: float, watched: Node3D) -> void:
	var watching := false
	if watched:
		# Turns to watch the player, as far as its neck allows.
		var head := _skeleton.global_transform * _skeleton.get_bone_global_pose(_bones["head"]).origin
		var to := _skeleton.global_transform.basis.inverse() * (watched.global_position + Vector3.UP * 1.4 - head)
		_look_want = Vector2(clampf(atan2(to.x, to.z), -1.0, 1.0),
			clampf(atan2(to.y, Vector2(to.x, to.z).length()), -0.3, 0.45))
		watching = true
	elif not _walking:
		_glance_timer -= delta
		if _glance_timer <= 0.0:
			_look_want = Vector2(randf_range(-0.8, 0.8), randf_range(-0.1, 0.25)) if randf() < 0.7 else Vector2.ZERO
			_glance_timer = randf_range(1.5, 3.5)
	else:
		_look_want = Vector2.ZERO
	_look = _look.lerp(_look_want, 1.0 - exp(-(4.0 if watching else 3.0) * delta))
	# The chest takes a quarter of the turn (in _animate); the head the rest.
	_turn("head", Quaternion(Vector3.UP, _look.x * 0.75) * Quaternion(Vector3.RIGHT, -_look.y))


## Ears flop with each step and twitch now and then: a quick flick that eases back.
func _animate_ears(delta: float, phi: float) -> void:
	for side in ["l", "r"]:
		var s := 1.0 if side == "l" else -1.0
		_ear_timer[side] -= delta
		if _ear_timer[side] <= 0.0:
			_ear_twitch[side] = randf_range(0.25, 0.45) * (1.0 if randf() < 0.6 else -1.0)
			_ear_timer[side] = randf_range(2.0, 6.0)
		_ear_twitch[side] = lerpf(_ear_twitch[side], 0.0, 1.0 - exp(-6.0 * delta))
		var flop := absf(sin(phi)) * 0.12 * _moving
		# About the forward axis, a positive turn tips a left (+X) ear in toward upright.
		var tilt: float = s * (_ear_twitch[side] - flop)
		_turn("ear_%s_0" % side, Quaternion(Vector3.BACK, tilt))
		_turn("ear_%s_1" % side, Quaternion(Vector3.BACK, tilt * 0.6 - s * flop))


## Turns a bone from its rest pose by `turn`, given in skeleton space.
func _turn(bone_name: String, turn: Quaternion) -> void:
	var bone: int = _bones[bone_name]
	var g := _skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion()
	var rest := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
	_skeleton.set_bone_pose_rotation(bone, rest * (g.inverse() * turn * g))
