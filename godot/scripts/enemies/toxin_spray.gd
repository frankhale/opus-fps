class_name ToxinSpray
extends Node3D
## A spider's spit: a hose-like stream of milky white toxin. For `duration` seconds it
## squirts droplets from the mouth (`mouth`, a Callable giving the point each frame)
## toward the target in a tight, wavering cone, lobbed so they arc onto it under
## gravity. Each droplet is raycast step by step, so it can't pass through walls; on
## hitting anything it splashes, and on hitting the player it hurts (gathered into a
## few hits per spray, so it doesn't stutter the pain sound) and wets the screen. A fine
## mist sprays out alongside the stream. Frees itself once the last droplet has landed.

## World and player bodies (physics layers 1 and 2).
const MASK := 1 | 2
const GRAVITY := 9.8
const DROP_COLOR := Color(0.93, 0.95, 0.97, 0.85)
const MAX_DROPS := 360

## Where the stream comes from; returns a world position.
var mouth: Callable
## What it's aimed at; returns a world position (re-read each frame, so it tracks).
var target: Callable
var duration := 0.6
var drops_per_second := 170.0
var speed := 15.0
## Cone half-angle in degrees.
var spread := 2.5
## Damage from every droplet that hits the player.
var damage_per_drop := 0.3
## Bodies the droplets pass through (the spider itself).
var exclude: Array[RID] = []

var _age := 0.0
var _emit_debt := 0.0
## Live droplets: {"p": position, "v": velocity}.
var _drops: Array[Dictionary] = []
var _pending_damage := 0.0
var _flush_timer := 0.0
var _hit_from := Vector3.ZERO
var _splash_cooldown := 0.0
var _mm: MultiMesh
var _mist: GPUParticles3D
var _wobble := Vector2.ZERO


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY
	var drop := BoxMesh.new()
	drop.size = Vector3(0.022, 0.022, 0.16)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = DROP_COLOR
	drop.material = mat
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.mesh = drop
	_mm.instance_count = MAX_DROPS
	_mm.visible_instance_count = 0
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = _mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mmi)
	_mist = _make_mist()
	add_child(_mist)


func _physics_process(delta: float) -> void:
	_age += delta
	_splash_cooldown -= delta
	var from: Vector3 = mouth.call() if mouth.is_valid() else global_position
	var aim := _launch_velocity(from, target.call() if target.is_valid() else from + Vector3.FORWARD)
	if _age < duration:
		# The stream wavers a little, like a hose in an unsteady grip.
		_wobble = Vector2(sin(_age * 23.0), cos(_age * 17.0)) * deg_to_rad(spread) * 0.6
		_emit_debt += drops_per_second * delta
		while _emit_debt >= 1.0 and _drops.size() < MAX_DROPS:
			_emit_debt -= 1.0
			_drops.append({"p": from, "v": _jitter(aim)})
		_mist.global_transform = Transform3D(Basis.looking_at(aim.normalized()), from)
		_mist.emitting = true
	else:
		_mist.emitting = false

	var space := get_world_3d().direct_space_state
	var alive: Array[Dictionary] = []
	for d in _drops:
		var p: Vector3 = d.p
		var v: Vector3 = d.v
		v.y -= GRAVITY * delta
		var next := p + v * delta
		var q := PhysicsRayQueryParameters3D.create(p, next, MASK, exclude)
		var hit := space.intersect_ray(q)
		if hit:
			_on_drop_hit(hit.collider, hit.position, hit.normal, v)
			continue
		if next.y < -50.0:
			continue
		d.p = next
		d.v = v
		alive.append(d)
	_drops = alive
	_draw_drops()

	_flush_timer -= delta
	if _pending_damage > 0.0 and _flush_timer <= 0.0:
		_flush_damage()
	if _age >= duration and _drops.is_empty():
		if _pending_damage > 0.0:
			_flush_damage()
		set_physics_process(false)
		get_tree().create_timer(_mist.lifetime + 0.1).timeout.connect(queue_free)


