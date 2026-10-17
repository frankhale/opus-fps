class_name Dachshund
extends CharacterBody3D
## The dachshund (assets/enemies/enemy_dachshund.glb): a red smooth-haired dachshund who
## lives on the island. It's harmless, like the lynx ranger: no aggro ring, health or
## attack. It's solid (shots stop on it) and stays off the minimap.
##
## It potters about near home: it stands a while (`idle_time`), sniffing the ground or
## looking about, then trots off somewhere a few meters away (`walk_distance`), and now and
## then gets the zoomies and dashes off somewhere further at a run. When the player comes
## within `greet_range` it runs over to them, stops close by, looks up at them with its
## tail going and, once it's settled, sits pretty: it rocks back onto its haunches, its
## body upright, forepaws held up and drooping at the wrists, its head tilted, wobbling
## a little as it balances and sweeping its tail on the ground. It follows if they move
## off (dropping back onto all fours first), until it loses interest (`greet_time`) and
## wanders off again for a while (`greet_cooldown`). It never goes off dry land
## (`can_stand`).
##
## It's animated procedurally on its rig (see enemy_dachshund in the asset generator),
## with two gaits it blends between by speed, each cycle advancing with the distance
## covered. Walking, its short legs patter in a quick four-beat walk (hind, fore, hind,
## fore down one side then the other), the body level, rolling a touch, the ears swaying
## and the tail wagging easily. Running, it bounds: the hind legs reach forward together
## and the fore legs together, half a cycle apart, the spine arching and stretching, the
## body rocking and lifting off the ground, the ears streaming back and flapping, and
## the tail held up behind. Each paw is planted flat through its stance and curls back as
## it comes through.

const MODEL := preload("res://assets/enemies/enemy_dachshund.glb")
## Meters covered per full gait cycle, walking and running.
const WALK_CYCLE := 0.25
const RUN_CYCLE := 0.65
## Share of the cycle each paw is on the ground, walking and running.
const WALK_DUTY := 0.65
const RUN_DUTY := 0.38
## How far each leg swings either side of straight down (radians).
const WALK_SWING := 0.42
const RUN_SWING := 0.68
## Where each leg is in the cycle (as a share of it), walking (a lateral-sequence walk)
## and running (a bound: the pairs nearly together, half a cycle apart).
const WALK_OFFSETS := {"bl": 0.0, "fl": 0.25, "br": 0.5, "fr": 0.75}
const RUN_OFFSETS := {"bl": 0.0, "br": 0.08, "fl": 0.5, "fr": 0.6}
## Seconds it stands still by the player before it sits pretty.
const SETTLE_TIME := 0.8
## Sitting pretty: how far the body rocks back (radians, about its rump) and how far the
## rump drops to sit on the ground (m).
const PRETTY_TILT := 1.35
const PRETTY_DROP := 0.19
## Sitting pretty, the turns (radians) on the fore legs (shoulder, wrist, paw), the hind
## legs (hip, hock, paw), the neck and head (neck pitch, head pitch, head tilt) and the
## tail's root.
const PRETTY_FORE := Vector3(0.6, -0.05, 1.35)
const PRETTY_HIND := Vector3(0.2, 0.0, 1.3)
const PRETTY_NECK := Vector3(0.95, 0.25, 0.3)
const PRETTY_TAIL := 1.15

@export var walk_speed := 0.75
@export var run_speed := 3.4
## It stays within this far of where it started (across the ground).
@export var wander_radius := 18.0
## How far each trot goes, and each dash when it gets the zoomies.
@export var walk_distance := Vector2(2.5, 6.0)
@export var run_distance := Vector2(7.0, 14.0)
## Seconds it stands between outings, and the chance an outing is a dash.
@export var idle_time := Vector2(2.5, 7.0)
@export var zoomies_chance := 0.2
## It runs over to greet the player within this distance, stays with them this many
## seconds, and then leaves them be for this long before it'll come again.
@export var greet_range := 11.0
@export var greet_time := 14.0
@export var greet_cooldown := 25.0

