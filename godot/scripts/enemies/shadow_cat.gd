@tool
class_name ShadowCat
extends CharacterBody3D
## The shadow cat (assets/enemies/enemy_shadow_cat.glb): a harmless wanderer for now. It
## has no aggro, health or attack yet. It roams between spots near home, mostly at a
## walk but now and then at a trot or a full run, and stops between outings to stand and
## look around. When the player comes within `curious_range` it turns its head to watch
## them. It's solid to the player and to shots, which just stop on it.
##
## It's animated procedurally on its rig (see enemy_shadow_cat in the asset generator).
## Three gaits (GAITS) blend into each other by speed, each with its own footfalls,
## stride, paw lift, body motion, head carriage, ears and tail:
##   * walk: one leg at a time (hind, fore, other hind, other fore), at least two paws
##     always down; a small bob, relaxed head, tail swaying.
##   * trot: diagonal pairs together, with a moment of flight between them; a springy
##     bounce, high-stepping paws, steady head and a raised tail.
##   * run: a gallop. The hind paws land just apart, then the fore paws, with flight
##     after each pair. The body bounds and rocks (nose up as the hind legs drive, down
##     as the fore legs land), the head reaches forward and low, the ears pin back and
##     the tail streams out behind.
## The gait cycle advances with the distance covered, so planted paws don't slide. Each
## paw is set on the ground below it (a raycast) and the legs bend to reach it (two-bone
## IK; a hind leg keeps its hock-to-ankle segment as at rest), and paws curl as they
## swing through. It also crouches a little and pitches with the slope. The head looks
## where it's going, glances around when idle and watches a nearby player. The tail
## swishes now and then when idle, and the ears twitch and flop with its steps.
## The model stands in its rest pose (mid-stride, right forepaw raised) in the editor.

const MODEL := preload("res://assets/enemies/enemy_shadow_cat.glb")

## Per gait:
##   speed: the speed it's tuned for (m/s); between two gaits' speeds it blends them.
##   stride: how far a paw travels while planted (model meters).
##   duty: share of each cycle a paw is planted.
##   lift: paw height at the top of its swing.
##   extend: in the air the legs stretch out (in strides): the hind legs kick back
##     after leaving the ground and the forelegs reach forward before landing.
##   offsets: where in the cycle each paw lands (bl/br/fl/fr: back/front, left/right).
##     They wrap at 1, so the trot's front right is 1 rather than 0: blending from the
##     walk (0.75) then moves it forward a quarter cycle instead of back three quarters.
##   bob: body rise and fall; low: phase of its lowest point (twice a cycle).
##   rock: body pitch with the stride (nose up at phase `low`, down half a cycle on).
##   crouch: how far the body sinks below rest, keeping the legs bent.
##   head: forward reach of the head and neck (radians, nose down).
##   ears: how far the ears lie back (radians).
##   tail: 0 = curled up over the back, 1 = streaming straight out behind.
const GAITS := [
	{"speed": 0.9, "stride": 0.3, "duty": 0.62, "lift": 0.07, "extend": 0.0,
	 "offsets": {"bl": 0.0, "fl": 0.25, "br": 0.5, "fr": 0.75},
	 "bob": 0.012, "low": 0.0, "rock": 0.0, "crouch": 0.05, "head": 0.0, "ears": 0.0, "tail": 0.0},
	{"speed": 2.2, "stride": 0.4, "duty": 0.38, "lift": 0.12, "extend": 0.15,
	 "offsets": {"bl": 0.0, "fr": 1.0, "br": 0.5, "fl": 0.5},
	 "bob": 0.03, "low": 0.19, "rock": 0.02, "crouch": 0.04, "head": 0.08, "ears": 0.15, "tail": 0.35},
	{"speed": 4.5, "stride": 0.44, "duty": 0.28, "lift": 0.13, "extend": 0.7,
	 "offsets": {"bl": 0.0, "br": 0.1, "fl": 0.48, "fr": 0.58},
	 "bob": 0.035, "low": 0.19, "rock": 0.14, "crouch": 0.08, "head": 0.3, "ears": 0.7, "tail": 1.0},
]

## Share of outings taken at a trot, and at a run (the rest are walks).
@export var trot_chance := 0.2
@export var run_chance := 0.15
@export var turn_speed := 5.0
## It stays within this far of where it started (across the ground).
@export var wander_radius := 25.0
## How far each walk goes, at least and at most. Runs go 1.6 times as far.
@export var walk_distance := Vector2(4.0, 12.0)
## Seconds it stands between outings.
@export var idle_time := Vector2(2.0, 6.0)
## It watches the player within this distance.
@export var curious_range := 7.0

