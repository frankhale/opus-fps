class_name Explosion
extends Node3D
## Impact explosion whose every part scales with `size` (pellet pop at ~0.2, rocket
## blast at ~2.4): a glowing fireball, rising smoke, sparks, a light flash, a 3D sound
## and camera shake for a player who is close enough. Frees itself when done.

const SMALL_SOUND := preload("res://assets/sfx/explosion_small.wav")
const LARGE_SOUND := preload("res://assets/sfx/explosion_large.wav")

var size := 1.0
var color := Color(1.0, 0.6, 0.2)


func _ready() -> void:
	var s := size

	var light := OmniLight3D.new()
	light.light_color = color
	# Kept modest and scaled with size: a strong light saturates the ground under the
	# blast to white, which then dominates how big the explosion looks.
	light.omni_range = 1.0 + 4.0 * s
	light.light_energy = 0.4 + 0.9 * s
	add_child(light)
	create_tween().tween_property(light, "light_energy", 0.0, 0.15 + 0.2 * s)

	var fire := ParticleProcessMaterial.new()
	fire.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	fire.emission_sphere_radius = 0.15 * s
	fire.direction = Vector3.UP
	fire.spread = 180.0
	# Speed grows slower than size, so big blasts stay a dense fireball rather than
	# flinging fire across the whole screen.
	fire.initial_velocity_min = 0.8 * sqrt(s)
	fire.initial_velocity_max = 3.5 * sqrt(s)
	fire.damping_min = 2.0
	fire.damping_max = 3.5
	fire.gravity = Vector3(0, 1.5 * s, 0)
	fire.scale_min = 0.35 * s
	fire.scale_max = 0.8 * s
	fire.scale_curve = FX.curve([Vector2(0, 0.5), Vector2(0.2, 1.0), Vector2(1, 0)])
	# Saturated ramp and modest HDR energy: overlapping additive puffs stay yellow,
	# orange and red instead of summing to white.
	fire.color_ramp = FX.ramp([Color(1, 0.88, 0.55), Color(1, 0.65, 0.2), color, Color(0.45, 0.08, 0.03, 0)],
		[0.0, 0.12, 0.4, 1.0])
	var fireball := FX.emitter(int(10 + 20 * s), 0.35 + 0.3 * s, fire, FX.quad(true, 1.15), true)

	var smoke_mat := ParticleProcessMaterial.new()
	smoke_mat.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	smoke_mat.emission_sphere_radius = 0.2 * s
	smoke_mat.direction = Vector3.UP
	smoke_mat.spread = 60.0
	smoke_mat.initial_velocity_min = 0.5 * sqrt(s)
	smoke_mat.initial_velocity_max = 1.6 * sqrt(s)
	smoke_mat.damping_min = 1.0
	smoke_mat.damping_max = 2.0
	smoke_mat.gravity = Vector3(0, 0.8, 0)
	smoke_mat.scale_min = 0.45 * s
	smoke_mat.scale_max = 0.85 * s
	smoke_mat.scale_curve = FX.curve([Vector2(0, 0.5), Vector2(1, 1.5)])
	smoke_mat.color_ramp = FX.ramp([Color(0.2, 0.18, 0.16, 0), Color(0.2, 0.18, 0.16, 0.45), Color(0.38, 0.38, 0.38, 0)],
		[0.0, 0.15, 1.0])
	var smoke := FX.emitter(int(4 + 4 * s), 0.9 + 0.45 * s, smoke_mat, FX.quad(false), true)

	var sparks := FX.burst(color, int(8 + 22 * s), 4.0 + 5.0 * sqrt(s), 0.05 + 0.04 * s, 0.35 + 0.3 * s)

	for p in [smoke, fireball, sparks]:
		add_child(p)
		p.emitting = true

	var sound := AudioStreamPlayer3D.new()
	sound.stream = LARGE_SOUND if s >= 1.0 else SMALL_SOUND
	sound.unit_size = 3.0 + 6.0 * s
	sound.volume_db = lerpf(-14.0, 2.0, clampf(s / 2.4, 0.0, 1.0))
	sound.pitch_scale = clampf(1.5 - 0.3 * s, 0.8, 1.5) * randf_range(0.93, 1.07)
	add_child(sound)
	sound.play()

	var cam := get_viewport().get_camera_3d()
	if cam and cam.has_method("add_trauma"):
		var reach := 3.0 + 7.0 * s
		var falloff := 1.0 - cam.global_position.distance_to(global_position) / reach
		if falloff > 0.0:
			cam.add_trauma(clampf(0.35 * s * falloff, 0.0, 0.9))

	get_tree().create_timer(2.0 + 1.5 * s).timeout.connect(queue_free)
