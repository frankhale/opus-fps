class_name Lovebird
extends CharacterBody3D
## The lovebird (assets/enemies/enemy_lovebird.glb): a rosy-faced lovebird, bright green
## with a red forehead and pink cheeks, flying about over the island and perching on things.
## It's harmless, like the jellyfish: no aggro ring, health or attack. It's solid to shots
## and stays off the minimap.
##
## It flies on and on between random spots near home (`can_hover` keeps it over the
## island), `fly_height` above whatever is below, in long sweeping turns: it can only turn
## so fast (`turn_rate`), so it swings round in arcs, banking into each turn and pitching
## up as it climbs and down as it dives, and speeding up a little as it dives. It keeps
## clear of the ground, and if it bumps into something it heads off somewhere else.
##
## Every few seconds in flight it may look for somewhere to perch (`perch_chance`): the top
## of any solid object nearby that it can see, such as a tree, a rock, a wall, the ruins, a
## crate or a barrel. A perch has to be fairly flat, stand at least PERCH_RAISE above what's
## under it (so the ground itself doesn't count), have open air above to come down through,
## and not be taken by another lovebird. It flies over to it, slowing and turning tighter as
## it nears, then swoops down onto it, flaring with its body tipped up, wings beating hard
## and swept forward to brake, and its feet reaching down. Perched, it sits up with its
## wings folded along its sides and its tail hanging, glancing about in quick little turns
## of the head, flicking its tail and now and then hopping round to face another way. It
## flies off after a while (`perch_time`), when the player comes within `flush_range`
## (away from them), or if its perch is knocked about or blown up.
##
## It flies the way small parrots do: bursts of quick wingbeats (`flap_rate`), then short
## glides on outstretched wings. It flaps harder and faster climbing, and glides more
## going down. It's animated procedurally on its rig (see enemy_lovebird in the asset
## generator). Each wingbeat sweeps the whole wing down and a little forward, then on the
## upstroke the wrist folds the hand back so the wing comes up half closed, the hand
## lagging the arm so the tip whips round. The body bobs with each downstroke, the tail
## tips with the beat and spreads into a turn, the head stays level as the body pitches
## and banks, and the feet are tucked back under the tail while it cruises. To fold its
## wings it sweeps each one back along its side, turned edge-up, and draws the hand in.

const MODEL := preload("res://assets/enemies/enemy_lovebird.glb")
## Its shoulders' raise through a wingbeat: the top and bottom of the stroke (radians).
const STROKE_TOP := 0.95
const STROKE_BOTTOM := -0.75
## Gliding, the wings are held a little raised (radians).
const GLIDE_RAISE := 0.12
## Seconds of flapping, then of gliding, between glides.
const FLAP_SPELL := Vector2(0.9, 2.4)
const GLIDE_SPELL := Vector2(0.4, 1.1)
## How far its heading may point up or down (as the sine of the angle).
const MAX_CLIMB := 0.45
## The lowest it flies over whatever is below, before it pulls up (m).
const MIN_CLEARANCE := 1.5
## How far it banks per radian a second of turning, and its steepest bank (radians).
const BANK := 0.55
const MAX_BANK := 1.0
## A perch must be at least this high above whatever is under it (m), as flat as this
## (the up component of its surface's normal), and have this much open air above it (m).
const PERCH_RAISE := 0.6
const PERCH_FLAT := 0.85
const PERCH_HEADROOM := 2.0
## Two lovebirds don't perch closer together than this (m).
const PERCH_SPACING := 0.6
## Perched, its body is tipped up this far (radians), and its toes are this far below and
## ahead of its origin (m, at model_scale 1), measured on the folded pose.
const PERCH_PITCH := 0.6
const FOOT_DROP := 0.04
const FOOT_AHEAD := 0.017
## How far it tips up as it flares to land (radians).
const FLARE_PITCH := 0.9
## The folded wing: how much the arm and hand are drawn in, so the long primaries lie
## over the tail rather than past it.
const FOLD_ARM := 0.8
const FOLD_HAND := 0.55
## It gives up on a perch it hasn't reached in this many seconds.
const APPROACH_TIME := 12.0
## How far its perch may move, or tip (radians), before it takes fright and flies off.
const PERCH_SHIFT := 0.05
const PERCH_TIP := 0.3