## Where it may go: (world point) -> bool. Set by the level (the island keeps it on dry
## land); by default anywhere within wander_radius of home.
var can_stand: Callable

enum { IDLE, OUTING, GREET }

var _state := IDLE
var _home := Vector3.ZERO
var _target := Vector3.ZERO
var _running := false
var _timer := 0.0
var _greet_wait := 3.0
var _stuck_timer := 0.0
var _stuck_from := Vector3.ZERO
var _t := 0.0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

var _model: Node3D
var _skeleton: Skeleton3D
var _bones := {}
## Gait cycle position, how much it's moving (0 to 1, easing the legs into and out of
## their stride) and how much of that is running rather than walking.
var _phase := 0.0
var _moving := 0.0
var _run := 0.0
## Its ground speed, smoothed so a hitch in its movement doesn't jolt the stride, and
## its height, smoothed so the body glides over bumps the floor snapping steps over.
var _speed := 0.0
var _smooth_y := 0.0
## Head look (yaw, pitch) in radians, and where it wants to look.
var _look := Vector2.ZERO
var _look_want := Vector2.ZERO
var _glance_timer := 2.0
## How far its nose is down sniffing (0 to 1), and whether it wants it down.
var _sniff := 0.0
var _sniffing := false
## How hard it's wagging (0 to 1): easy when out and about, hard when it's with the player.
var _wag := 0.3
## How far into sitting pretty it is (0 to 1), and how long it's stood still by the player.
var _pretty := 0.0
var _settled := 0.0


func _ready() -> void:
	floor_snap_length = 0.3
	collision_layer = Enemy.ENEMY_LAYER  # shots stop on it
	collision_mask = 1
	# Two short upright capsules, under its chest and its hips: a long, low body.
	for z in [-0.3, 0.22]:
		var shape := CollisionShape3D.new()
		var capsule := CapsuleShape3D.new()
		capsule.radius = 0.15
		capsule.height = 0.48
		shape.shape = capsule
		shape.position = Vector3(0.0, 0.24, z)
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
	_smooth_y = global_position.y
	_t = randf() * 10.0
	_timer = randf_range(idle_time.x, idle_time.y)


func _physics_process(delta: float) -> void:
	_t += delta
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player and player.get("dead"):
		player = null
	var to_player := Vector3.ZERO
	if player:
		to_player = player.global_position - global_position
		to_player.y = 0.0

	_timer -= delta
	_greet_wait -= delta
	if player and _state != GREET and _greet_wait <= 0.0 and to_player.length() < greet_range:
		_state = GREET
		_timer = greet_time
	if _state == GREET and (player == null or _timer <= 0.0 or to_player.length() > greet_range * 1.6):
		_state = IDLE
		_timer = randf_range(idle_time.x, idle_time.y)
		_greet_wait = greet_cooldown

	if _state != GREET:
		_settled = 0.0
	var desired := Vector3.ZERO
	match _state:
		GREET:
			# Runs over, slows to a walk as it gets close, and stops at the player's feet,
			# facing them.
			var gap := to_player.length()
			var ahead := global_position + to_player.normalized() * 0.6
			if gap > 1.6 and (not can_stand.is_valid() or can_stand.call(ahead)):
				_running = gap > 3.5 or (_running and gap > 2.2)
				desired = to_player.normalized() * (run_speed if _running else walk_speed)
				_settled = 0.0
			else:
				_settled += delta
			if _pretty > 0.05:
				desired = Vector3.ZERO  # back down onto all fours before it goes anywhere
			if _pretty < 0.5:
				_face(to_player, delta, 8.0 if _running else 5.0)
		OUTING:
			var to := _target - global_position
			to.y = 0.0
			_stuck_timer -= delta
			if _stuck_timer <= 0.0:
				if global_position.distance_to(_stuck_from) < 0.25:
					_stop()  # ran into something; it'll pick somewhere else
				_stuck_timer = 1.2
				_stuck_from = global_position
			if _state == OUTING and (to.length() < 0.4 or (can_stand.is_valid()
					and not can_stand.call(global_position + to.normalized() * 0.6))):
				_stop()
			elif _state == OUTING:
				desired = to.normalized() * (run_speed if _running else walk_speed)
				_face(to, delta, 7.0 if _running else 4.0)
		IDLE:
			if _timer <= 0.0:
				set_out(randf() < zoomies_chance)

	var hv := Vector3(velocity.x, 0.0, velocity.z).lerp(desired, 1.0 - exp(-(5.0 if _running else 7.0) * delta))
	velocity.x = hv.x
	velocity.z = hv.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
	var before := global_position
	move_and_slide()
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	_animate(delta, moved, player if _state == GREET else null)


