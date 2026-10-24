class_name Butterfly
extends CharacterBody3D
## The butterfly (assets/enemies/enemy_butterfly.glb): a monarch, orange and black with
## white-spotted borders, fluttering about low over the island and settling on things.
## It's harmless, like the lovebird: no aggro ring, health or attack. It's solid to shots
## and stays off the minimap.
##
## It flies the way butterflies do: a burst of quick wingbeats, then a short glide with
## its wings held up in a V, sinking a little, then another burst; bouncing up with every
## beat and wandering from side to side, never in a straight line. It heads off to random
## spots near home (`can_hover` keeps it over the island), `fly_height` above whatever is
## below.
##
## Every so often (`land_chance`) it picks somewhere to settle: the top of whatever is
## under a spot nearby (grass, a rock, a bush, the fountain's rim), if it's fairly flat.
## It flutters down onto it and rests there, its wings closed up over its back, opening
## and closing them slowly as it basks. It flies off again after a while (`rest_time`), or
## at once if the player comes within `flush_range`.
##
## It's animated procedurally on its rig (see enemy_butterfly in the asset generator):
## the forewings and hindwings beat together, the hindwings lagging a touch, and the
## abdomen swings against the beat.

const MODEL := preload("res://assets/enemies/enemy_butterfly.glb")
## Its wings' raise through a wingbeat: the top and bottom of the stroke (radians).
const STROKE_TOP := 1.3
const STROKE_BOTTOM := -0.55
## Its wings' raise gliding, and folded shut over its back at rest (radians).
const GLIDE_RAISE := 0.55
const CLOSED := 1.45
## How far its heading may point up or down (as the sine of the angle).
const MAX_CLIMB := 0.5
## The lowest it flies over whatever is below, unless it's landing (m).
const MIN_CLEARANCE := 0.5
## Its body's height over the spot it rests on (its legs' reach, before model_scale).
const STANCE := 0.09
## How steep a spot it may rest on (the least upward part of the surface's normal).
const FLAT_ENOUGH := 0.7

@export var model_scale := 1.0
@export var speed := 1.8
## Turning rate (radians a second).
@export var turn_rate := 3.0
## Wingbeats a second in a burst.
@export var flap_rate := 5.0
## How high it flies over whatever is below: the range each new spot is picked from.
@export var fly_height := Vector2(0.8, 2.6)
## The lowest ground it flies over (a level with a sea sets the water's surface).
@export var floor_min := -1000.0
## It stays within this far of where it started (across the ground).
@export var wander_radius := 14.0
## The chance, each new spot it picks, that it looks for somewhere to settle instead.
@export var land_chance := 0.35
## Seconds it rests before flying on.
@export var rest_time := Vector2(4.0, 12.0)
## It flies up when the player comes this close while it rests.
@export var flush_range := 3.0

## Where it may fly to: (world point) -> bool. Set by the level; by default anywhere
## within wander_radius of home.
var can_hover: Callable

enum { FLYING, LANDING, RESTING }

var _state := FLYING
var _state_timer := 0.0
var _home := Vector3.ZERO
var _target := Vector3.ZERO
var _wander_timer := 0.0
var _t := 0.0
## Its heading (a unit vector) and the speed it flies along it.
var _dir := Vector3.FORWARD
var _speed := 0.0
var _bank := 0.0
var _pitch := 0.0
## Wingbeat cycle position (0 at the top of the stroke), and the bursts and glides:
## whether it's gliding and how long until it switches.
var _phase := 0.0
var _gliding := false
var _burst_timer := 0.0
## How far its wings are from beating to held still (0 to 1), and to folded at rest.
var _hold := 0.0
var _rest := 0.0
## The wander: a random offset to its course, drifting from one to the next.
var _drift := Vector3.ZERO
var _drift_want := Vector3.ZERO
var _drift_timer := 0.0
## Where it's settling: the spot (its body's place there) and the way it faces.
var _spot := Vector3.ZERO

var _pivot: Node3D
var _model: Node3D
var _skeleton: Skeleton3D
var _bones := {}


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	collision_layer = Enemy.ENEMY_LAYER  # shots stop on it
	collision_mask = 1
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.06 * model_scale
	shape.shape = sphere
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
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player and player.get("dead"):
		player = null
	match _state:
		FLYING:
			_fly(delta)
		LANDING:
			_land(delta)
		RESTING:
			_state_timer -= delta
			velocity = Vector3.ZERO
			if _state_timer <= 0.0 or (player and global_position.distance_to(player.global_position) < flush_range):
				_take_off(player)
	_animate(delta)