@export var model_scale := 1.0
@export var speed := 4.5
## Turning rate (radians a second): how tight its arcs are.
@export var turn_rate := 1.4
## Wingbeats a second, flapping steadily.
@export var flap_rate := 5.5
## How high it flies over whatever is below: the range each new spot is picked from.
@export var fly_height := Vector2(3.0, 8.0)
## The lowest ground it flies over (a level with a sea sets the water's surface, so it
## keeps above the waves rather than the sea bed).
@export var floor_min := -1000.0
## It stays within this far of where it started (across the ground).
@export var wander_radius := 20.0
## The chance, each time it thinks about it in flight (every few seconds), that it looks
## for a perch, and how far around it looks.
@export var perch_chance := 0.5
@export var perch_search := 16.0
## Seconds it sits on a perch before flying on.
@export var perch_time := Vector2(6.0, 20.0)
## It flies off its perch when the player comes this close.
@export var flush_range := 3.5

## Where it may fly to: (world point) -> bool. Set by the level; by default anywhere
## within wander_radius of home.
var can_hover: Callable

enum { FLYING, APPROACH, LANDING, PERCHED }

## Every lovebird's perch, by instance id, so two don't pick the same spot.
static var _perches := {}

var _state := FLYING
var _state_timer := 0.0
var _home := Vector3.ZERO
var _target := Vector3.ZERO
var _wander_timer := 0.0
var _perch_think := 0.0
var _t := 0.0
## Its heading (a unit vector) and the speed it flies along it.
var _dir := Vector3.FORWARD
var _speed := 0.0
## How fast it's turning (radians a second, smoothed) and its bank and pitch.
var _yaw_rate := 0.0
var _bank := 0.0
var _pitch := 0.0
## Wingbeat cycle position (0 at the top of the stroke), how much it's flapping rather
## than gliding (0 to 1), whether it wants to flap, and how long until it changes its mind.
var _phase := 0.0
var _flap := 1.0
var _flapping := true
var _spell := 1.0
## How far its feet are tucked up (0 hanging, 1 tucked).
var _tuck := 1.0

## The perch: the body it's on, the spot in that body's space and in the world (as it
## was when picked), and that body's up when it landed.
var _perch_body: CollisionObject3D
var _perch_local := Vector3.ZERO
var _perch_point := Vector3.ZERO
var _perch_up := Vector3.UP
## Landing: where the swoop starts, the point it curves through, the way it faces at the
## end, and how far through it is (0 to 1) over how many seconds.
var _land_from := Vector3.ZERO
var _land_via := Vector3.ZERO
var _land_yaw := 0.0
var _land_t := 0.0
var _land_time := 1.0
## How far into the flare it is (0 to 1), and how far settled on the perch with its wings
## folded (0 to 1).
var _flare := 0.0
var _perched := 0.0
## Perched: the way it faces, its head's look (yaw, pitch) and where it wants to look,
## and its little hops, tail flicks and glances.
var _yaw := 0.0
var _look := Vector2.ZERO
var _look_want := Vector2.ZERO
var _glance_timer := 1.0
var _hop := 0.0
var _hop_timer := 8.0
var _flick := 0.0
var _flick_timer := 3.0

var _pivot: Node3D
var _model: Node3D
var _skeleton: Skeleton3D
var _bones := {}


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	collision_layer = Enemy.ENEMY_LAYER  # shots stop on it
	collision_mask = 1
	# A small ball round its body, held up off its feet so it's clear of its perch.
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.05 * model_scale
	shape.shape = sphere
	shape.position.y = 0.02 * model_scale
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
	_perch_think = randf_range(2.0, 6.0)
	var a := randf() * TAU
	_dir = Vector3(cos(a), 0.0, sin(a))
	_speed = speed  # it picks where to head on its first step, once the level has set can_hover


