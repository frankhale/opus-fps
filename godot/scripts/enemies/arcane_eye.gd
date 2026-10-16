class_name ArcaneEye
extends CharacterBody3D
## The arcane eye (assets/enemies/enemy_arcane_eye.glb): an ornate eye in a thorny brass
## frame that floats about like the floating eye, but harmlessly. It has no aggro ring,
## health or attack. It drifts slowly between spots near home, hovering `hover_height`
## above whatever is below with a gentle bob, swaying and tipping into its drift. When the
## player is within `watch_range` it turns its gaze on them, tilting to look up or down at
## them. A dim violet light pulses round it. It's solid to shots, which just stop on it,
## and stays off the minimap.
##
## Its hangings are rigged (see enemy_arcane_eye in the asset generator): each chain and
## each cloth strip is a run of three bones. Here each one is simulated as a little rope
## (verlet points joined by fixed lengths, under gravity and air drag) pinned to the frame
## where it hangs, and its bones are aimed along the rope every frame. So they really
## swing: drifting, speeding up and slowing, bobbing, tipping and turning all fling them
## about, and they trail behind, overshoot and settle on their own. The cloth is a little
## stiff (it eases back toward hanging straight) and stirs in a faint breeze. Now and then
## it glances aside and back, so even idle it sets them swaying.
##
## It blinks: every few seconds (now and then twice) its lids snap shut across the eye and
## open again. While it watches the player it narrows them to a suspicious squint.

const MODEL := preload("res://assets/enemies/enemy_arcane_eye.glb")
const LIGHT_COLOR := Color(0.62, 0.3, 1.0)
## The furthest any segment of a hanging swings from straight down (radians).
const MAX_SWING := deg_to_rad(80.0)
## How far the lids turn to shut (radians): the model's rest pose has them open by this
## much (LID_OPEN in the asset generator).
const LID_OPEN := deg_to_rad(50.0)
## A blink's timing: closing, held shut, opening (seconds).
const BLINK_CLOSE := 0.08
const BLINK_HOLD := 0.05
const BLINK_OPEN := 0.17
## How far the lids narrow while it watches the player (0 open, 1 shut).
const SQUINT := 0.3

@export var model_scale := 1.3
@export var speed := 1.2
@export var hover_height := 2.8
## It stays within this far of where it started (across the ground).
@export var wander_radius := 20.0
## It turns to watch the player within this distance.
@export var watch_range := 12.0

## Where it may drift to: (world point) -> bool. Set by the level (the island keeps it
## over the island); by default anywhere within wander_radius of home.
var can_hover: Callable

var _home := Vector3.ZERO
var _target := Vector3.ZERO
var _wander_timer := 0.0
var _t := 0.0
var _model: Node3D
var _skeleton: Skeleton3D
var _light: OmniLight3D
## Gaze pitch (radians, up positive), eased.
var _gaze := 0.0
## A sideways glance (radians from where it would look) and when to take the next.
var _glance := 0.0
var _glance_timer := 2.0
## One per chain and cloth strip: "bones" (top first), "rest" (its joints and tip at rest,
## skeleton space), "points" and "prev" (the simulated joints now and a step ago, world
## space; the first is pinned), "lengths" (between joints, world space), "stiff" (how
## quickly it eases back toward its rest shape, per second), "drag" (air drag, per
## second) and "breeze" (how much wind stirs it).
var _ropes: Array[Dictionary] = []
## Blinking: seconds into the current blink (negative when not blinking), seconds until
## the next, whether another follows straight after, and the squint (eased).
var _blink_t := -1.0
var _blink_timer := 2.0
var _double := false
var _squint := 0.0
var _lid_upper := -1
var _lid_lower := -1


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	collision_layer = Enemy.ENEMY_LAYER  # shots stop on it
	collision_mask = 1
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.5 * model_scale
	shape.shape = sphere
	add_child(shape)

	_model = MODEL.instantiate()
	_model.scale = Vector3.ONE * model_scale
	_model.rotation.y = PI  # the eye looks down its +Z; this node "faces" -Z
	add_child(_model)
	# Kept out of the minimap's snapshot of the level, like the enemies.
	for g: GeometryInstance3D in _model.find_children("*", "GeometryInstance3D", true, false):
		g.layers = Enemy.ENEMY_VISUAL_LAYER

	_light = OmniLight3D.new()
	_light.light_color = LIGHT_COLOR
	_light.omni_range = 4.0
	_light.position = Vector3(0.0, 0.0, -0.4 * model_scale)
	add_child(_light)

	_home = global_position
	_target = global_position
	_t = randf() * 10.0
	var found := _model.find_children("*", "Skeleton3D", true, false)
	if not found.is_empty():
		_skeleton = found[0]
		_lid_upper = _skeleton.find_bone("lid_upper")
		_lid_lower = _skeleton.find_bone("lid_lower")
		_setup_ropes.call_deferred()  # once it's in place in the world