# ---------------------------------------------------------------------------
# Flying
# ---------------------------------------------------------------------------
func _fly(delta: float) -> void:
	_wander_timer -= delta
	if _wander_timer <= 0.0 or (_target - global_position).length() < 1.0:
		if randf() < land_chance and _find_spot():
			_state = LANDING
			_state_timer = 8.0  # gives up if it can't get there
			return
		_pick_target()

	# Wander: every moment or two its course swings to a new random offset.
	_drift_timer -= delta
	if _drift_timer <= 0.0:
		_drift_timer = randf_range(0.4, 1.2)
		_drift_want = Vector3(randf_range(-1.0, 1.0), randf_range(-0.4, 0.4), randf_range(-1.0, 1.0)) * 0.8
	_drift = _drift.lerp(_drift_want, 1.0 - exp(-3.0 * delta))

	var want := ((_target - global_position).normalized() + _drift).normalized()
	want.y = clampf(want.y, -MAX_CLIMB, MAX_CLIMB)
	var clearance := global_position.y - maxf(_ground_y(), floor_min)
	if clearance < MIN_CLEARANCE:
		want.y = maxf(want.y, MAX_CLIMB * (1.0 - clearance / MIN_CLEARANCE))  # pull up
	_steer(want.normalized(), delta)
	_flutter(delta)
	velocity = _dir * _speed + _bounce()
	if _gliding:
		velocity.y -= 0.35  # sinking a little on the glide
	move_and_slide()
	if get_slide_collision_count() > 0:
		_dir = (_dir + get_slide_collision(0).get_normal() + Vector3.UP * 0.5).normalized()
		_pick_target()
	_face(delta)


## Flutters down onto the spot it picked, slowing as it comes in.
func _land(delta: float) -> void:
	_state_timer -= delta
	var to := _spot - global_position
	if _state_timer <= 0.0 or (can_hover.is_valid() and not can_hover.call(_spot)):
		_state = FLYING
		_pick_target()
		return
	if to.length() < 0.5:
		# Close in: drift straight onto it, the wings beating slow and shallow.
		global_position = global_position.move_toward(_spot, delta * maxf(0.3, to.length() * 2.0))
		velocity = Vector3.ZERO
		_gliding = false
		if global_position.distance_to(_spot) < 0.005:
			_state = RESTING
			_state_timer = randf_range(rest_time.x, rest_time.y)
		_face(delta)
		return
	# Come in from a little above it, so it settles down rather than skimming in.
	var aim := _spot + Vector3.UP * minf(to.length() * 0.4, 0.8)
	_steer((aim - global_position).normalized(), delta)
	_flutter(delta)
	_speed = lerpf(_speed, speed * clampf(to.length() / 2.0, 0.4, 1.0), 1.0 - exp(-3.0 * delta))
	velocity = _dir * _speed + _bounce() * 0.6
	move_and_slide()
	_face(delta)


func _take_off(player: Node3D) -> void:
	_state = FLYING
	var away := Vector3.ZERO
	if player:
		away = global_position - player.global_position
		away.y = 0.0
	if away.length() < 0.01:
		away = -global_basis.z
	_dir = (away.normalized() + Vector3.UP).normalized()
	_speed = speed * 1.2
	_gliding = false
	_burst_timer = randf_range(1.0, 1.8)
	_pick_target()


## Switches between bursts of beats and short glides.
func _flutter(delta: float) -> void:
	_burst_timer -= delta
	if _burst_timer <= 0.0:
		# A glide only from the top of a stroke, so the wings are up when it holds them.
		if _gliding or cos(TAU * _phase) > 0.7:
			_gliding = not _gliding
			_burst_timer = randf_range(0.25, 0.6) if _gliding else randf_range(0.6, 1.6)
	_speed = lerpf(_speed, speed * (0.8 if _gliding else 1.0), 1.0 - exp(-2.0 * delta))


## Each beat flings it up, so it bounces along.
func _bounce() -> Vector3:
	return Vector3.ZERO if _gliding else Vector3.UP * 0.9 * sin(TAU * _phase)


func _steer(want: Vector3, delta: float) -> void:
	var before := Vector2(_dir.x, _dir.z).angle()
	var angle := _dir.angle_to(want)
	if angle > 0.001:
		_dir = _dir.slerp(want, minf(1.0, turn_rate * delta / angle)).normalized()
	var turned := angle_difference(before, Vector2(_dir.x, _dir.z).angle())
	_bank = lerpf(_bank, clampf(-turned / maxf(delta, 0.0001) * 0.25, -0.6, 0.6), 1.0 - exp(-4.0 * delta))


