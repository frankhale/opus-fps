class_name Bat
extends CharacterBody3D
## The bat (assets/enemies/enemy_bat.glb): a chibi bat, all head, with huge orange eyes and
## pink-lined ears, flitting about over the back of the island. It's harmless, like the
## lovebird: no aggro ring, health or attack. It's solid to shots and stays off the minimap.
##
## It flies the way bats do: never gliding, its wings beating quickly all the time, and
## jinking about rather than sweeping round in long arcs. It heads off to random spots near
## home (`can_hover` keeps it over the island), `fly_height` above whatever is below, but
## its course wavers from side to side and up and down as it goes, and it bobs with every
## wingbeat. It turns fast (`turn_rate`), banking into its turns.
##
## When the player comes within `watch_range` it flutters over to hover in front of them,
## a little above their eyes, turning to face them and bobbing on the spot with its head
## cocked, peering at them. After a while (`watch_time`), or if they come too close, it
## darts off again, and won't come back to watch them for a while (`watch_cooldown`).
##
## It's animated procedurally on its rig (see enemy_bat in the asset generator). Each
## wingbeat sweeps the arms down and a little forward with the fingers spread, so the
## membrane catches the air; on the upstroke the elbows and fingers fold in, so the wings
## come up half closed, the finger tips lagging behind and whipping round. The body bobs
## with each stroke, the ears flop back and forth, the feet dangle and swing, and the head
## stays nearly level as the body pitches and banks.

const MODEL := preload("res://assets/enemies/enemy_bat.glb")
## Its shoulders' raise through a wingbeat: the top and bottom of the stroke (radians).
const STROKE_TOP := 0.85
const STROKE_BOTTOM := -0.8
## How far its heading may point up or down (as the sine of the angle).
const MAX_CLIMB := 0.5
## The lowest it flies over whatever is below, before it pulls up (m).
const MIN_CLEARANCE := 1.5
## How far it banks per radian a second of turning, and its steepest bank (radians).
const BANK := 0.35
const MAX_BANK := 0.8
## Watching the player: how far in front of them it hovers, and how far above their eyes (m).
const WATCH_GAP := 2.6
const WATCH_RISE := 0.6
## It darts away if the player comes this close while it watches them (m).
const TOO_CLOSE := 1.4

@export var model_scale := 1.0
@export var speed := 3.6
## Turning rate (radians a second).
@export var turn_rate := 2.6
## Wingbeats a second.
@export var flap_rate := 4.2
## How high it flies over whatever is below: the range each new spot is picked from.
@export var fly_height := Vector2(2.5, 6.0)
## The lowest ground it flies over (a level with a sea sets the water's surface, so it
## keeps above the waves rather than the sea bed).
@export var floor_min := -1000.0
## It stays within this far of where it started (across the ground).
@export var wander_radius := 16.0
## It comes over to watch the player within this range, for this long (seconds), and then
## leaves them be for a while.
@export var watch_range := 9.0
@export var watch_time := Vector2(5.0, 9.0)
@export var watch_cooldown := 12.0

## Where it may fly to: (world point) -> bool. Set by the level; by default anywhere
## within wander_radius of home.
var can_hover: Callable

enum { FLYING, WATCHING }

var _state := FLYING
var _state_timer := 0.0
var _watch_wait := 0.0
var _home := Vector3.ZERO
var _target := Vector3.ZERO
var _wander_timer := 0.0
var _t := 0.0
## Its heading (a unit vector) and the speed it flies along it.
var _dir := Vector3.FORWARD
var _speed := 0.0
## How fast it's turning (radians a second, smoothed), and its bank and pitch.
var _yaw_rate := 0.0
var _bank := 0.0
var _pitch := 0.0
## Wingbeat cycle position (0 at the top of the stroke).
var _phase := 0.0
## The jinks: random offsets to its course, drifting from one to the next.
var _jink := Vector3.ZERO
var _jink_want := Vector3.ZERO
var _jink_timer := 0.0
## Its head's look (yaw, pitch) and tilt, and how far it's hovering (0 to 1).
var _look := Vector2.ZERO
var _cock := 0.0
var _hover := 0.0

