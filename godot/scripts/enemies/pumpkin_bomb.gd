class_name PumpkinBomb
extends Node3D
## A glowing little jack-o'-lantern a pumpkin crab plucks off its back and lobs at the
## player. It tumbles through the air in an arc from where it's thrown to where it was
## aimed, trailing embers, and bursts into flame where it lands, or where it hits
## anything (the player included) on the way. Anyone within `radius` of the burst takes
## up to `damage` (less toward the edge) and is thrown up a little. Frees itself when done.

const FLAME := Color(1.0, 0.5, 0.12)

var damage := 22.0
var radius := 2.2
## Seconds in the air.
var flight_time := 0.95
## Bodies it flies through (the crab that threw it).
var exclude: Array[RID] = []

var _from := Vector3.ZERO
var _to := Vector3.ZERO
var _arc := 1.5
var _age := 0.0
var _spin := Vector3.ZERO
var _pumpkin: MeshInstance3D
var _trail: GPUParticles3D
var _done := false


## Sends it on its way from `from` to land at `to` (world points).
func launch(from: Vector3, to: Vector3) -> void:
	_from = from
	_to = to
	_arc = maxf(1.2, from.distance_to(to) * 0.22)
	global_position = from


func _ready() -> void:
	top_level = true
	_pumpkin = MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.13
	mesh.height = 0.2
	mesh.radial_segments = 6
	mesh.rings = 3
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.62, 0.22)
	mesh.material = mat
	_pumpkin.mesh = mesh
	_pumpkin.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_pumpkin)
	var stem := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = Vector3(0.03, 0.06, 0.03)
	var stem_mat := StandardMaterial3D.new()
	stem_mat.albedo_color = Color(0.18, 0.13, 0.1)
	box.material = stem_mat
	stem.mesh = box
	stem.position.y = 0.11
	_pumpkin.add_child(stem)

	var light := OmniLight3D.new()
	light.light_color = FLAME
	light.light_energy = 0.8
	light.omni_range = 2.5
	add_child(light)

	var m := ParticleProcessMaterial.new()
	m.direction = Vector3.UP
	m.spread = 180.0
	m.initial_velocity_min = 0.2
	m.initial_velocity_max = 0.8
	m.gravity = Vector3(0, 1.0, 0)
	m.scale_min = 0.05
	m.scale_max = 0.1
	m.scale_curve = FX.curve([Vector2(0, 1), Vector2(1, 0)])
	m.color_ramp = FX.ramp([Color(1, 0.9, 0.5), FLAME, Color(0.5, 0.1, 0.02, 0)], [0.0, 0.3, 1.0])
	_trail = FX.emitter(24, 0.45, m, FX.quad(true, 2.0), false)
	add_child(_trail)
	_trail.emitting = true
	_spin = Vector3(randf_range(-9, 9), randf_range(-4, 4), randf_range(-9, 9))


func _physics_process(delta: float) -> void:
	if _done:
		return
	_age += delta
	var t := minf(_age / flight_time, 1.0)
	var at := _from.lerp(_to, t) + Vector3.UP * _arc * 4.0 * t * (1.0 - t)
	# Bursts on whatever it meets between here and there.
	var q := PhysicsRayQueryParameters3D.create(global_position, at, 1, exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	if hit:
		_burst(hit.position)
		return
	global_position = at
	_pumpkin.rotation += _spin * delta
	if t >= 1.0:
		_burst(at)


func _burst(at: Vector3) -> void:
	_done = true
	global_position = at
	_pumpkin.visible = false
	_trail.emitting = false
	var boom := Explosion.new()
	boom.size = 0.9
	boom.color = FLAME
	get_parent().add_child(boom)
	boom.global_position = at + Vector3.UP * 0.2
	# Embers, sparks and bits of rind.
	for e in [[FLAME, 3.0], [Color(1.0, 0.8, 0.3), 3.0], [Color(0.6, 0.35, 0.15), 0.8]]:
		var bits := FX.burst(e[0], 14, 5.0, 0.09, 0.8, -9.8, e[1])
		add_child(bits)
		bits.position.y = 0.2
		bits.emitting = true
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player and not player.get("dead"):
		var off := player.global_position + Vector3.UP * 0.9 - at
		if off.length() < radius:
			var dir := Vector3(off.x, 0.0, off.z).normalized()
			player.take_damage(damage * (1.0 - 0.5 * off.length() / radius), at, dir)
			if player is CharacterBody3D:
				(player as CharacterBody3D).velocity += dir * 3.0 + Vector3.UP * 4.0
	get_tree().create_timer(1.2).timeout.connect(queue_free)