func _face(delta: float) -> void:
	if Vector2(_dir.x, _dir.z).length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(-_dir.x, -_dir.z), 1.0 - exp(-8.0 * delta))
	var level := _state == RESTING or (_state == LANDING and velocity == Vector3.ZERO)
	_pitch = lerpf(_pitch, 0.0 if level else asin(clampf(_dir.y, -1.0, 1.0)) * 0.5, 1.0 - exp(-4.0 * delta))
	if level:
		_bank = lerpf(_bank, 0.0, 1.0 - exp(-6.0 * delta))


func _pick_target() -> void:
	var allowed := can_hover if can_hover.is_valid() else func(_p: Vector3) -> bool: return true
	for i in 24:
		var a := randf() * TAU
		var p := global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(3.0, 9.0)
		if Vector2(p.x - _home.x, p.z - _home.z).length() < wander_radius and allowed.call(p):
			p.y = maxf(_ground_y_at(p), floor_min) + randf_range(fly_height.x, fly_height.y)
			_target = p
			_wander_timer = randf_range(3.0, 7.0)
			return
	_target = _home + Vector3.UP * fly_height.y  # nowhere new: head back home
	_wander_timer = 5.0


## Looks for somewhere nearby to settle: the top of whatever is under a random spot, if
## it's fairly flat and over the island.
func _find_spot() -> bool:
	var allowed := can_hover if can_hover.is_valid() else func(_p: Vector3) -> bool: return true
	for i in 8:
		var a := randf() * TAU
		var p := global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(1.5, 6.0)
		if Vector2(p.x - _home.x, p.z - _home.z).length() > wander_radius or not allowed.call(p):
			continue
		var from := Vector3(p.x, global_position.y + 3.0, p.z)
		var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 40.0, 1, [get_rid()])
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if hit and hit.normal.y > FLAT_ENOUGH and hit.position.y > floor_min:
			_spot = hit.position + hit.normal * STANCE * model_scale
			return true
	return false


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
# Turns are in the model's skeleton space: +X is the butterfly's left, +Y up, +Z forward.
# So a positive turn about +Z (BACK) raises the left wings (about -Z the right ones), and
# a positive turn about +X lowers the abdomen's tip.
func _animate(delta: float) -> void:
	var resting := _state == RESTING
	var settling := _state == LANDING and velocity == Vector3.ZERO
	_rest = move_toward(_rest, 1.0 if resting else 0.0, delta * 3.0)
	_hold = move_toward(_hold, 1.0 if _gliding and not resting else 0.0, delta * 6.0)
	var rate := flap_rate * (0.5 if settling else 1.0)
	if not _gliding:
		_phase = fmod(_phase + delta * rate * (1.0 - _rest), 1.0)
	var c := cos(TAU * _phase)

	# The body dips against each beat, and rocks with it.
	var beat := (1.0 - _hold) * (1.0 - _rest)
	_pivot.position.y = 0.012 * c * beat * model_scale
	_pivot.rotation = Vector3(_pitch + 0.1 * c * beat, 0.0, _bank)
	if not _skeleton:
		return

	# At rest the wings fold up over its back, opening and closing slowly as it basks.
	var bask := CLOSED - 0.9 * maxf(0.0, sin(_t * 0.9)) ** 2
	for side in ["l", "r"]:
		var s := 1.0 if side == "l" else -1.0
		var fore := lerpf(STROKE_BOTTOM, STROKE_TOP, (c + 1.0) * 0.5)
		var hind := lerpf(STROKE_BOTTOM, STROKE_TOP, (cos(TAU * (_phase - 0.06)) + 1.0) * 0.5) * 0.9
		if settling:
			fore *= 0.5
			hind *= 0.5
		fore = lerpf(lerpf(fore, GLIDE_RAISE, _hold), bask, _rest)
		hind = lerpf(lerpf(hind, GLIDE_RAISE * 0.9, _hold), bask - 0.05, _rest)
		_turn("wing_%s_0" % side, Quaternion(Vector3.BACK * s, fore))
		_turn("wing_%s_1" % side, Quaternion(Vector3.BACK * s, hind))
	_turn("abdomen", Quaternion(Vector3.RIGHT, 0.15 * cos(TAU * (_phase - 0.2)) * beat + 0.05))


## Turns a bone from its rest pose by `turn`, given in skeleton space.
func _turn(bone_name: String, turn: Quaternion) -> void:
	var bone: int = _bones[bone_name]
	var g := _skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion()
	var rest := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
	_skeleton.set_bone_pose_rotation(bone, rest * (g.inverse() * turn * g))
