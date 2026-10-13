class_name PhysicsProp
extends Node3D
## Makes a scenery model (barrels) a loose physics object: on load its imported static
## collision is swapped for a RigidBody3D with a simple cylinder shape fitted to the
## model, which carries the mesh. Shots knock it about where they hit (see Projectile),
## and blasts (rocket splash, gas cans) throw it into the air via blast(). It starts
## frozen in place, so props standing on slopes don't roll off on their own and a level
## full of them costs nothing; the first hit sets it loose.

@export var mass := 15.0
## Fastest a blast can throw a prop, in m/s (about 6 m up at most).
const MAX_THROW_SPEED := 11.0

var body: RigidBody3D


func _ready() -> void:
	add_to_group("physics_props")
	body = RigidBody3D.new()
	body.name = "Body"
	body.mass = mass
	var surface := PhysicsMaterial.new()
	surface.friction = 0.8
	surface.bounce = 0.15
	body.physics_material_override = surface
	body.angular_damp = 0.5
	add_child(body)
	# The body is kept unscaled (physics bodies don't scale well); the model's scale goes
	# onto the mesh and into the shape's size instead.
	var s := scale
	body.top_level = true
	body.global_transform = Transform3D(global_basis.orthonormalized(), global_position)

	var box := AABB()
	for mi: MeshInstance3D in find_children("*", "MeshInstance3D", true, false):
		if mi.get_parent() == body:
			continue
		for col in mi.find_children("*", "CollisionObject3D", true, false):
			col.queue_free()  # the imported static trimesh
		var xf := mi.transform
		mi.get_parent().remove_child(mi)
		body.add_child(mi)
		mi.transform = Transform3D(Basis.from_scale(s), Vector3.ZERO) * xf
		var b := mi.transform * mi.get_aabb()
		box = b if box.size == Vector3.ZERO else box.merge(b)

	var cyl := CylinderShape3D.new()
	cyl.radius = maxf(box.size.x, box.size.z) / 2.0
	cyl.height = box.size.y
	var shape := CollisionShape3D.new()
	shape.shape = cyl
	shape.position = box.get_center()
	body.add_child(shape)
	body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	body.center_of_mass = box.get_center()
	body.freeze = true


## Throws every prop within `radius` of `at` up and away, harder the closer it is.
## `strength` is the impulse (N·s) at the center of the blast.
static func blast(tree: SceneTree, at: Vector3, radius: float, strength: float) -> void:
	for prop: PhysicsProp in tree.get_nodes_in_group("physics_props"):
		var b := prop.body
		var center := b.global_transform * b.center_of_mass
		var away := center - at
		var falloff := 1.0 - away.length() / radius
		if falloff <= 0.0:
			continue
		var dir := (Vector3(away.x, 0.0, away.z).normalized() + Vector3.UP * 1.4).normalized()
		b.freeze = false
		# Capped, so several blasts at once (a rocket setting off gas cans) don't fire it
		# out of sight; spun at random so it tumbles as it flies.
		b.linear_velocity = (b.linear_velocity + dir * strength * falloff / b.mass).limit_length(MAX_THROW_SPEED)
		b.angular_velocity += Vector3(randf_range(-1, 1), randf_range(-1, 1), randf_range(-1, 1)) * 6.0 * falloff