func _physics_process(delta: float) -> void:
	_t += delta
	_wander_timer -= delta
	if _wander_timer <= 0.0 or Vector2(_target.x - global_position.x, _target.z - global_position.z).length() < 1.0:
		_pick_target()

	var to := _target - global_position
	to.y = 0.0
	var desired := to.limit_length(1.0) * speed
	# Hold a hovering height over whatever is below, with a gentle bob.
	var target_y := _ground_y() + hover_height + sin(_t * 1.2) * 0.25
	desired.y = clampf((target_y - global_position.y) * 2.0, -2.0, 2.0)
	velocity = velocity.lerp(desired, 1.0 - exp(-1.5 * delta))
	move_and_slide()

	# Watches the player when they're near; otherwise looks the way it drifts.
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var gaze_want := 0.0
	if player and global_position.distance_to(player.global_position) < watch_range:
		var eyes := player.global_position + Vector3.UP * 1.5
		var off := eyes - global_position
		_face(off, delta, 2.5)
		gaze_want = clampf(atan2(off.y, Vector2(off.x, off.z).length()), -0.7, 0.5)
		_squint = lerpf(_squint, SQUINT, 1.0 - exp(-2.0 * delta))
	else:
		# Looks the way it drifts, glancing aside now and then.
		_glance_timer -= delta
		if _glance_timer <= 0.0:
			_glance = 0.0 if _glance != 0.0 else randf_range(0.7, 1.3) * (1.0 if randf() < 0.5 else -1.0)
			_glance_timer = randf_range(1.2, 2.0) if _glance != 0.0 else randf_range(3.0, 6.0)
		var ahead := to if to.length() > 0.3 else -global_basis.z
		_face(ahead.rotated(Vector3.UP, _glance), delta, 1.6)
	if gaze_want == 0.0:
		_squint = lerpf(_squint, 0.0, 1.0 - exp(-2.0 * delta))
	_gaze = lerpf(_gaze, gaze_want, 1.0 - exp(-3.0 * delta))

	# Sway, tipping into the drift (forward speed, in this node's frame), and the gaze.
	var local_v := global_basis.inverse() * velocity
	var tip := clampf(-local_v.z * 0.12, -0.25, 0.25)
	_model.rotation = Vector3(-_gaze + tip + sin(_t * 1.1) * 0.05, PI, sin(_t * 0.8) * 0.06 + clampf(local_v.x * 0.1, -0.2, 0.2))
	_light.light_energy = 0.7 + 0.25 * sin(_t * 2.3)
	_animate_hangings(delta)
	_animate_lids(delta)


func _pick_target() -> void:
	var allowed := can_hover if can_hover.is_valid() else func(_p: Vector3) -> bool: return true
	for i in 24:
		var a := randf() * TAU
		var p := global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(3.0, 9.0)
		if Vector2(p.x - _home.x, p.z - _home.z).length() < wander_radius and allowed.call(p):
			_target = p
			_wander_timer = randf_range(5.0, 10.0)
			return
	_target = _home  # nowhere new: drift back home
	_wander_timer = 4.0


## Turns toward `dir` about Y (this node faces -Z).
func _face(dir: Vector3, delta: float, rate: float) -> void:
	var flat := Vector3(dir.x, 0.0, dir.z)
	if flat.length() > 0.01:
		rotation.y = lerp_angle(rotation.y, atan2(-flat.x, -flat.z), 1.0 - exp(-rate * delta))


func _ground_y() -> float:
	var from := global_position + Vector3.UP
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 40.0, 1, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if hit else global_position.y - hover_height


## Finds the hanging chains of bones (pendant_<k>_<j>, cloth_<side>_<k>_<j>) and starts
## each rope hanging at rest.
func _setup_ropes() -> void:
	var groups := {}
	for i in _skeleton.get_bone_count():
		var name := _skeleton.get_bone_name(i)
		if name.begins_with("pendant_") or name.begins_with("cloth_"):
			var cut := name.rfind("_")
			groups.get_or_add(name.substr(0, cut), {})[int(name.substr(cut + 1))] = i
	var sk := _skeleton.global_transform
	for key: String in groups:
		var bones: Array[int] = []
		for j in range((groups[key] as Dictionary).size()):
			bones.append(groups[key][j])
		var rest := PackedVector3Array()
		for bone in bones:
			rest.append(_skeleton.get_bone_global_rest(bone).origin)
		rest.append(rest[-1] * 2.0 - rest[-2])  # the tip: the segments are equal
		var points := PackedVector3Array()
		var lengths := PackedFloat32Array()
		for i in rest.size():
			points.append(sk * rest[i])
			if i > 0:
				lengths.append(points[i].distance_to(points[i - 1]))
		var cloth := key.begins_with("cloth_")
		_ropes.append({
			"bones": bones, "rest": rest, "points": points, "prev": points.duplicate(), "lengths": lengths,
			"stiff": 1.5 if cloth else 0.6, "drag": 3.0 if cloth else 1.8, "breeze": 1.0 if cloth else 0.15,
			"phase": randf() * TAU,
		})


