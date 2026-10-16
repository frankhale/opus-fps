extends Node3D
## Puffs of dust kicked up at the player's feet on jumping off the ground and on
## landing, a ring spreading low along the ground, bigger for harder landings.

@onready var player: CharacterBody3D = get_parent()


func _ready() -> void:
	player.jumped.connect(func():
		if player.is_on_floor():
			_puff(0.6))
	player.landed.connect(func(impact: float):
		if impact > 3.0:
			_puff(clampf(impact / 9.0, 0.5, 1.5)))
	player.vaulted.connect(func(_h: float): _puff(0.4))


func _puff(size: float) -> void:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_RING
	m.emission_ring_axis = Vector3.UP
	m.emission_ring_radius = 0.3
	m.emission_ring_inner_radius = 0.15
	m.emission_ring_height = 0.05
	# Out along the ground, barely lifting, and quickly slowed by the air.
	m.direction = Vector3.UP
	m.spread = 85.0
	m.flatness = 0.0
	m.radial_velocity_min = 1.2 * size
	m.radial_velocity_max = 2.4 * size
	m.initial_velocity_min = 0.2
	m.initial_velocity_max = 0.6 * size
	m.gravity = Vector3(0, 0.25, 0)
	m.damping_min = 3.0
	m.damping_max = 5.0
	m.angle_min = -180.0
	m.angle_max = 180.0
	m.scale_min = 0.25 * size
	m.scale_max = 0.45 * size
	m.scale_curve = FX.curve([Vector2(0, 0.5), Vector2(1, 1.6)])
	m.color_ramp = FX.ramp([Color(0.55, 0.5, 0.42, 0.0), Color(0.55, 0.5, 0.42, 0.55), Color(0.5, 0.47, 0.42, 0.0)],
		[0.0, 0.12, 1.0])
	var dust := FX.emitter(roundi(14 * size) + 4, 0.7, m, FX.quad(false), true)
	get_tree().current_scene.add_child(dust)
	dust.global_position = player.global_position + Vector3(0, 0.05, 0)
	dust.emitting = true
	get_tree().create_timer(dust.lifetime + 0.2).timeout.connect(dust.queue_free)
