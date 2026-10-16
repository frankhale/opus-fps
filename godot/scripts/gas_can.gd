class_name GasCan
extends Node3D
## Explosive gas can, set on the gas_can model's root. Each weapon's gas_can_shots says
## how many direct hits it takes to set one off (three pistol rounds, one of anything
## else); a blast (rocket splash, another can) sets it off outright, so cans chain. It
## goes up in a fuel blast: the weapon Explosion plus a rolling fireball, red shrapnel,
## a black smoke column and spilled fuel that burns for burn_time seconds, dying down
## over the last fade_time of them. The blast hurts the player and enemies nearby.
## The blast itself (fuel_blast, blast_at) is shared with ExplosiveBarrel, and both are
## in the "explosives" group, so cans and barrels set each other off.

@export var blast_radius := 4.0
## Damage at the center of the blast, falling off to zero at blast_radius.
@export var blast_damage := 60.0
## Impulse (N·s) given to barrels at the center of the blast (see PhysicsProp).
@export var blast_push := 220.0
## Seconds the spilled fuel burns, from the blast until the flames are out.
@export var burn_time := 10.0
## The fire and its smoke die down over the last this-many seconds of burn_time.
@export var fade_time := 4.0

var _wear := 0.0
var _exploded := false


func _ready() -> void:
	add_to_group("explosives")
	# Shots find the imported collision body; route them to this script.
	for body in find_children("*", "CollisionObject3D", true, false):
		body.set_meta("damage_target", self)


## A direct hit by a projectile from `weapon`.
func take_shot(weapon: WeaponData, _at: Vector3) -> void:
	if _exploded:
		return
	_wear += 1.0 / maxi(weapon.gas_can_shots, 1)
	if _wear >= 0.999:
		explode()
	else:
		var t := create_tween()  # knocked about a little
		t.tween_property(self, "rotation:z", randf_range(-0.12, 0.12), 0.05)
		t.tween_property(self, "rotation:z", 0.0, 0.2)


## Caught in a blast: the fuel goes up a moment later, so chains ripple outward.
func ignite() -> void:
	if not _exploded:
		get_tree().create_timer(randf_range(0.1, 0.25)).timeout.connect(explode)


## Where the blast goes off from (explosives group; see ignite_near).
func blast_origin() -> Vector3:
	return global_position


## Sets off every gas can and explosive barrel within `radius` of `at`. They are found
## by distance rather than a physics query: mesh colliders report one result per triangle.
static func ignite_near(tree: SceneTree, at: Vector3, radius: float) -> void:
	for n in tree.get_nodes_in_group("explosives"):
		if n.blast_origin().distance_to(at) < radius:
			n.ignite()


func explode() -> void:
	if _exploded:
		return
	_exploded = true
	var center := global_position + Vector3(0, 0.3, 0)
	fuel_blast(get_parent(), center, 1.0, burn_time, fade_time)
	blast_at(get_tree(), center, blast_radius, blast_damage, blast_push)
	queue_free()


## The look of a fuel blast at `center`, `size` times a gas can's: the weapon Explosion,
## a rolling fireball, shrapnel in `shrapnel_color`, and burning fuel spilled on the
## ground below (if it is near), with a black smoke column, for `burn` seconds.
static func fuel_blast(parent: Node3D, center: Vector3, size: float, burn: float, fade: float,
		shrapnel_color := Color(0.6, 0.06, 0.04)) -> void:
	var blast := Explosion.new()
	blast.size = 1.8 * size
	blast.color = Color(1.0, 0.45, 0.1)
	parent.add_child(blast)
	blast.global_position = center

	# The spilled fuel lands on whatever is below; one blown up in the air leaves none.
	var down := PhysicsRayQueryParameters3D.create(center, center + Vector3.DOWN * 2.5, 1)
	var ground := parent.get_world_3d().direct_space_state.intersect_ray(down)

	var fx := Node3D.new()  # the particles, freed once they have all faded
	parent.add_child(fx)
	fx.global_position = center
	var smoke := _smoke_column(size)
	var parts: Array = [_fireball(size), _shrapnel(size, shrapnel_color)]
	if ground:
		parts.append(smoke)
	for p in parts:
		fx.add_child(p)
		p.emitting = true
	# Tweens and callbacks belong to the effects, not the can or barrel, which is freed
	# right away (a lambda of a freed object never runs).
	var t := fx.create_tween()
	if ground:
		t.tween_interval(burn - fade)
		t.tween_property(smoke, "amount_ratio", 0.0, fade)
		t.tween_interval(smoke.lifetime)  # the last puffs drift off
	else:
		t.tween_interval(2.0)
	t.tween_callback(fx.queue_free)
	if not ground:
		return

	var fire := Campfire.new()  # the spilled fuel
	fire.size = 0.9 * size
	fire.light_energy = 2.4 * size
	fire.light_range = 8.0 * size
	parent.add_child(fire)
	fire.global_position = ground.position
	fire.burn_out(burn - fade, fade)