## Where it may go: (world point) -> bool. Set by the level (the island keeps it on dry
## land); by default anywhere within wander_radius of home.
var can_stand: Callable

enum State { IDLE, MOVE }

var _state := State.IDLE
var _state_timer := 0.0
var _target := Vector3.ZERO
var _speed := 0.0
var _home := Vector3.ZERO
var _stuck_timer := 0.0
var _stuck_from := Vector3.ZERO
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _t := 0.0

var _model: Node3D
var _skeleton: Skeleton3D
## Leg descriptions: bones, rest points and lengths (skeleton space), stance.
var _legs: Array[Dictionary] = []
var _phase := 0.0
## Current gait, 0 = walk, 1 = trot, 2 = run, blending in between.
var _gait := 0.0
## How much it's moving, 0 to 1, easing the legs into and out of the gait.
var _moving := 0.0
var _pitch := 0.0
## Head look (yaw, pitch) in radians, and where it wants to look.
var _look := Vector2.ZERO
var _look_want := Vector2.ZERO
var _glance_timer := 0.0
var _swish := 0.0
var _swish_timer := 0.0
var _ear_twitch := {"l": 0.0, "r": 0.0}
var _ear_timer := {"l": 1.0, "r": 2.0}


func _ready() -> void:
	_model = MODEL.instantiate()
	_model.rotation.y = PI  # the model faces its +Z; this node faces -Z
	add_child(_model)
	if Engine.is_editor_hint():
		return
	collision_layer = Enemy.ENEMY_LAYER  # solid to the player and to shots
	collision_mask = 1
	floor_snap_length = 0.3
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.28
	capsule.height = 0.9
	shape.shape = capsule
	shape.position.y = 0.48
	add_child(shape)
	# Kept out of the minimap's snapshot of the level, like the enemies.
	for g: GeometryInstance3D in _model.find_children("*", "GeometryInstance3D", true, false):
		g.layers = Enemy.ENEMY_VISUAL_LAYER
	add_to_group("shadow_cats")
	_home = global_position
	_t = randf() * 10.0
	_state_timer = randf_range(idle_time.x, idle_time.y)
	_setup_rig()


func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	_t += delta
	var desired := Vector3.ZERO
	match _state:
		State.IDLE:
			_state_timer -= delta
			if _state_timer <= 0.0:
				set_out()
		State.MOVE:
			var to := _target - global_position
			to.y = 0.0
			var dist := to.length()
			if dist < 0.5:
				_stop()
			else:
				# Slows over the last stretch rather than stopping dead (longer from a run).
				desired = to / dist * _speed * clampf(dist / maxf(_speed * 0.6, 1.0), 0.35, 1.0)
				_stuck_timer -= delta
				if _stuck_timer <= 0.0:
					if global_position.distance_to(_stuck_from) < 0.3:
						_stop()  # ran into something; it'll pick somewhere else
					_stuck_timer = 1.5
					_stuck_from = global_position

	var hv := Vector3(velocity.x, 0.0, velocity.z).lerp(desired, 1.0 - exp(-4.0 * delta))
	velocity.x = hv.x
	velocity.z = hv.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
	var before := global_position
	move_and_slide()
	if hv.length() > 0.05:
		rotation.y = lerp_angle(rotation.y, atan2(-hv.x, -hv.z), 1.0 - exp(-turn_speed * delta))
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()
	_animate(delta, moved)


## Picks somewhere to go and sets off for it, at `gait` (0 walk, 1 trot, 2 run) or, by
## default, one picked by trot_chance and run_chance. The dev console's `cat` command
## calls it to show a gait on demand. Returns false if there was nowhere to go.
func set_out(gait := -1) -> bool:
	var allowed := can_stand if can_stand.is_valid() else func(_p: Vector3) -> bool: return true
	if gait < 0:
		var roll := randf()
		gait = 2 if roll < run_chance else (1 if roll < run_chance + trot_chance else 0)
	var reach := walk_distance * (1.6 if gait == 2 else 1.0)
	for i in 48:
		var a := randf() * TAU
		var p := global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(reach.x, reach.y)
		if Vector2(p.x - _home.x, p.z - _home.z).length() < wander_radius and allowed.call(p):
			_target = p
			_speed = GAITS[gait].speed
			_state = State.MOVE
			_stuck_timer = 1.5
			_stuck_from = global_position
			return true
	_state_timer = 1.0  # nowhere suitable this time; try again shortly
	return false