## Trots (or, `dash`, runs) off somewhere nearby on dry land. Returns false if it couldn't
## find anywhere.
func set_out(dash := false) -> bool:
	var allowed := can_stand if can_stand.is_valid() else func(_p: Vector3) -> bool: return true
	var reach := run_distance if dash else walk_distance
	for i in 32:
		var a := randf() * TAU
		var p := global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(reach.x, reach.y)
		if Vector2(p.x - _home.x, p.z - _home.z).length() < wander_radius and allowed.call(p):
			_target = p
			_state = OUTING
			_running = dash
			_stuck_timer = 1.2
			_stuck_from = global_position
			return true
	_stop()
	return false


func _stop() -> void:
	_state = IDLE
	_running = false
	_timer = randf_range(idle_time.x, idle_time.y)
	_sniffing = randf() < 0.5


## Turns toward `dir` about Y (this node faces -Z).
func _face(dir: Vector3, delta: float, rate: float) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(-flat.x, -flat.z), 1.0 - exp(-rate * delta))


# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------
# Turns are in the model's skeleton space: +X is the dog's left, +Y up, +Z forward. So a
# negative turn about X swings a leg's foot forward and lifts the nose; a positive one
# swings it back and raises the backward-pointing tail.
func _animate(delta: float, moved: float, greeting: Node3D) -> void:
	if _skeleton == null:
		return
	_speed = lerpf(_speed, moved / maxf(delta, 1e-4), 1.0 - exp(-12.0 * delta))
	_moving = move_toward(_moving, 1.0 if _speed > 0.1 else 0.0, delta * 3.0)
	_run = move_toward(_run, smoothstep(walk_speed * 1.3, run_speed * 0.7, _speed), delta * 2.0)
	_phase = fmod(_phase + _speed * delta / lerpf(WALK_CYCLE, RUN_CYCLE, _run), 1.0)
	var phi := _phase * TAU
	var moving := smoothstep(0.0, 1.0, _moving)
	var walk := moving * (1.0 - _run)
	var run := moving * _run
	_smooth_y = clampf(lerpf(_smooth_y, global_position.y, 1.0 - exp(-15.0 * delta)),
		global_position.y - 0.08, global_position.y + 0.08)

	# Body. Walking it stays level, rolling a touch from side to side. Running it lifts off
	# the ground twice a cycle, and rocks nose-up as the fore legs reach and nose-down as
	# the hind ones gather under it, its spine arching as they gather and stretching as
	# they reach.
	var rock := -sin(phi) * 0.09 * run
	var arch := cos(phi) * 0.16 * run + sin(_t * 2.2) * 0.012  # and it breathes
	# Sitting pretty, it rocks back about its rump onto its haunches.
	_pretty = move_toward(_pretty, 1.0 if _settled > SETTLE_TIME else 0.0, delta * (1.4 if _settled > 0.0 else 2.5))
	var sit := smoothstep(0.0, 1.0, _pretty)
	_model.position.y = _smooth_y - global_position.y + 0.035 * (0.5 - 0.5 * cos(2.0 * phi)) * run - PRETTY_DROP * sit
	_model.rotation = Vector3(rock, PI, sin(phi) * 0.035 * walk)
	# Balancing up there, it wobbles a little.
	var wobble := Vector2(sin(_t * 1.9) * 0.04, sin(_t * 1.3 + 1.0) * 0.05) * sit
	_turn("hips", Quaternion(Vector3.BACK, wobble.y) * Quaternion(Vector3.RIGHT, -PRETTY_TILT * sit + wobble.x))
	_turn("chest", Quaternion(Vector3.RIGHT, arch + 0.12 * sit) * Quaternion(Vector3.UP, _look.x * 0.15))

	var swing_amp := lerpf(WALK_SWING, RUN_SWING, _run) * moving
	var duty := lerpf(WALK_DUTY, RUN_DUTY, _run)
	# Coming through, a paw leaves and lands at the speed it swept back at while planted,
	# so its swing flows on out of its stance and back into the next, no stop at either.
	var sweep := -2.0 * (1.0 - duty) / duty
	for leg in ["fl", "fr", "bl", "br"]:
		var p := fposmod(_phase + lerpf(WALK_OFFSETS[leg], RUN_OFFSETS[leg], _run), 1.0)
		var swing: float
		var lift := 0.0
		if p < duty:
			swing = swing_amp * (1.0 - 2.0 * p / duty)  # planted, pushing back
		else:
			var k := (p - duty) / (1.0 - duty)  # coming through, lifted
			var k2 := k * k
			var k3 := k2 * k
			swing = swing_amp * (-(2.0 * k3 - 3.0 * k2 + 1.0) + (-2.0 * k3 + 3.0 * k2)
				+ (k3 - 2.0 * k2 + k + k3 - k2) * sweep)
			lift = pow(sin(PI * k), 2.0) * lerpf(0.7, 1.0, _run) * moving
		var side: String = leg.substr(1)
		if leg.begins_with("f"):
			# Fore legs reach from the shoulder, and fold at the wrist as they come through.
			# The arch tips the chest; the legs take some of it back so they stay under it.
			# Sitting pretty, they're held up in front of the chest, the paws drooping, and
			# paddle a little now and then.
			var base := swing + 0.3 * lift - arch * 0.8
			var paddle := maxf(sin(_t * 2.3 + (0.0 if side == "l" else 2.0)), 0.0) * 0.15 * sit
			_turn("leg_f%s_0" % side, Quaternion(Vector3.RIGHT, -base + PRETTY_FORE.x * sit - paddle))
			_turn("leg_f%s_1" % side, Quaternion(Vector3.RIGHT, 1.1 * lift + PRETTY_FORE.y * sit))
			_turn("paw_f%s" % side, Quaternion(Vector3.RIGHT, base - 1.1 * lift + 0.6 * lift + arch * 0.8 - rock
				+ PRETTY_FORE.z * sit + paddle))
		else:
			# Hind legs swing from the hip and fold at the hock as they come through.
			# Sitting pretty, they fold forward under it, the paws flat on the ground.
			var base := swing + 0.35 * lift
			_turn("leg_b%s_0" % side, Quaternion(Vector3.RIGHT, -base + PRETTY_HIND.x * sit))
			_turn("leg_b%s_1" % side, Quaternion(Vector3.RIGHT, 0.8 * lift + PRETTY_HIND.y * sit))
			_turn("paw_b%s" % side, Quaternion(Vector3.RIGHT, base - 0.8 * lift + 0.4 * lift - rock + PRETTY_HIND.z * sit))

	_animate_head(delta, greeting, rock, arch, sit)
	_animate_ears(phi, walk, run)
	_animate_tail(delta, phi, run, greeting != null, sit)