## A launch velocity at `speed` that lobs a droplet onto `to` (the flatter of the two
## arcs), or straight at it when it's out of reach.
func _launch_velocity(from: Vector3, to: Vector3) -> Vector3:
	var d := to - from
	var flat := Vector2(d.x, d.z)
	var x := flat.length()
	if x < 0.01:
		return d.normalized() * speed
	var v2 := speed * speed
	var disc := v2 * v2 - GRAVITY * (GRAVITY * x * x + 2.0 * d.y * v2)
	var angle := atan2(d.y, x) if disc < 0.0 else atan((v2 - sqrt(disc)) / (GRAVITY * x))
	var dir := flat / x
	return Vector3(dir.x * cos(angle), sin(angle), dir.y * cos(angle)) * speed


func _jitter(v: Vector3) -> Vector3:
	var basis := Basis.looking_at(v.normalized())
	var r := sqrt(randf()) * deg_to_rad(spread)
	var a := randf() * TAU
	var local := Vector3(sin(r) * cos(a) + _wobble.x, sin(r) * sin(a) + _wobble.y, -1.0).normalized()
	return basis * local * speed * randf_range(0.93, 1.05)


func _on_drop_hit(collider: Object, at: Vector3, normal: Vector3, v: Vector3) -> void:
	if collider and collider.is_in_group("player"):
		_pending_damage += damage_per_drop
		_hit_from = at - v.normalized()
		if _flush_timer <= 0.0:
			_flush_timer = 0.15
	if _splash_cooldown <= 0.0:
		_splash_cooldown = 0.04
		_splash(at, normal)


func _flush_damage() -> void:
	var player := get_tree().get_first_node_in_group("player")
	if player and not player.get("dead"):
		player.take_damage(_pending_damage, _hit_from, Vector3.ZERO)
		get_tree().call_group("hud", "splash", clampf(_pending_damage / 4.0, 0.35, 1.0))
	_pending_damage = 0.0
	_flush_timer = 0.15


## A little burst of white spatter bouncing off the surface.
func _splash(at: Vector3, normal: Vector3) -> void:
	var m := ParticleProcessMaterial.new()
	m.direction = normal
	m.spread = 60.0
	m.initial_velocity_min = 0.8
	m.initial_velocity_max = 2.2
	m.gravity = Vector3(0, -GRAVITY, 0)
	m.scale_min = 0.05
	m.scale_max = 0.1
	m.scale_curve = FX.curve([Vector2(0, 1), Vector2(1, 0.3)])
	m.color_ramp = FX.ramp([Color(1, 1, 1, 0.9), Color(0.9, 0.93, 0.95, 0.0)], [0.0, 1.0])
	var p := FX.emitter(7, 0.4, m, FX.quad(false), true)
	add_child(p)
	p.global_position = at + normal * 0.03
	p.emitting = true
	get_tree().create_timer(0.6).timeout.connect(p.queue_free)


## Fine spray around the stream, emitted at the mouth along the aim (-Z).
func _make_mist() -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3(0, 0, -1)
	m.spread = 7.0
	m.initial_velocity_min = speed * 0.45
	m.initial_velocity_max = speed * 0.8
	m.gravity = Vector3(0, -GRAVITY * 0.6, 0)
	m.damping_min = 4.0
	m.damping_max = 8.0
	m.scale_min = 0.1
	m.scale_max = 0.22
	m.scale_curve = FX.curve([Vector2(0, 0.4), Vector2(1, 1.8)])
	m.color_ramp = FX.ramp([Color(1, 1, 1, 0.0), Color(0.95, 0.97, 1.0, 0.6), Color(0.9, 0.93, 0.96, 0.0)],
		[0.0, 0.15, 1.0])
	var p := FX.emitter(90, 0.55, m, FX.quad(false), false)
	return p


func _draw_drops() -> void:
	_mm.visible_instance_count = _drops.size()
	for i in _drops.size():
		var d: Dictionary = _drops[i]
		var v: Vector3 = d.v
		var up := Vector3.UP if absf(v.normalized().y) < 0.99 else Vector3.RIGHT
		# Stretched along its travel, longer the faster it goes.
		var b := Basis.looking_at(v, up).scaled_local(Vector3(1, 1, clampf(v.length() / speed, 0.4, 1.2)))
		_mm.set_instance_transform(i, Transform3D(b, d.p))