func _stop() -> void:
	_state = State.IDLE
	_state_timer = randf_range(idle_time.x, idle_time.y)


# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------
func _setup_rig() -> void:
	var found := _model.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		return
	_skeleton = found[0]
	var sk := _skeleton
	var rest := func(name: String) -> Vector3: return sk.get_bone_global_rest(sk.find_bone(name)).origin
	# Where planted paws stand, from the planted left legs (the right foreleg is raised
	# at rest), mirrored for the right.
	var front_paw: Vector3 = rest.call("paw_fl")
	var back_l: Vector3 = rest.call("paw_bl")
	var back_r: Vector3 = rest.call("paw_br")
	var back_paw := (back_l + back_r * Vector3(-1, 1, 1)) * 0.5
	for side in ["l", "r"]:
		var mirror := Vector3(1, 1, 1) if side == "l" else Vector3(-1, 1, 1)
		var shoulder: Vector3 = rest.call("leg_f%s_0" % side)
		var elbow: Vector3 = rest.call("leg_f%s_1" % side)
		var wrist: Vector3 = rest.call("paw_f%s" % side)
		_legs.append({
			"name": "f" + side,
			"bones": [sk.find_bone("leg_f%s_0" % side), sk.find_bone("leg_f%s_1" % side)],
			"paw": sk.find_bone("paw_f%s" % side),
			"root": shoulder, "lengths": [shoulder.distance_to(elbow), elbow.distance_to(wrist)],
			"stand": front_paw * mirror,
			"pole": Vector3(0, 0, -1),  # elbows point back
		})
		var hip: Vector3 = rest.call("leg_b%s_0" % side)
		var knee: Vector3 = rest.call("leg_b%s_1" % side)
		var hock: Vector3 = rest.call("leg_b%s_2" % side)
		var ankle: Vector3 = rest.call("paw_b%s" % side)
		_legs.append({
			"name": "b" + side,
			"bones": [sk.find_bone("leg_b%s_0" % side), sk.find_bone("leg_b%s_1" % side)],
			"hock": sk.find_bone("leg_b%s_2" % side), "hock_offset": hock - ankle,
			"paw": sk.find_bone("paw_b%s" % side),
			"root": hip, "lengths": [hip.distance_to(knee), knee.distance_to(hock)],
			"stand": back_paw * mirror,
			"pole": knee - (hip + hock) * 0.5,  # bent as at rest
		})


## The current gait's settings, blended between the two gaits either side of _gait.
func _gait_value(key: String) -> float:
	var i := mini(int(_gait), GAITS.size() - 2)
	return lerpf(GAITS[i][key], GAITS[i + 1][key], _gait - i)


func _gait_offset(leg: String) -> float:
	var i := mini(int(_gait), GAITS.size() - 2)
	return lerpf(GAITS[i].offsets[leg], GAITS[i + 1].offsets[leg], _gait - i)


func _animate(delta: float, moved: float) -> void:
	if _skeleton == null:
		return
	var speed := Vector2(velocity.x, velocity.z).length()
	_moving = move_toward(_moving, 1.0 if speed > 0.15 else 0.0, delta * 3.0)
	# Which gait suits this speed: 0 at a walk's speed or slower, 1 at a trot's, 2 at a run's.
	var want := 0.0
	for i in GAITS.size() - 1:
		var lo: float = GAITS[i].speed
		var hi: float = GAITS[i + 1].speed
		want += clampf((speed - lo) / (hi - lo), 0.0, 1.0)
	_gait = move_toward(_gait, want, delta * 1.5)
	var stride := _gait_value("stride")
	var duty := _gait_value("duty")
	var lift_height := _gait_value("lift")
	var extend := _gait_value("extend")
	# One cycle covers the distance a paw travels while planted, over its planted share.
	_phase = fmod(_phase + moved / (stride / duty), 1.0)

	_animate_body(delta)
	var sk := _skeleton.global_transform
	var to_sk := sk.affine_inverse()
	var space := get_world_3d().direct_space_state
	for leg in _legs:
		var c := fmod(_phase + _gait_offset(leg.name), 1.0)
		var reach := 0.0
		var lift := 0.0
		if c < duty:
			reach = lerpf(0.5, -0.5, c / duty)  # planted: the body moves on over it
		else:
			var s := (c - duty) / (1.0 - duty)
			reach = lerpf(-0.5, 0.5, smoothstep(0.0, 1.0, s))  # swinging forward
			lift = sin(PI * s)
			if leg.name.begins_with("b"):
				reach -= extend * sin(PI * minf(s / 0.45, 1.0))  # kicks back after push-off
			else:
				reach += extend * sin(PI * maxf((s - 0.5) / 0.5, 0.0))  # reaches out to land
		var stand: Vector3 = leg.stand
		var paw := stand + Vector3(0, 0, reach * stride * _moving)  # +Z is the model's front
		var world := sk * paw
		world.y = _ground_at(space, world) + stand.y + lift * lift_height * _moving
		_place_leg(leg, to_sk * world, lift * _moving)
	_animate_head(delta)
	_animate_tail(delta)
	_animate_ears(delta)