func _exit_tree() -> void:
	_release_perch()


func _physics_process(delta: float) -> void:
	_t += delta
	match _state:
		FLYING, APPROACH:
			_fly(delta)
		LANDING:
			_land(delta)
		PERCHED:
			_sit(delta)
	_animate(delta)


# ---------------------------------------------------------------------------
# Flying
# ---------------------------------------------------------------------------
func _fly(delta: float) -> void:
	var approaching := _state == APPROACH
	if approaching:
		_state_timer -= delta
		if not _perch_valid() or _state_timer <= 0.0:
			_give_up_perch()
			approaching = false
		else:
			# Make for a spot over the perch, and swoop down once close enough with it ahead.
			_target = _perch_point + Vector3.UP
			var to_perch := _perch_point - global_position
			if (_target - global_position).length() < 1.6 \
					or (to_perch.length() < 3.2 and to_perch.normalized().dot(_dir) > 0.2):
				_start_landing()
				return
	if not approaching:
		_wander_timer -= delta
		if _wander_timer <= 0.0 or (_target - global_position).length() < 2.0:
			_pick_target()
		_perch_think -= delta
		if _perch_think <= 0.0:
			_perch_think = randf_range(3.0, 7.0)
			if randf() < perch_chance and _find_perch():
				_state = APPROACH
				_state_timer = APPROACH_TIME

	# Steer toward the target, turning no faster than turn_rate, so it flies in arcs. Near
	# a perch it slows and turns tighter, so it doesn't circle round it.
	var to := _target - global_position
	var near := 0.0
	if approaching:
		near = 1.0 - smoothstep(2.0, 8.0, Vector2(to.x, to.z).length())
	var want := to.normalized()
	want.y = clampf(want.y, -MAX_CLIMB, MAX_CLIMB)
	var clearance := global_position.y - maxf(_ground_y(), floor_min)
	if clearance < MIN_CLEARANCE and near < 0.5:
		want.y = maxf(want.y, MAX_CLIMB * (1.0 - clearance / MIN_CLEARANCE))  # pull up
	want = want.normalized()
	var before := Vector2(_dir.x, _dir.z).angle()
	var angle := _dir.angle_to(want)
	if angle > 0.001:
		var rate := turn_rate * (1.0 + 1.5 * near)
		_dir = _dir.slerp(want, minf(1.0, rate * delta / angle)).normalized()
	var turned := angle_difference(before, Vector2(_dir.x, _dir.z).angle())
	_yaw_rate = lerpf(_yaw_rate, -turned / maxf(delta, 0.0001), 1.0 - exp(-4.0 * delta))

	# A little faster diving and slower climbing.
	var cruise := speed * (1.0 - 0.4 * _dir.y) * (1.0 - 0.55 * near)
	_speed = lerpf(_speed, cruise, 1.0 - exp(-2.0 * delta))
	velocity = _dir * _speed
	move_and_slide()
	if get_slide_collision_count() > 0:
		_dir = (_dir + get_slide_collision(0).get_normal() + Vector3.UP * 0.5).normalized()
		if _state == APPROACH:
			_give_up_perch()
		_pick_target()

	# Face along the heading; bank into the turn and pitch with the climb.
	rotation.y = atan2(-_dir.x, -_dir.z)
	_bank = lerpf(_bank, clampf(_yaw_rate * BANK, -MAX_BANK, MAX_BANK), 1.0 - exp(-3.0 * delta))
	_pitch = lerpf(_pitch, asin(clampf(_dir.y, -1.0, 1.0)) * 0.8, 1.0 - exp(-3.0 * delta))
	_flare = move_toward(_flare, 0.0, delta * 2.0)