var _pivot: Node3D
var _model: Node3D
var _skeleton: Skeleton3D
var _bones := {}


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	collision_layer = Enemy.ENEMY_LAYER  # shots stop on it
	collision_mask = 1
	# A ball round its head and body.
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.24 * model_scale
	shape.shape = sphere
	shape.position.y = 0.12 * model_scale
	add_child(shape)

	# The model banks and pitches on a pivot at the middle of its body (its origin).
	_pivot = Node3D.new()
	add_child(_pivot)
	_model = MODEL.instantiate()
	_model.scale = Vector3.ONE * model_scale
	_model.rotation.y = PI  # the model faces its +Z; this node faces -Z
	_pivot.add_child(_model)
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
	_phase = randf()
	var a := randf() * TAU
	_dir = Vector3(cos(a), 0.0, sin(a))
	_speed = speed  # it picks where to head on its first step, once the level has set can_hover


func _physics_process(delta: float) -> void:
	_t += delta
	_watch_wait -= delta
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player and player.get("dead"):
		player = null
	match _state:
		FLYING:
			if player and _watch_wait <= 0.0 and global_position.distance_to(player.global_position) < watch_range:
				_state = WATCHING
				_state_timer = randf_range(watch_time.x, watch_time.y)
			_fly(delta)
		WATCHING:
			_watch(delta, player)
	_animate(delta, player)


# ---------------------------------------------------------------------------
# Flying
# ---------------------------------------------------------------------------
func _fly(delta: float) -> void:
	_wander_timer -= delta
	if _wander_timer <= 0.0 or (_target - global_position).length() < 2.0:
		_pick_target()

	# Jink: every moment or two its course swings to a new random offset, so it flits
	# about rather than flying straight.
	_jink_timer -= delta
	if _jink_timer <= 0.0:
		_jink_timer = randf_range(0.3, 0.9)
		_jink_want = Vector3(randf_range(-1.0, 1.0), randf_range(-0.5, 0.5), randf_range(-1.0, 1.0)) * 0.9
	_jink = _jink.lerp(_jink_want, 1.0 - exp(-5.0 * delta))

	var want := ((_target - global_position).normalized() + _jink).normalized()
	want.y = clampf(want.y, -MAX_CLIMB, MAX_CLIMB)
	var clearance := global_position.y - maxf(_ground_y(), floor_min)
	if clearance < MIN_CLEARANCE:
		want.y = maxf(want.y, MAX_CLIMB * (1.0 - clearance / MIN_CLEARANCE))  # pull up
	_steer(want.normalized(), delta, turn_rate)
	_speed = lerpf(_speed, speed * (1.0 - 0.3 * _dir.y), 1.0 - exp(-3.0 * delta))
	velocity = _dir * _speed + Vector3.UP * 0.5 * sin(TAU * _phase)  # bobbing with the beat
	move_and_slide()
	if get_slide_collision_count() > 0:
		_dir = (_dir + get_slide_collision(0).get_normal() + Vector3.UP * 0.5).normalized()
		_pick_target()
	rotation.y = atan2(-_dir.x, -_dir.z)
	_lean(delta)