## Crouch, bob and rock with the stride, and pitch with the slope under the paws.
func _animate_body(delta: float) -> void:
	var low := _gait_value("low")
	var bob := -_gait_value("bob") * cos(TAU * 2.0 * (_phase - low)) * _moving
	var rock := _gait_value("rock") * cos(TAU * (_phase - low)) * _moving
	var space := get_world_3d().direct_space_state
	var front := global_position - global_basis.z * 0.3
	var back := global_position + global_basis.z * 0.25
	var slope := atan2(_ground_at(space, front) - _ground_at(space, back), 0.55)
	_pitch = lerpf(_pitch, clampf(slope, -0.4, 0.4), 1.0 - exp(-6.0 * delta))
	# Pitching about the node's X raises its front (-Z) for a positive angle.
	_model.transform = Transform3D(Basis(Vector3.RIGHT, _pitch + rock) * Basis(Vector3.UP, PI),
		Vector3(0.0, -_gait_value("crouch") + bob, 0.0))


## Bends a leg so its paw reaches `paw` (skeleton space), curling the paw by `curl` (0 to
## 1) as it swings through.
func _place_leg(leg: Dictionary, paw: Vector3, curl: float) -> void:
	var lengths: Array = leg.lengths
	var bones: Array = leg.bones
	var root: Vector3 = leg.root
	var end := paw + (leg.hock_offset as Vector3 if leg.has("hock") else Vector3.ZERO)
	var joint := _two_bone(root, end, lengths[0], lengths[1], leg.pole)
	# Out of reach (a leg stretched out in flight), the leg points at it, straight, and
	# the paw stays on the end of it.
	var dir := (end - root).normalized()
	var reached := root + dir * minf(root.distance_to(end), lengths[0] + lengths[1] - 0.001)
	paw += reached - end
	end = reached
	_aim(bones[0], root, joint)
	_aim(bones[1], joint, end)
	if leg.has("hock"):
		_aim(leg.hock, end, paw)
	var p: int = leg.paw
	var paw_basis := Basis(Vector3.RIGHT, curl * 0.9) * _skeleton.get_bone_global_rest(p).basis  # toes tuck down
	_skeleton.set_bone_global_pose(p, Transform3D(paw_basis, paw))


## The middle joint of a two-bone chain from `root` reaching for `target`, bent toward
## `pole`.
static func _two_bone(root: Vector3, target: Vector3, l1: float, l2: float, pole: Vector3) -> Vector3:
	var d := target - root
	var dist := clampf(d.length(), absf(l1 - l2) + 0.001, l1 + l2 - 0.001)
	var dir := d.normalized()
	var a := (l1 * l1 - l2 * l2 + dist * dist) / (2.0 * dist)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var side := (pole - dir * pole.dot(dir)).normalized()
	return root + dir * a + side * h


## Poses a bone at `from` pointing (its +Y) at `to`, turned from its rest orientation by
## the shortest rotation.
func _aim(bone: int, from: Vector3, to: Vector3) -> void:
	var base := _skeleton.get_bone_global_rest(bone).basis.orthonormalized()
	var want := (to - from).normalized()
	var turn := Quaternion(base.y.normalized(), want) if base.y.normalized().dot(want) > -0.999 else Quaternion.IDENTITY
	_skeleton.set_bone_global_pose(bone, Transform3D(Basis(turn) * base, from))


## Turns a bone from its rest pose by `turn`, given in skeleton space.
func _turn(bone_name: String, turn: Quaternion) -> void:
	var bone := _skeleton.find_bone(bone_name)
	var g := _skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion()
	var rest := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
	_skeleton.set_bone_pose_rotation(bone, rest * (g.inverse() * turn * g))