## The blast's force at `at`: hurts the player and enemies within `radius` (`damage` at
## the center, less the farther away), sets off other explosives and throws barrels.
static func blast_at(tree: SceneTree, at: Vector3, radius: float, damage: float, push: float) -> void:
	var sphere := SphereShape3D.new()
	sphere.radius = radius
	var q := PhysicsShapeQueryParameters3D.new()
	q.shape = sphere
	q.transform = Transform3D(Basis.IDENTITY, at)
	q.collision_mask = 2 | Projectile.LAYER_ENEMIES
	for r in tree.root.get_world_3d().direct_space_state.intersect_shape(q, 16):
		var body: Object = r.collider
		if body and body.has_method("take_damage"):
			var pos: Vector3 = (body as Node3D).global_position
			var amount := damage * clampf(1.0 - pos.distance_to(at) / radius, 0.0, 1.0)
			if amount > 1.0:
				body.take_damage(amount, at, (pos - at).normalized())
	ignite_near(tree, at, radius)
	PhysicsProp.blast(tree, at, radius * 1.25, push)


## A rolling ball of burning fuel, bigger and slower than the weapon blast's.
static func _fireball(size: float) -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.4 * size
	m.direction = Vector3.UP
	m.spread = 50.0
	m.initial_velocity_min = 1.5 * size
	m.initial_velocity_max = 4.0 * size
	m.damping_min = 2.0
	m.damping_max = 3.0
	m.gravity = Vector3(0, 3.0, 0)
	m.scale_min = 0.9 * size
	m.scale_max = 1.6 * size
	m.scale_curve = FX.curve([Vector2(0, 0.4), Vector2(0.25, 1.0), Vector2(1, 0.2)])
	m.color_ramp = FX.ramp([Color(1, 0.7, 0.3), Color(1, 0.42, 0.08), Color(0.7, 0.14, 0.03, 0.85),
		Color(0.15, 0.05, 0.03, 0)], [0.0, 0.2, 0.55, 1.0])
	return FX.emitter(roundi(40 * size), 1.1, m, FX.quad(false, 1.15), true)


## Painted shards flung out and falling back, glowing hot at first.
static func _shrapnel(size: float, color: Color) -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3.UP
	m.spread = 75.0
	m.initial_velocity_min = 4.0 * sqrt(size)
	m.initial_velocity_max = 9.0 * sqrt(size)
	m.gravity = Vector3(0, -9.8, 0)
	m.angle_min = -180.0
	m.angle_max = 180.0
	m.angular_velocity_min = -720.0
	m.angular_velocity_max = 720.0
	m.particle_flag_rotate_y = true
	m.scale_min = 0.6
	m.scale_max = 1.4
	m.scale_curve = FX.curve([Vector2(0, 1), Vector2(0.8, 1), Vector2(1, 0)])
	m.color_ramp = FX.ramp([Color(1, 0.6, 0.2), color, color.darkened(0.6)], [0.0, 0.25, 1.0])
	var shard := BoxMesh.new()
	shard.size = Vector3(0.09, 0.015, 0.06) * sqrt(size)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.7
	shard.material = mat
	return FX.emitter(roundi(24 * size), 1.4, m, shard, true)


## Thick black fuel smoke rising off the fire; it stops when the fire goes out.
static func _smoke_column(size: float) -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.3 * size
	m.direction = Vector3.UP
	m.spread = 15.0
	m.initial_velocity_min = 1.0
	m.initial_velocity_max = 2.0
	m.gravity = Vector3(0.25, 0.5, 0.1)
	m.damping_min = 0.2
	m.damping_max = 0.4
	m.angle_min = -180.0
	m.angle_max = 180.0
	m.angular_velocity_min = -20.0
	m.angular_velocity_max = 20.0
	m.scale_min = 1.0 * size
	m.scale_max = 1.5 * size
	m.scale_curve = FX.curve([Vector2(0, 0.6), Vector2(1, 3.0)])
	m.color_ramp = FX.ramp([Color(0.06, 0.05, 0.05, 0), Color(0.07, 0.06, 0.05, 0.9), Color(0.18, 0.17, 0.17, 0.55),
		Color(0.35, 0.35, 0.36, 0)], [0.0, 0.1, 0.6, 1.0])
	return FX.emitter(40, 4.5, m, FX.quad(false), false)