func _pick_target() -> void:
	var allowed := can_hover if can_hover.is_valid() else func(_p: Vector3) -> bool: return true
	for i in 24:
		var a := randf() * TAU
		var p := global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(8.0, 22.0)
		if Vector2(p.x - _home.x, p.z - _home.z).length() < wander_radius and allowed.call(p):
			p.y = maxf(_ground_y_at(p), floor_min) + randf_range(fly_height.x, fly_height.y)
			_target = p
			_wander_timer = randf_range(6.0, 12.0)
			return
	_target = _home + Vector3.UP * fly_height.y  # nowhere new: head back home
	_wander_timer = 6.0


func _ground_y() -> float:
	return _ground_y_at(global_position)


func _ground_y_at(p: Vector3) -> float:
	var from := Vector3(p.x, maxf(p.y, global_position.y) + 1.0, p.z)
	var hit := _ray(from, from + Vector3.DOWN * 60.0, [get_rid()])
	return hit.position.y if hit else p.y - fly_height.x


func _ray(from: Vector3, to: Vector3, exclude: Array[RID]) -> Dictionary:
	var q := PhysicsRayQueryParameters3D.create(from, to, 1, exclude)
	return get_world_3d().direct_space_state.intersect_ray(q)


# ---------------------------------------------------------------------------
# Perching
# ---------------------------------------------------------------------------
## Looks for somewhere to perch among the solid things within perch_search: tries a few
## spots on top of each (in a random order) and takes the first that will do.
func _find_perch() -> bool:
	var allowed := can_hover if can_hover.is_valid() else func(_p: Vector3) -> bool: return true
	var query := PhysicsShapeQueryParameters3D.new()
	var ball := SphereShape3D.new()
	ball.radius = perch_search
	query.shape = ball
	query.transform = Transform3D(Basis(), global_position)
	query.collision_mask = 1
	query.exclude = [get_rid()]
	var found := get_world_3d().direct_space_state.intersect_shape(query, 48)
	found.shuffle()
	for f in found:
		var mesh := _mesh_of(f.collider as CollisionObject3D)
		if not mesh:
			continue
		var box := mesh.global_transform * mesh.get_aabb()
		for i in 3:
			var x := box.position.x + box.size.x * randf_range(0.2, 0.8)
			var z := box.position.z + box.size.z * randf_range(0.2, 0.8)
			var top := Vector3(x, box.end.y + 1.0, z)
			var hit := _ray(top, Vector3(x, box.position.y - 1.0, z), [get_rid()])
			if hit.is_empty() or not _mesh_of(hit.collider as CollisionObject3D):
				continue
			var p: Vector3 = hit.position
			if hit.normal.y < PERCH_FLAT or not allowed.call(p) \
					or Vector2(p.x - _home.x, p.z - _home.z).length() > wander_radius:
				continue
			# Something solid well below: it stands on the ground, it isn't the ground.
			var body := hit.collider as CollisionObject3D
			var under := _ray(p + Vector3.DOWN * 0.05, p + Vector3.DOWN * 40.0, [get_rid(), body.get_rid()])
			if under.is_empty() or p.y - under.position.y < PERCH_RAISE:
				continue
			# Open air above to come down through, and no other lovebird there already.
			if not _ray(p + Vector3.UP * 0.05, p + Vector3.UP * PERCH_HEADROOM, [get_rid()]).is_empty():
				continue
			if _perches.values().any(func(q: Vector3) -> bool: return q.distance_to(p) < PERCH_SPACING):
				continue
			_perch_body = body
			_perch_point = p
			_perch_local = body.global_transform.affine_inverse() * p
			_perches[get_instance_id()] = p
			return true
	return false


