@tool
class_name Campfire
extends Node3D
## Burning campfire effect, placed on top of the campfire model: licking flames,
## embers that float up and wink out, a column of smoke drifting off with the wind
## and a flickering firelight. Built from the same particle pieces as the weapon
## effects (FX). (@tool so the fire also burns in the editor.)

## Scales the whole fire; 1 suits the campfire model at its level scale (1.2).
@export var size := 1.0
@export var light_energy := 3.2
@export var light_range := 11.0
## Direction and strength the smoke drifts in, in m/s².
@export var wind := Vector3(0.25, 0.0, 0.1)

var _light: OmniLight3D
var _t := 0.0
## 1 while burning fully, falling to 0 as the fire dies down (see burn_out()).
var _strength := 1.0


func _ready() -> void:
	var s := size

	var flame := ParticleProcessMaterial.new()
	flame.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	flame.emission_sphere_radius = 0.18 * s
	flame.direction = Vector3.UP
	flame.spread = 12.0
	flame.initial_velocity_min = 0.8 * s
	flame.initial_velocity_max = 1.5 * s
	flame.gravity = Vector3(0, 1.2 * s, 0)  # hot air rises
	flame.damping_min = 0.5
	flame.damping_max = 1.0
	flame.scale_min = 0.35 * s
	flame.scale_max = 0.6 * s
	# Tongues start wide at the base and taper to a point as they rise.
	flame.scale_curve = FX.curve([Vector2(0, 0.7), Vector2(0.25, 1.0), Vector2(1, 0.1)])
	flame.color_ramp = FX.ramp([Color(1, 0.85, 0.45, 1), Color(1, 0.55, 0.12, 0.95), Color(0.9, 0.22, 0.04, 0.7),
		Color(0.5, 0.08, 0.02, 0)], [0.0, 0.3, 0.7, 1.0])
	flame.turbulence_enabled = true
	flame.turbulence_noise_strength = 0.6
	flame.turbulence_noise_scale = 1.5
	flame.turbulence_influence_min = 0.05
	flame.turbulence_influence_max = 0.12
	# Alpha-blended rather than additive so the flames stay solid against a bright
	# daytime background; energy above 1 lets the glow (bloom) pick them up.
	var flames := FX.emitter(36, 0.8, flame, FX.quad(false, 1.8), false)
	flames.position.y = 0.15 * s

	# A small additive core keeps the heart of the fire white-hot.
	var core_mat := flame.duplicate() as ParticleProcessMaterial
	core_mat.emission_sphere_radius = 0.1 * s
	core_mat.scale_min = 0.25 * s
	core_mat.scale_max = 0.4 * s
	core_mat.initial_velocity_max = 1.0 * s
	core_mat.color_ramp = FX.ramp([Color(1, 0.95, 0.7), Color(1, 0.7, 0.25), Color(1, 0.4, 0.1, 0)], [0.0, 0.4, 1.0])
	var core := FX.emitter(16, 0.45, core_mat, FX.quad(true, 2.0), false)
	core.position.y = 0.15 * s

	var ember := ParticleProcessMaterial.new()
	ember.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	ember.emission_sphere_radius = 0.2 * s
	ember.direction = Vector3.UP
	ember.spread = 25.0
	ember.initial_velocity_min = 1.0 * s
	ember.initial_velocity_max = 2.4 * s
	ember.gravity = Vector3(0, 0.4, 0)
	ember.damping_min = 0.6
	ember.damping_max = 1.2
	ember.scale_min = 0.035 * s
	ember.scale_max = 0.06 * s
	ember.color_ramp = FX.ramp([Color(1, 0.85, 0.4), Color(1, 0.45, 0.1), Color(0.6, 0.1, 0.02, 0)], [0.0, 0.5, 1.0])
	ember.turbulence_enabled = true
	ember.turbulence_noise_strength = 1.5
	ember.turbulence_noise_scale = 2.0
	ember.turbulence_influence_min = 0.1
	ember.turbulence_influence_max = 0.3
	var embers := FX.emitter(12, 1.8, ember, FX.quad(true, 3.0), false)
	embers.position.y = 0.25 * s

	var puff := ParticleProcessMaterial.new()
	puff.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	puff.emission_sphere_radius = 0.15 * s
	puff.direction = Vector3.UP
	puff.spread = 10.0
	puff.initial_velocity_min = 0.5 * s
	puff.initial_velocity_max = 0.9 * s
	puff.gravity = wind + Vector3(0, 0.35, 0)
	puff.damping_min = 0.1
	puff.damping_max = 0.3
	puff.angle_min = -180.0
	puff.angle_max = 180.0
	puff.angular_velocity_min = -20.0
	puff.angular_velocity_max = 20.0
	puff.scale_min = 0.45 * s
	puff.scale_max = 0.7 * s
	# Billows out as it climbs and thins away.
	puff.scale_curve = FX.curve([Vector2(0, 0.6), Vector2(1, 3.2)])
	puff.color_ramp = FX.ramp([Color(0.16, 0.15, 0.14, 0), Color(0.2, 0.19, 0.18, 0.75), Color(0.38, 0.38, 0.39, 0.45),
		Color(0.55, 0.55, 0.57, 0)], [0.0, 0.1, 0.55, 1.0])
	puff.turbulence_enabled = true
	puff.turbulence_noise_strength = 0.8
	puff.turbulence_noise_scale = 3.0
	puff.turbulence_influence_min = 0.03
	puff.turbulence_influence_max = 0.08
	var smoke := FX.emitter(24, 5.0, puff, FX.quad(false), false)
	smoke.position.y = 0.9 * s

	# Smoke first so the additive fire draws over it.
	for p: GPUParticles3D in [smoke, flames, core, embers]:
		p.preprocess = p.lifetime  # already burning when the level loads
		add_child(p)
		p.emitting = true

	_light = OmniLight3D.new()
	_light.light_color = Color(1.0, 0.5, 0.18)
	_light.omni_range = light_range
	_light.position.y = 0.7 * s
	add_child(_light)


func _process(delta: float) -> void:
	# Firelight flicker: a slow breath plus quick, uneven jitter.
	_t += delta
	var flicker := 0.12 * sin(_t * 2.1) + 0.08 * sin(_t * 7.3 + 1.1) + 0.06 * sin(_t * 13.7 + 2.3) + 0.04 * sin(_t * 23.0)
	_light.light_energy = light_energy * _strength * (1.0 + flicker)


## Lets the fire die down: after `delay` seconds the flames, embers and smoke thin out
## and the light dims over `fade` seconds, then the node frees itself once the last
## smoke has drifted off. (The gas can's spilled fuel uses this.)
func burn_out(delay: float, fade: float) -> void:
	var t := create_tween()
	t.tween_interval(delay)
	t.tween_method(_set_strength, 1.0, 0.0, fade)
	var linger := 0.0
	for p in get_children():
		if p is GPUParticles3D:
			linger = maxf(linger, p.lifetime)
	t.tween_interval(linger)
	t.tween_callback(queue_free)


func _set_strength(k: float) -> void:
	_strength = k
	for p in get_children():
		if p is GPUParticles3D:
			p.amount_ratio = k
