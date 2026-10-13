class_name Projectile
extends Node3D
## A glowing projectile: an emissive core with a particle trail (plus smoke for
## rockets). It moves by raycasting from its last position to the next each physics
## step, so even fast shots can't tunnel through thin geometry. On impact it spawns
## an Explosion sized by the weapon, stops its trails and frees itself once they fade.

const MAX_LIFETIME := 4.0
## The core and trails appear once the projectile is this far out (the muzzle flash
## covers the gap). Seen end-on from the shooter's eye, anything glowing right in
## front of the gun blooms into a blob at the center of the screen.
const TRAIL_START_DISTANCE := 2.0

## Physics layers (see WeaponManager): 1 world, 2 player, 4 enemies.
const LAYER_ENEMIES := 4
## Push given to a loose physics object (barrels) on a direct hit, in N·s per point of
## damage, and the extra upward share that makes it hop.
const KNOCK_PER_DAMAGE := 1.2
const KNOCK_LIFT := 0.3
## Impulse at the center of a splash (rockets) per point of splash damage, for
## throwing physics props (see PhysicsProp.blast()).
const BLAST_PER_DAMAGE := 1.5

var data: WeaponData
var velocity := Vector3.ZERO
## Bodies the projectile ignores (the shooter).
var exclude: Array[RID] = []
## What it can hit: world + enemies for the player's shots, world + player for enemies'.
var collision_mask := 1 | LAYER_ENEMIES
## Called with (killed: bool) whenever this projectile damages something (hit markers).
var on_hit: Callable

var _core: MeshInstance3D
var _trails: Array[GPUParticles3D] = []
var _age := 0.0
var _travelled := 0.0
var _done := false


func _ready() -> void:
	var glow := data.projectile_color * data.glow_energy
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(glow.r, glow.g, glow.b, 1.0)
	var sphere := SphereMesh.new()
	sphere.radius = data.projectile_size
	sphere.height = data.projectile_size * 2.0
	sphere.radial_segments = 6
	sphere.rings = 3
	_core = MeshInstance3D.new()
	_core.mesh = sphere
	_core.material_override = mat
	_core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_core.visible = false
	add_child(_core)

	var c := data.projectile_color
	var trail := ParticleProcessMaterial.new()
	trail.gravity = Vector3.ZERO
	trail.spread = 180.0
	trail.initial_velocity_max = 0.3
	trail.scale_min = data.projectile_size * 1.6
	trail.scale_max = data.projectile_size * 2.2
	trail.scale_curve = FX.curve([Vector2(0, 1), Vector2(1, 0)])
	trail.color_ramp = FX.ramp([Color(1, 1, 0.9, 0.9), Color(c.r, c.g, c.b, 0.7), Color(c.r, c.g, c.b, 0)], [0.0, 0.3, 1.0])
	var life := 0.18 + data.projectile_size * 1.5
	# Alpha-blended (not additive) with an HDR color: when the trail is seen end-on,
	# overlapping particles settle at the trail color instead of summing to white,
	# but stay bright enough to bloom.
	_add_trail(FX.emitter(int(40 * life / 0.2), life, trail, FX.quad(false, 1.6), false))

	if data.smoke_trail:
		var smoke := ParticleProcessMaterial.new()
		smoke.gravity = Vector3(0, 0.6, 0)
		smoke.spread = 180.0
		smoke.initial_velocity_max = 0.4
		smoke.damping_min = 0.5
		smoke.damping_max = 1.0
		smoke.scale_min = 0.25
		smoke.scale_max = 0.45
		smoke.scale_curve = FX.curve([Vector2(0, 0.4), Vector2(1, 1.6)])
		smoke.color_ramp = FX.ramp([Color(0.75, 0.72, 0.7, 0.55), Color(0.5, 0.5, 0.5, 0.3), Color(0.4, 0.4, 0.4, 0)],
			[0.0, 0.5, 1.0])
		_add_trail(FX.emitter(60, 1.0, smoke, FX.quad(false), false))