## The visible mesh a solid thing carries (an imported model's mesh holds its static body;
## a loose prop's rigid body holds its mesh), or null for anything you can't see or that
## moves about on its own (the player, creatures and enemies).
func _mesh_of(body: CollisionObject3D) -> GeometryInstance3D:
	if not body or body is CharacterBody3D:
		return null
	var parent := body.get_parent() as GeometryInstance3D
	if parent and parent.is_visible_in_tree():
		return parent
	for c in body.get_children():
		if c is GeometryInstance3D and c.is_visible_in_tree():
			return c
	return null


func _perch_valid() -> bool:
	return is_instance_valid(_perch_body) and _perch_body.is_inside_tree()


func _release_perch() -> void:
	_perches.erase(get_instance_id())
	_perch_body = null


func _give_up_perch() -> void:
	_release_perch()
	_state = FLYING
	_perch_think = randf_range(3.0, 7.0)
	_pick_target()


## Where its origin sits when perched: its toes on the perch, facing the way it faces.
func _rest_spot() -> Vector3:
	return _perch_point + (Vector3.UP * FOOT_DROP + global_basis.z * FOOT_AHEAD) * model_scale


func _start_landing() -> void:
	_state = LANDING
	_land_from = global_position
	var d := global_position.distance_to(_perch_point)
	# It swoops down in a curve: carried on along its heading at first, then dropping onto
	# the perch, slowing all the way.
	_land_via = global_position + _dir * d * 0.4
	_land_via.y = maxf(_land_via.y, _perch_point.y + 0.4)
	var flat := Vector2(_perch_point.x - global_position.x, _perch_point.z - global_position.z)
	if flat.length() < 0.2:
		flat = Vector2(_dir.x, _dir.z)
	_land_yaw = atan2(-flat.x, -flat.y)
	_land_t = 0.0
	_land_time = clampf(d / 2.4, 0.6, 1.4)
	_yaw_rate = 0.0


func _land(delta: float) -> void:
	if not _perch_valid():
		_take_off(Vector3.ZERO)
		return
	_land_t = minf(_land_t + delta / _land_time, 1.0)
	var t := 1.0 - (1.0 - _land_t) * (1.0 - _land_t)  # slowing to a stop
	rotation.y = lerp_angle(rotation.y, _land_yaw, 1.0 - exp(-6.0 * delta))
	var end := _rest_spot()
	global_position = _land_from.lerp(_land_via, t).lerp(_land_via.lerp(end, t), t)
	_flare = _land_t
	_bank = lerpf(_bank, 0.0, 1.0 - exp(-6.0 * delta))
	_pitch = lerpf(_pitch, FLARE_PITCH * _flare, 1.0 - exp(-8.0 * delta))
	if _land_t >= 1.0:
		_state = PERCHED
		_state_timer = randf_range(perch_time.x, perch_time.y)
		_perch_up = _perch_body.global_basis.y.normalized()
		_yaw = rotation.y
		velocity = Vector3.ZERO


func _sit(delta: float) -> void:
	if not _perch_valid():
		_take_off(Vector3.ZERO)
		return
	# Knocked about or tipped over: it takes fright.
	var now := _perch_body.global_transform * _perch_local
	if now.distance_to(_perch_point) > PERCH_SHIFT \
			or _perch_body.global_basis.y.normalized().angle_to(_perch_up) > PERCH_TIP:
		_take_off(Vector3.ZERO)
		return
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player and player.global_position.distance_to(global_position) < flush_range:
		_take_off(global_position - player.global_position)
		return
	_state_timer -= delta
	if _state_timer <= 0.0:
		_take_off(Vector3.ZERO)
		return

	# Now and then it hops round to face another way.
	_hop_timer -= delta
	if _hop_timer <= 0.0:
		_hop_timer = randf_range(5.0, 12.0)
		_yaw += randf_range(0.6, 1.6) * (1.0 if randf() < 0.5 else -1.0)
		_hop = 1.0
	_hop = move_toward(_hop, 0.0, delta * 3.5)
	rotation.y = lerp_angle(rotation.y, _yaw, 1.0 - exp(-8.0 * delta))
	_pitch = lerpf(_pitch, PERCH_PITCH, 1.0 - exp(-6.0 * delta))
	_flare = move_toward(_flare, 0.0, delta * 2.0)
	global_position = _rest_spot()