## Hovers in front of the player, facing them and peering at them, until it's had enough.
func _watch(delta: float, player: Node3D) -> void:
	_state_timer -= delta
	if player == null or _state_timer <= 0.0 \
			or global_position.distance_to(player.global_position) > watch_range * 1.5:
		_leave(Vector3.ZERO)
		return
	var eye := player.global_position + Vector3.UP * 1.6
	var flat := Vector3(global_position.x - eye.x, 0.0, global_position.z - eye.z)
	if flat.length() < TOO_CLOSE:
		_leave(flat)
		return
	# A spot in front of them (on its side of them), a little above their eyes, held off
	# the ground and wobbling about as it hovers.
	var spot := eye + flat.normalized() * WATCH_GAP + Vector3.UP * WATCH_RISE
	spot += Vector3(sin(_t * 1.3) * 0.3, sin(_t * 2.1) * 0.15, cos(_t * 1.1) * 0.3)
	spot.y = maxf(spot.y, maxf(_ground_y_at(spot), floor_min) + MIN_CLEARANCE)
	var to := spot - global_position
	velocity = velocity.lerp(to * 2.0, 1.0 - exp(-3.0 * delta)).limit_length(speed)
	velocity.y += 0.6 * sin(TAU * _phase)
	move_and_slide()
	_dir = Vector3(velocity.x, 0.0, velocity.z).normalized() if velocity.length() > 0.3 else _dir
	_speed = velocity.length()
	# Face them.
	var face := Vector3(eye.x - global_position.x, 0.0, eye.z - global_position.z)
	if face.length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(-face.x, -face.z), 1.0 - exp(-6.0 * delta))
	_yaw_rate = lerpf(_yaw_rate, 0.0, 1.0 - exp(-4.0 * delta))
	_bank = lerpf(_bank, 0.0, 1.0 - exp(-4.0 * delta))
	_pitch = lerpf(_pitch, -0.1, 1.0 - exp(-4.0 * delta))


## Darts off (away from `away`, if given) and leaves the player be for a while.
func _leave(away: Vector3) -> void:
	_state = FLYING
	_watch_wait = watch_cooldown
	var flat := Vector3(away.x, 0.0, away.z)
	if flat.length() < 0.01:
		flat = -global_basis.z
	_dir = (flat.normalized() + Vector3.UP * 0.4).normalized()
	_speed = speed * 1.3
	_pick_target()


func _steer(want: Vector3, delta: float, rate: float) -> void:
	var before := Vector2(_dir.x, _dir.z).angle()
	var angle := _dir.angle_to(want)
	if angle > 0.001:
		_dir = _dir.slerp(want, minf(1.0, rate * delta / angle)).normalized()
	var turned := angle_difference(before, Vector2(_dir.x, _dir.z).angle())
	_yaw_rate = lerpf(_yaw_rate, -turned / maxf(delta, 0.0001), 1.0 - exp(-4.0 * delta))


## Banks into the turn and pitches with the climb.
func _lean(delta: float) -> void:
	_bank = lerpf(_bank, clampf(_yaw_rate * BANK, -MAX_BANK, MAX_BANK), 1.0 - exp(-4.0 * delta))
	_pitch = lerpf(_pitch, asin(clampf(_dir.y, -1.0, 1.0)) * 0.6, 1.0 - exp(-4.0 * delta))


func _pick_target() -> void:
	var allowed := can_hover if can_hover.is_valid() else func(_p: Vector3) -> bool: return true
	for i in 24:
		var a := randf() * TAU
		var p := global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(5.0, 14.0)
		if Vector2(p.x - _home.x, p.z - _home.z).length() < wander_radius and allowed.call(p):
			p.y = maxf(_ground_y_at(p), floor_min) + randf_range(fly_height.x, fly_height.y)
			_target = p
			_wander_timer = randf_range(4.0, 8.0)
			return
	_target = _home + Vector3.UP * fly_height.y  # nowhere new: head back home
	_wander_timer = 5.0


func _ground_y() -> float:
	return _ground_y_at(global_position)


func _ground_y_at(p: Vector3) -> float:
	var from := Vector3(p.x, maxf(p.y, global_position.y) + 1.0, p.z)
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 60.0, 1, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if hit else p.y - fly_height.x


# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------
# Turns are in the model's skeleton space: +X is the bat's left, +Y up, +Z forward. So a
# positive turn about +Z (BACK) raises the left wing (about -Z the right one), a positive
# turn about -Y (DOWN) sweeps the left wing forward (about +Y the right one), and a
# negative turn about X lifts the head, or swings the feet forward.
func _animate(delta: float, player: Node3D) -> void:
	var watching := _state == WATCHING
	_hover = move_toward(_hover, 1.0 if watching else 0.0, delta * 2.0)
	# It beats a little faster climbing and hovering.
	var rate := flap_rate * (1.0 + 0.3 * maxf(_dir.y, 0.0) / MAX_CLIMB + 0.2 * _hover)
	_phase = fmod(_phase + delta * rate, 1.0)
	var c := cos(TAU * _phase)
	var down := maxf(0.0, sin(TAU * _phase))  # the downstroke
	var up := maxf(0.0, -sin(TAU * _phase))  # the upstroke, with the wing folding

	# The body rises on each downstroke and sinks on the upstroke, and rocks with the beat.
	_pivot.position.y = -0.03 * c * model_scale
	_pivot.rotation = Vector3(_pitch + 0.08 * c, 0.0, _bank)
	if not _skeleton:
		return

	for side in ["l", "r"]:
		var s := 1.0 if side == "l" else -1.0
		var raise := lerpf(STROKE_BOTTOM, STROKE_TOP, (c + 1.0) * 0.5)
		# The arm sweeps down and forward, folds a little back coming up.
		_turn("wing_%s_0" % side, Quaternion(Vector3.BACK * s, raise)
			* Quaternion(Vector3.DOWN * s, 0.25 * down - 0.2 * up))
		# The elbow and wrist fold the hand in on the upstroke, lagging the arm.
		_turn("wing_%s_1" % side, Quaternion(Vector3.BACK * s, 0.25 * cos(TAU * (_phase - 0.1)))
			* Quaternion(Vector3.DOWN * s, -0.6 * up))
		# The fingers whip round behind the stroke and draw together coming up, the lower
		# ones more, so the membrane folds like a fan.
		for k in 3:
			var fold := up * (0.25 + 0.2 * k)
			_turn("finger_%s_%d" % [side, k], Quaternion(Vector3.BACK * s, 0.35 * cos(TAU * (_phase - 0.18)))
				* Quaternion(Vector3.DOWN * s, -fold))

	# The head stays nearly level as the body pitches and banks, and watching the player it
	# looks at them, cocking its head from side to side now and then.
	var look := Vector2.ZERO
	if watching and player:
		var to := global_transform.affine_inverse() * (player.global_position + Vector3.UP * 1.6)
		look = Vector2(atan2(-to.x, -to.z), atan2(to.y, Vector2(to.x, to.z).length()) + _pitch)
		look.x = clampf(look.x, -0.8, 0.8)
		look.y = clampf(look.y, -0.7, 0.5)
	_look = _look.lerp(look, 1.0 - exp(-6.0 * delta))
	_cock = lerpf(_cock, 0.3 * sin(_t * 0.9) * _hover, 1.0 - exp(-4.0 * delta))
	_turn("head", Quaternion(Vector3.UP, _look.x) * Quaternion(Vector3.BACK, -_bank * 0.6 + _cock)
		* Quaternion(Vector3.RIGHT, -(_pitch * 0.7 + 0.04 * c) - _look.y))

	# The ears flop back and forth with the beat; the feet dangle and swing.
	for side in ["l", "r"]:
		var s := 1.0 if side == "l" else -1.0
		_turn("ear_%s" % side, Quaternion(Vector3.RIGHT, 0.12 * cos(TAU * (_phase - 0.25)))
			* Quaternion(Vector3.BACK * s, 0.06 * c))
		_turn("leg_%s" % side, Quaternion(Vector3.RIGHT, -0.25 * cos(TAU * (_phase - 0.3)) + 0.3 * _speed / speed))


## Turns a bone from its rest pose by `turn`, given in skeleton space.
func _turn(bone_name: String, turn: Quaternion) -> void:
	var bone: int = _bones[bone_name]
	var g := _skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion()
	var rest := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
	_skeleton.set_bone_pose_rotation(bone, rest * (g.inverse() * turn * g))