func _add_trail(p: GPUParticles3D) -> void:
	add_child(p)
	_trails.append(p)


func _physics_process(delta: float) -> void:
	if _done:
		return
	velocity.y -= data.projectile_gravity * delta
	var from := global_position
	var to := from + velocity * delta
	var query := PhysicsRayQueryParameters3D.create(from, to, collision_mask, exclude)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit:
		var target := damage_target(hit.collider)
		if target and target.has_method("take_shot"):
			target.take_shot(data, hit.position)  # props that count hits (gas cans)
		elif target:
			target.take_damage(data.damage, hit.position, velocity.normalized())
			_report_hit(target)
		var loose := hit.collider as RigidBody3D
		if loose:
			# Pushed where it was hit, so off-center shots tip and spin it.
			loose.freeze = false  # props stand frozen until first hit (see PhysicsProp)
			loose.apply_impulse((velocity.normalized() + Vector3.UP * KNOCK_LIFT) * data.damage * KNOCK_PER_DAMAGE,
				hit.position - loose.global_position)
		explode(hit.position, hit.normal)
		return
	if data.proximity_radius > 0.0 and _enemy_near(to):
		explode(to, -velocity.normalized())
		return
	global_position = to
	_travelled += velocity.length() * delta
	if _travelled >= TRAIL_START_DISTANCE and not _core.visible:
		_core.visible = true
		for t in _trails:
			t.emitting = true
	_age += delta
	if _age > MAX_LIFETIME:
		_finish()


func explode(at: Vector3, normal := Vector3.UP) -> void:
	var e := Explosion.new()
	e.size = data.explosion_size()
	e.color = data.explosion_color
	get_parent().add_child(e)
	e.global_position = at + normal * 0.05
	global_position = at
	if data.splash_radius > 0.0:
		_splash(at)
	_finish()


## Proximity fuse: any enemy within the fuse radius of this point.
func _enemy_near(at: Vector3) -> bool:
	var sphere := SphereShape3D.new()
	sphere.radius = data.proximity_radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis.IDENTITY, at)
	q.collision_mask = collision_mask & LAYER_ENEMIES
	q.exclude = exclude
	return not get_world_3d().direct_space_state.intersect_shape(q, 1).is_empty()


## Area damage to enemies near the impact, falling off linearly with distance. Gas
## cans in range go up too, and barrels are thrown.
func _splash(at: Vector3) -> void:
	var sphere := SphereShape3D.new()
	sphere.radius = data.splash_radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis.IDENTITY, at)
	q.collision_mask = LAYER_ENEMIES
	q.exclude = exclude
	for r in get_world_3d().direct_space_state.intersect_shape(q, 16):
		var body: Object = r.collider
		if body and body.has_method("take_damage"):
			var d: float = (body as Node3D).global_position.distance_to(at)
			var amount := data.splash_damage * clampf(1.0 - d / data.splash_radius, 0.0, 1.0)
			if amount > 1.0:
				body.take_damage(amount, at, ((body as Node3D).global_position - at).normalized())
				_report_hit(body)
	GasCan.ignite_near(get_tree(), at, data.splash_radius)
	PhysicsProp.blast(get_tree(), at, data.splash_radius, data.splash_damage * BLAST_PER_DAMAGE)


## What takes damage when `collider` is hit: the collider itself, or the node it hands
## damage on to (a model's imported collision body passes it to the model's script).
static func damage_target(collider: Object) -> Object:
	if collider == null:
		return null
	if collider.has_meta("damage_target"):
		return collider.get_meta("damage_target")
	return collider if collider.has_method("take_damage") else null


func _report_hit(target: Object) -> void:
	if on_hit.is_valid():
		on_hit.call(target.get("dead") == true)


## Hide the core and let the trails fade out before freeing.
func _finish() -> void:
	_done = true
	_core.visible = false
	var linger := 0.0
	for t in _trails:
		t.emitting = false
		linger = maxf(linger, t.lifetime)
	get_tree().create_timer(linger + 0.1).timeout.connect(queue_free)