## Leaves its perch, springing up and on (away from `away`, if given).
func _take_off(away: Vector3) -> void:
	var flat := Vector3(away.x, 0.0, away.z)
	if flat.length() < 0.01:
		flat = -global_basis.z
	_dir = (flat.normalized() + Vector3.UP * 0.9).normalized()
	_speed = speed * 0.5
	_release_perch()
	_state = FLYING
	_flapping = true
	_spell = 1.2
	_flap = 1.0
	_hop = 0.0
	_perch_think = randf_range(6.0, 12.0)
	_pick_target()


# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------
# Turns are in the model's skeleton space: +X is the bird's left, +Y up, +Z forward. So a
# positive turn about +Z (BACK) raises the left wing (about -Z the right one), a positive
# turn about -Y (DOWN) sweeps the left wing forward (about +Y the right one), a negative
# turn about X lifts a wing's leading edge (or the head), and a positive one raises the
# tail or swings the feet back.
func _animate(delta: float) -> void:
	var landing := _state == LANDING
	var sitting := _state == PERCHED
	_perched = move_toward(_perched, 1.0 if sitting else 0.0, delta * (2.5 if sitting else 6.0))

	# Flap in bursts with glides between: steadily when climbing, gliding more going down,
	# and hard all through a landing.
	_spell -= delta
	if _spell <= 0.0:
		_flapping = not _flapping
		var spell := FLAP_SPELL if _flapping else GLIDE_SPELL
		_spell = randf_range(spell.x, spell.y)
	var flap := _flapping or _dir.y > 0.1
	if _dir.y < -0.2:
		flap = false
	if landing or _state == APPROACH and (_perch_point - global_position).length() < 5.0:
		flap = true
	# A glide starts halfway down a downstroke, where the wings are about level, so they
	# settle into it rather than snapping up or down.
	var want := 1.0 if flap else 0.0
	if not flap and _flap > 0.5 and absf(_phase - 0.25) > 0.06:
		want = 1.0
	_flap = move_toward(_flap, want, delta * 4.0)
	var rate := flap_rate * (1.0 + 0.4 * maxf(_dir.y, 0.0) / MAX_CLIMB + 0.5 * _flare)
	_phase = fmod(_phase + delta * rate * maxf(_flap, 0.3), 1.0)

	var c := cos(TAU * _phase)
	var down := maxf(0.0, sin(TAU * _phase))  # the downstroke
	var up := maxf(0.0, -sin(TAU * _phase))  # the upstroke, with the wing folding
	# Settled on a perch the wings are folded; a hop opens them a little.
	var hop := sin(PI * _hop)
	var fold := _perched * (1.0 - 0.3 * hop)
	var f := _flap * (1.0 - _perched)

	# The body rises a touch on each downstroke and sinks on the upstroke; perched it
	# breathes, and lifts off its feet as it hops.
	var breathe := 0.03 * sin(_t * 2.3) * _perched
	_pivot.position.y = (-0.012 * c * f + 0.025 * hop) * model_scale
	_pivot.rotation = Vector3(_pitch + 0.05 * c * f + breathe, 0.0, _bank * (1.0 - _perched))
	if not _skeleton:
		return

	for side in ["l", "r"]:
		var s := 1.0 if side == "l" else -1.0
		var raise := lerpf(GLIDE_RAISE, lerpf(STROKE_BOTTOM, STROKE_TOP, (c + 1.0) * 0.5), f)
		var brake := 0.35 * _flare  # flaring to land, the wings reach forward
		_turn("wing_%s_0" % side, (Quaternion(Vector3.BACK * s, raise)
			* Quaternion(Vector3.DOWN * s, (0.2 * down - 0.15 * up) * f + brake)).slerp(
			Quaternion(Vector3.BACK * s, -0.45) * Quaternion(Vector3.DOWN * s, -1.5)
			* Quaternion(Vector3.RIGHT, -1.35), fold))
		_turn("wing_%s_1" % side, (Quaternion(Vector3.BACK * s, 0.15 * cos(TAU * (_phase - 0.1)) * f)
			* Quaternion(Vector3.DOWN * s, -0.35 * up * f)).slerp(Quaternion.IDENTITY, fold))
		_turn("wing_%s_2" % side, (Quaternion(Vector3.BACK * s, (0.35 * cos(TAU * (_phase - 0.15)) * f) - 0.05 * (1.0 - f))
			* Quaternion(Vector3.DOWN * s, -0.9 * up * f) * Quaternion(Vector3.RIGHT, -0.25 * up * f)).slerp(
			Quaternion(Vector3.BACK * s, -0.4), fold))
		_skeleton.set_bone_pose_scale(_bones["wing_%s_1" % side], Vector3.ONE * lerpf(1.0, FOLD_ARM, fold))
		_skeleton.set_bone_pose_scale(_bones["wing_%s_2" % side], Vector3.ONE * lerpf(1.0, FOLD_HAND, fold))

	# The tail tips with the beat, lifts in a dive and drops climbing, and twists into a
	# turn. Perched it hangs, flicking up now and then.
	_flick_timer -= delta
	if _flick_timer <= 0.0:
		_flick_timer = randf_range(2.0, 6.0)
		_flick = 1.0
	_flick = move_toward(_flick, 0.0, delta * 4.0)
	var tail_pitch := -0.08 * c * f - _pitch * 0.5 * (1.0 - _perched)
	var tail_sit := Quaternion(Vector3.RIGHT, -0.15 + 0.4 * sin(PI * _flick))
	_turn("tail_0", (Quaternion(Vector3.BACK, _bank * 0.35) * Quaternion(Vector3.RIGHT, tail_pitch)).slerp(
		tail_sit, _perched))
	_turn("tail_1", Quaternion(Vector3.RIGHT, tail_pitch * 0.6 * (1.0 - _perched)))

	# The head stays nearly level as the body pitches and banks. Perched it glances about
	# in quick little turns.
	_glance_timer -= delta
	if _glance_timer <= 0.0:
		_glance_timer = randf_range(0.5, 2.5)
		_look_want = Vector2(randf_range(-1.2, 1.2), randf_range(-0.3, 0.35))
	_look = _look.lerp(_look_want, 1.0 - exp(-15.0 * delta))
	var head_fly := Quaternion(Vector3.BACK, _bank * 0.7) * Quaternion(Vector3.RIGHT, _pitch * 0.7 + 0.04 * c * f)
	var head_sit := Quaternion(Vector3.UP, _look.x) * Quaternion(Vector3.RIGHT, PERCH_PITCH * 0.75 + _look.y)
	_turn("head", head_fly.slerp(head_sit, _perched))

	# Feet tucked back while it cruises, let down when it slows to climb hard or to land,
	# and gripping the perch under it once it's down.
	var tuck_to := 0.0 if landing or _flare > 0.1 else (0.3 if _dir.y > 0.3 else 1.0)
	_tuck = move_toward(_tuck, tuck_to, delta * (5.0 if landing else 2.0))
	for side in ["l", "r"]:
		_turn("leg_%s" % side, Quaternion(Vector3.RIGHT, 1.1 * _tuck).slerp(Quaternion(Vector3.RIGHT, 0.85),
			_perched))


## Turns a bone from its rest pose by `turn`, given in skeleton space.
func _turn(bone_name: String, turn: Quaternion) -> void:
	var bone: int = _bones[bone_name]
	var g := _skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion()
	var rest := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
	_skeleton.set_bone_pose_rotation(bone, rest * (g.inverse() * turn * g))