func _animate_head(delta: float, greeting: Node3D, rock: float, arch: float, sit: float) -> void:
	var looking := false
	if greeting:
		# Looks up at the player's face, as far as its neck allows.
		var head := _skeleton.global_transform * _skeleton.get_bone_global_pose(_bones["head"]).origin
		var to := _skeleton.global_transform.basis.inverse() * (greeting.global_position + Vector3.UP * 1.5 - head)
		_look_want = Vector2(clampf(atan2(to.x, to.z), -1.0, 1.0),
			clampf(atan2(to.y, Vector2(to.x, to.z).length()), -0.3, 0.75))
		looking = true
		_sniffing = false
	elif _state == IDLE:
		_glance_timer -= delta
		if _glance_timer <= 0.0:
			_sniffing = randf() < 0.45
			_look_want = Vector2(randf_range(-0.7, 0.7), randf_range(-0.05, 0.2)) if not _sniffing else \
				Vector2(randf_range(-0.3, 0.3), 0.0)
			_glance_timer = randf_range(1.5, 3.5)
	else:
		_look_want = Vector2.ZERO
		_sniffing = false
	_look = _look.lerp(_look_want, 1.0 - exp(-(5.0 if looking else 3.0) * delta))
	_sniff = move_toward(_sniff, 1.0 if _sniffing else 0.0, delta * 1.5)
	# Sniffing, the neck dips and the nose works along the ground, twitching.
	var dip := smoothstep(0.0, 1.0, _sniff)
	var twitch := sin(_t * 17.0) * 0.03 * dip
	# The neck keeps the head steadier than the body as it runs. Sitting pretty, the neck
	# bends forward over the upright body to bring the head level, cocked to one side; up
	# there it needn't look up so far.
	var up := _look.y * (1.0 - 0.6 * sit)
	_turn("neck", Quaternion(Vector3.UP, _look.x * 0.4) * Quaternion(Vector3.RIGHT, 0.75 * dip - rock - arch * 0.6
		- up * 0.5 + PRETTY_NECK.x * sit))
	_turn("head", Quaternion(Vector3.UP, _look.x * 0.45 + sin(_t * 1.3) * 0.08 * dip)
		* Quaternion(Vector3.BACK, PRETTY_NECK.z * sit) * Quaternion(Vector3.RIGHT, 0.35 * dip + twitch - up * 0.5
		+ PRETTY_NECK.y * sit))