## Steps each rope: carries its top along with the frame, lets the rest fall, drift and
## swing, keeps the joints their lengths apart, then aims the bones along it.
func _animate_hangings(delta: float) -> void:
	if _skeleton == null or _ropes.is_empty():
		return
	var sk := _skeleton.global_transform
	var to_sk := sk.affine_inverse()
	var gravity := Vector3.DOWN * 9.8
	for rope in _ropes:
		var rest: PackedVector3Array = rope.rest
		var points: PackedVector3Array = rope.points
		var prev: PackedVector3Array = rope.prev
		var lengths: PackedFloat32Array = rope.lengths
		var keep := exp(-float(rope.drag) * delta)
		var ease_back := 1.0 - exp(-float(rope.stiff) * delta)
		var ph: float = rope.phase
		var wind := Vector3(sin(_t * 1.3 + ph), 0.0, cos(_t * 0.9 + ph * 1.3)) * 2.0 * float(rope.breeze)
		points[0] = sk * rest[0]
		prev[0] = points[0]
		for i in range(1, points.size()):
			var moving := (points[i] - prev[i]) * keep
			prev[i] = points[i]
			points[i] += moving + (gravity + wind) * delta * delta
			points[i] = points[i].lerp(sk * rest[i], ease_back)
		for pass_i in 3:
			for i in range(1, points.size()):
				var d := (points[i] - points[i - 1]).normalized()
				# Heavy as they are, they never swing up past MAX_SWING from hanging straight.
				var lean := d.angle_to(Vector3.DOWN)
				if lean > MAX_SWING:
					d = Vector3.DOWN.slerp(d, MAX_SWING / lean)
				points[i] = points[i - 1] + d * lengths[i - 1]
		rope.points = points
		rope.prev = prev
		var bones: Array[int] = rope.bones
		for j in bones.size():
			_aim(bones[j], to_sk * points[j], to_sk * points[j + 1])


## Blinks now and then, and holds the lids at the squint otherwise.
func _animate_lids(delta: float) -> void:
	if _skeleton == null or _lid_upper < 0:
		return
	var shut := 0.0
	if _blink_t >= 0.0:
		_blink_t += delta
		if _blink_t < BLINK_CLOSE:
			shut = _blink_t / BLINK_CLOSE
		elif _blink_t < BLINK_CLOSE + BLINK_HOLD:
			shut = 1.0
		else:
			shut = 1.0 - (_blink_t - BLINK_CLOSE - BLINK_HOLD) / BLINK_OPEN
			if shut <= 0.0:
				shut = 0.0
				_blink_t = -1.0
		shut = smoothstep(0.0, 1.0, shut)
	else:
		_blink_timer -= delta
		if _blink_timer <= 0.0:
			blink()
	var lids := maxf(shut, _squint)
	_turn(_lid_upper, Quaternion(Vector3.RIGHT, LID_OPEN * lids))
	_turn(_lid_lower, Quaternion(Vector3.RIGHT, -LID_OPEN * lids))


## Blinks once (and, now and then, again straight after).
func blink() -> void:
	_blink_t = 0.0
	if _double:
		_double = false  # the second of a pair: back to the usual wait
		_blink_timer = randf_range(2.0, 6.0)
	else:
		_double = randf() < 0.2
		_blink_timer = 0.12 if _double else randf_range(2.0, 6.0)


## Turns a bone from its rest pose by `turn`, given in skeleton space.
func _turn(bone: int, turn: Quaternion) -> void:
	var g := _skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion()
	var rest := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
	_skeleton.set_bone_pose_rotation(bone, rest * (g.inverse() * turn * g))


## Poses a bone at `from` pointing (its +Y) at `to` (skeleton space), turned from its rest
## orientation by the shortest rotation.
func _aim(bone: int, from: Vector3, to: Vector3) -> void:
	var base := _skeleton.get_bone_global_rest(bone).basis.orthonormalized()
	var want := (to - from).normalized()
	var turn := Quaternion(base.y.normalized(), want) if base.y.normalized().dot(want) > -0.999 else Quaternion.IDENTITY
	_skeleton.set_bone_global_pose(bone, Transform3D(Basis(turn) * base, from))
