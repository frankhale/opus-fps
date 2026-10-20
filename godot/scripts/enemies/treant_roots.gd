class_name TreantRoots
extends Node3D
## Roots a treant sends up under the player when it slams its claws into the ground.
## For `warn_time` the ground there gives it away: a dark ring spreads on it and dirt
## spurts up as it rumbles. Then a clump of sharp roots bursts out: one in the middle and
## a ring round it, leaning outward. Anyone standing within `radius` (and not jumped
## clear above it) takes `damage` and is thrown up into the air (one hit per burst). The
## roots stand a moment, then sink back into the ground and it frees itself.

const PALETTE := preload("res://materials/ps1_palette.tres")
const SOUND := preload("res://assets/sfx/treant_roots.wav")
const RING_COLOR := Color(0.18, 0.11, 0.05)
const DIRT_COLOR := Color(0.29, 0.21, 0.16)
## Palette swatches (8 x 4, row 0 at the top): dark bark, wood and light wood.
const DBARK_UV := Vector2(3.5 / 8.0, 1.5 / 4.0)
const WOOD_UV := Vector2(4.5 / 8.0, 1.5 / 4.0)
const LWOOD_UV := Vector2(5.5 / 8.0, 1.5 / 4.0)

var radius := 1.4
var damage := 20.0
## Seconds of warning before they burst out (the sound's burst comes at 0.58 s).
var warn_time := 0.58
var hold_time := 1.1
var sink_time := 0.45
## How hard the burst throws the player up (m/s).
var toss := 7.0

var _age := 0.0
var _hit_done := false
var _ring: Decal
var _dirt: GPUParticles3D
## The roots: [MeshInstance3D, direction (leaning out), height, foot (local)].
var _roots: Array = []

static var _mesh: ArrayMesh


func _ready() -> void:
	top_level = true
	var audio := AudioStreamPlayer3D.new()
	audio.stream = SOUND
	audio.unit_size = 8.0
	audio.volume_db = 3.0
	add_child(audio)
	audio.play()

	_ring = Decal.new()
	_ring.texture_albedo = Enemy._make_ring_texture()
	_ring.size = Vector3(0.1, 3.0, 0.1)
	_ring.modulate = RING_COLOR
	_ring.upper_fade = 0.5
	_ring.lower_fade = 0.5
	add_child(_ring)

	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	m.emission_ring_axis = Vector3.UP
	m.emission_ring_radius = radius * 0.8
	m.emission_ring_inner_radius = 0.0
	m.emission_ring_height = 0.0
	m.direction = Vector3.UP
	m.spread = 25.0
	m.initial_velocity_min = 1.0
	m.initial_velocity_max = 3.0
	m.gravity = Vector3(0, -9.8, 0)
	m.scale_min = 0.05
	m.scale_max = 0.11
	m.color = DIRT_COLOR
	_dirt = FX.emitter(40, 0.5, m, FX.quad(false), false)
	add_child(_dirt)
	_dirt.emitting = true

	if _mesh == null:
		_mesh = _root_mesh()
	var count := 7
	for i in count:
		var dir := Vector3.UP
		var at := Vector3.ZERO
		var height := 1.5
		if i > 0:
			var a := TAU * (i - 1) / (count - 1) + randf_range(-0.3, 0.3)
			var out := Vector3(cos(a), 0.0, sin(a))
			at = out * radius * randf_range(0.5, 0.75)
			dir = (Vector3.UP + out * randf_range(0.35, 0.6)).normalized()
			height = randf_range(0.9, 1.3)
		var root := MeshInstance3D.new()
		root.mesh = _mesh
		root.visible = false
		add_child(root)
		_roots.append([root, dir, height * randf_range(0.9, 1.1), at])


func _process(delta: float) -> void:
	_age += delta
	var spread := clampf(_age / warn_time, 0.0, 1.0)
	_ring.size = Vector3(radius * 2.0 * spread, 3.0, radius * 2.0 * spread)
	if _age < warn_time:
		return
	var t := _age - warn_time
	_dirt.emitting = t < 0.15
	# Up fast with a little overshoot, stand, then sink back.
	var grow := 0.0
	if t < 0.14:
		grow = sin(t / 0.14 * PI * 0.5) * 1.12
	elif t < 0.24:
		grow = lerpf(1.12, 1.0, (t - 0.14) / 0.1)
	elif t < hold_time:
		grow = 1.0
	else:
		grow = 1.0 - (t - hold_time) / sink_time
	_ring.modulate = RING_COLOR * clampf(1.0 - (t - hold_time) / sink_time, 0.0, 1.0)
	for r in _roots:
		var mi: MeshInstance3D = r[0]
		var h: float = r[2]
		mi.visible = grow > 0.01
		var basis := Basis(Quaternion(Vector3.UP, r[1]))
		# Grows up out of the ground, the buried part kept below it.
		mi.transform = Transform3D(basis * Basis.from_scale(Vector3(0.9, h, 0.9)),
			(r[3] as Vector3) + r[1] * h * (grow - 1.0))
	if not _hit_done and t < 0.2:
		_check_hit()
	if t > hold_time + sink_time:
		queue_free()


func _check_hit() -> void:
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player == null or player.get("dead"):
		return
	var off := player.global_position - global_position
	if Vector2(off.x, off.z).length() > radius + 0.3 or off.y > 1.2 or off.y < -1.0:
		return
	_hit_done = true
	var out := Vector3(off.x, 0.0, off.z).normalized() if Vector2(off.x, off.z).length() > 0.05 else Vector3.ZERO
	player.take_damage(damage, player.global_position, (out + Vector3.UP).normalized())
	if player is CharacterBody3D:
		(player as CharacterBody3D).velocity = Vector3(out.x * 2.5, toss, out.z * 2.5)


## A sharp root along +Y, a meter tall before scaling and starting a little below the
## ground: a five-sided dark bark shaft with a knot halfway and a pale splintered point.
static func _root_mesh() -> ArrayMesh:
	var ring := func(r: float, y: float, twist: float) -> Array:
		var pts := []
		for i in 5:
			var a := TAU * i / 5.0 + twist
			pts.append(Vector3(cos(a) * r, y, sin(a) * r))
		return pts
	var rings: Array = [ring.call(0.16, -0.25, 0.0), ring.call(0.13, 0.35, 0.3), ring.call(0.11, 0.5, 0.1),
		ring.call(0.06, 0.8, 0.4)]
	var uvs := [DBARK_UV, WOOD_UV, DBARK_UV]
	var tip := Vector3(0.02, 1.0, 0.0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in 3:
		var a: Array = rings[k]
		var b: Array = rings[k + 1]
		st.set_uv(uvs[k])
		for i in 5:
			var j := (i + 1) % 5
			for v in [a[i], b[i], b[j], a[i], b[j], a[j]]:
				st.add_vertex(v)
	st.set_uv(LWOOD_UV)
	var top: Array = rings[3]
	for i in 5:
		for v in [top[i], tip, top[(i + 1) % 5]]:
			st.add_vertex(v)
	st.generate_normals()
	st.set_material(PALETTE)
	return st.commit()