## Ears sway with each step walking, and running they stream back and flap with each
## bound.
func _animate_ears(phi: float, walk: float, run: float) -> void:
	for side in ["l", "r"]:
		var s := 1.0 if side == "l" else -1.0
		var flap := sin(phi - 0.9)
		var out := run * (0.35 + 0.3 * flap) + walk * 0.08 * sin(2.0 * phi + s)
		var back := run * (0.8 + 0.35 * flap) + walk * 0.06 * absf(sin(2.0 * phi))
		# About the forward axis, a positive turn swings a left (+X) ear's tip outward.
		_turn("ear_%s" % side, Quaternion(Vector3.BACK, s * out) * Quaternion(Vector3.RIGHT, back))


## The tail wags, a whip running down it: easily out and about, hard when it's with the
## player. Running, it's held up behind with a quicker, smaller wag.
func _animate_tail(delta: float, phi: float, run: float, happy: bool, sit: float) -> void:
	_wag = move_toward(_wag, 1.0 if happy else 0.35, delta * 1.5)
	var rate := lerpf(lerpf(5.0, 13.0, _wag), 16.0, run)
	var amp := lerpf(lerpf(0.12, 0.42, _wag), 0.1, run) * (1.0 - 0.4 * sit)
	# Sitting pretty, it lies out along the ground behind, sweeping as it wags.
	var raise := 0.12 + 0.3 * run + 0.15 * _wag + sin(phi) * 0.08 * run + PRETTY_TAIL * sit
	for k in 4:
		var wag := sin(_t * rate - k * 0.7) * amp * (0.7 + 0.15 * k)
		_turn("tail_%d" % k, Quaternion(Vector3.UP, wag) * Quaternion(Vector3.RIGHT, raise if k == 0 else 0.0))


## Turns a bone from its rest pose by `turn`, given in skeleton space.
func _turn(bone_name: String, turn: Quaternion) -> void:
	var bone: int = _bones[bone_name]
	var g := _skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion()
	var rest := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
	_skeleton.set_bone_pose_rotation(bone, rest * (g.inverse() * turn * g))