func _animate_head(delta: float) -> void:
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var watching := false
	var running := clampf(_gait - 1.0, 0.0, 1.0) * _moving
	if player and running < 0.5 and global_position.distance_to(player.global_position) < curious_range:
		# Turns to watch the player, as far as its neck allows.
		var head := _skeleton.global_transform * _skeleton.get_bone_global_pose(_skeleton.find_bone("head")).origin
		var to := _skeleton.global_transform.basis.inverse() * (player.global_position + Vector3.UP * 1.4 - head)
		_look_want = Vector2(clampf(atan2(to.x, to.z), -1.1, 1.1),
			clampf(atan2(to.y, Vector2(to.x, to.z).length()), -0.3, 0.5))
		watching = true
	elif _state == State.IDLE:
		_glance_timer -= delta
		if _glance_timer <= 0.0:
			_look_want = Vector2(randf_range(-0.9, 0.9), randf_range(-0.15, 0.25))
			_glance_timer = randf_range(1.0, 2.5)
	else:
		_look_want = Vector2.ZERO
	_look = _look.lerp(_look_want, 1.0 - exp(-(4.0 if watching else 3.0) * delta))
	# A walk nods with each step; faster gaits hold the head steadier, reaching forward.
	var nod := sin(_phase * TAU * 2.0) * 0.05 * _moving * clampf(1.0 - _gait, 0.0, 1.0)
	var reach := _gait_value("head") * _moving
	# Against the run's rocking, so the head stays level on its target.
	var steady := -_gait_value("rock") * cos(TAU * (_phase - _gait_value("low"))) * _moving
	_turn("neck", Quaternion(Vector3.UP, _look.x * 0.4) * Quaternion(Vector3.RIGHT, -_look.y * 0.4 + reach * 0.6 - steady * 0.5))
	_turn("head", Quaternion(Vector3.UP, _look.x * 0.6) * Quaternion(Vector3.RIGHT, -_look.y * 0.6 + nod + reach * 0.4 - steady * 0.5))


func _animate_tail(delta: float) -> void:
	# Now and then while standing it gives a slow, wide swish.
	_swish_timer -= delta
	if _swish_timer <= 0.0:
		_swish_timer = randf_range(3.0, 7.0)
		if _state == State.IDLE:
			_swish = 1.0
	_swish = maxf(_swish - delta * 0.35, 0.0)
	var stream := _gait_value("tail") * _moving
	# Sways less the faster it goes; at a run it streams out, riding the bounds.
	var amp := (0.12 + 0.25 * _swish) * (1.0 - 0.7 * stream)
	for k in 6:
		var wave := sin(_t * (2.2 + _gait) - k * 0.75)
		var sway := Quaternion(Vector3.UP, wave * amp * (0.5 + k * 0.12))
		# Uncurling: each joint swings back toward the tail's root line.
		var uncurl := -stream * (0.5 if k == 0 else 0.42)
		var ride := sin(TAU * (_phase - 0.3) - k * 0.6) * 0.12 * stream
		var lift := Quaternion(Vector3.RIGHT, sin(_t * 0.9 - k * 0.5) * 0.05 + uncurl + ride)
		_turn("tail_%d" % k, sway * lift)


func _animate_ears(delta: float) -> void:
	var back := _gait_value("ears") * _moving
	for side in ["l", "r"]:
		var s := 1.0 if side == "l" else -1.0
		_ear_timer[side] -= delta
		if _ear_timer[side] <= 0.0:
			_ear_timer[side] = randf_range(1.5, 5.0)
			_ear_twitch[side] = 1.0
		_ear_twitch[side] = maxf(_ear_twitch[side] - delta * 4.0, 0.0)
		var twitch: float = sin(_ear_twitch[side] * PI) * 0.5 * (1.0 - back)
		var ear := _skeleton.get_bone_global_rest(_skeleton.find_bone("ear_%s_0" % side))
		# A twitch swivels the ear about its own length; running lays them back (toward
		# -Z), and the tips flop with each step.
		_turn("ear_%s_0" % side, Quaternion(Vector3.RIGHT, -back) * Quaternion(ear.basis.y.normalized(), -s * twitch))
		_turn("ear_%s_1" % side, Quaternion(Vector3.RIGHT, sin(_phase * TAU * 2.0 + 1.0) * 0.12 * _moving - back * 0.3))


func _ground_at(space: PhysicsDirectSpaceState3D, p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.0, p + Vector3.DOWN * 1.5, 1, [get_rid()])
	var hit := space.intersect_ray(q)
	return hit.position.y if hit else global_position.y
