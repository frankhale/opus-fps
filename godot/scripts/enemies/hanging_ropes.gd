class_name HangingRopes
extends RefCounted
## Chains of bones simulated as little ropes, so a model's hangings (the arcane eye's
## chains and cloth, the jellyfish's tentacles) really swing. Each chain is a run of
## verlet points joined at fixed lengths, under gravity and air drag, pinned where it
## hangs from the model; every step its bones are aimed along it. So moving, speeding up
## and slowing, bobbing, tipping and turning all fling the hangings about, and they trail
## behind, overshoot and settle on their own. Each rope also eases back toward its rest
## shape (`stiff`) and stirs in a breeze (`breeze`).

## The furthest any segment swings from straight down (radians).
var max_swing: float
## Pull on the hangings (m/s²).
var gravity: Vector3

var _skeleton: Skeleton3D
## One per chain: "bones" (top first), "rest" (its joints and tip at rest, skeleton
## space), "points" and "prev" (the simulated joints now and a step ago, world space; the
## first is pinned), "lengths" (between joints, world space), "stiff" (how quickly it eases
## back toward its rest shape, per second), "drag" (air drag, per second), "breeze" (how
## much wind stirs it) and "phase" (its own offset in the breeze).
var _ropes: Array[Dictionary] = []


func _init(skeleton: Skeleton3D, swing_limit: float, pull := Vector3.DOWN * 9.8) -> void:
	_skeleton = skeleton
	max_swing = swing_limit
	gravity = pull


## Adds a chain (its bones, top first), hanging at rest. The bones must be equally long.
func add(bones: Array[int], stiff: float, drag: float, breeze: float) -> void:
	var rest := PackedVector3Array()
	for bone in bones:
		rest.append(_skeleton.get_bone_global_rest(bone).origin)
	rest.append(rest[-1] * 2.0 - rest[-2])  # the tip: the segments are equal
	var sk := _skeleton.global_transform
	var points := PackedVector3Array()
	var lengths := PackedFloat32Array()
	for i in rest.size():
		points.append(sk * rest[i])
		if i > 0:
			lengths.append(points[i].distance_to(points[i - 1]))
	_ropes.append({
		"bones": bones, "rest": rest, "points": points, "prev": points.duplicate(), "lengths": lengths,
		"stiff": stiff, "drag": drag, "breeze": breeze, "phase": randf() * TAU,
	})


## Adds every chain named <prefix><key>_<j> (j = 0, 1, ... top to bottom), one per key,
## and returns how many it found.
func add_named(prefix: String, stiff: float, drag: float, breeze: float) -> int:
	var groups := {}
	for i in _skeleton.get_bone_count():
		var bone := _skeleton.get_bone_name(i)
		if bone.begins_with(prefix):
			var cut := bone.rfind("_")
			groups.get_or_add(bone.substr(0, cut), {})[int(bone.substr(cut + 1))] = i
	for key: String in groups:
		var bones: Array[int] = []
		for j in range((groups[key] as Dictionary).size()):
			bones.append(groups[key][j])
		add(bones, stiff, drag, breeze)
	return groups.size()


## Steps each rope: carries its top along with the model, lets the rest fall, drift and
## swing, keeps the joints their lengths apart, then aims the bones along it. `t` is the
## running time, for the breeze.
func step(delta: float, t: float) -> void:
	if _ropes.is_empty():
		return
	var sk := _skeleton.global_transform
	var to_sk := sk.affine_inverse()
	for rope in _ropes:
		var rest: PackedVector3Array = rope.rest
		var points: PackedVector3Array = rope.points
		var prev: PackedVector3Array = rope.prev
		var lengths: PackedFloat32Array = rope.lengths
		var keep := exp(-float(rope.drag) * delta)
		var ease_back := 1.0 - exp(-float(rope.stiff) * delta)
		var ph: float = rope.phase
		var wind := Vector3(sin(t * 1.3 + ph), 0.0, cos(t * 0.9 + ph * 1.3)) * 2.0 * float(rope.breeze)
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
				# However they're flung, they never swing up past max_swing from straight down.
				var lean := d.angle_to(Vector3.DOWN)
				if lean > max_swing:
					d = Vector3.DOWN.slerp(d, max_swing / lean)
				points[i] = points[i - 1] + d * lengths[i - 1]
		rope.points = points
		rope.prev = prev
		var bones: Array[int] = rope.bones
		for j in bones.size():
			_aim(bones[j], to_sk * points[j], to_sk * points[j + 1])


## Poses a bone at `from` pointing (its +Y) at `to` (skeleton space), turned from its rest
## orientation by the shortest rotation.
func _aim(bone: int, from: Vector3, to: Vector3) -> void:
	var base := _skeleton.get_bone_global_rest(bone).basis.orthonormalized()
	var want := (to - from).normalized()
	var turn := Quaternion(base.y.normalized(), want) if base.y.normalized().dot(want) > -0.999 else Quaternion.IDENTITY
	_skeleton.set_bone_global_pose(bone, Transform3D(Basis(turn) * base, from))
