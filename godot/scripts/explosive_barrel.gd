class_name ExplosiveBarrel
extends PhysicsProp
## The red explosive barrel: a loose physics prop like the plain barrels (knocked about
## by shots, thrown by blasts) that also goes up like a gas can, only bigger. It takes
## the same hits to set off as a can (each weapon's gas_can_shots), and a blast nearby
## (rocket splash, a can, another barrel) sets it off a moment later, so one thrown
## into the air by a blast can burst in mid-flight. See GasCan for the blast itself.

@export var blast_radius := 5.5
## Damage at the center of the blast, falling off to zero at blast_radius.
@export var blast_damage := 80.0
## Impulse (N·s) given to other barrels at the center of the blast.
@export var blast_push := 300.0
## Size of the fireball, smoke and fire, times a gas can's.
@export var blast_size := 1.4
@export var burn_time := 10.0
@export var fade_time := 4.0

var _wear := 0.0
var _exploded := false


func _ready() -> void:
	super()
	add_to_group("explosives")
	body.set_meta("damage_target", self)  # shots hit the body; route them here


## A direct hit by a projectile from `weapon` (the shot also knocks the body about).
func take_shot(weapon: WeaponData, _at: Vector3) -> void:
	if _exploded:
		return
	_wear += 1.0 / maxi(weapon.gas_can_shots, 1)
	if _wear >= 0.999:
		explode()


## Caught in a blast: goes up a moment later, so chains ripple outward.
func ignite() -> void:
	if not _exploded:
		get_tree().create_timer(randf_range(0.1, 0.25)).timeout.connect(explode)


## The middle of the barrel, wherever it has rolled or flown to.
func blast_origin() -> Vector3:
	return body.global_transform * body.center_of_mass


func explode() -> void:
	if _exploded:
		return
	_exploded = true
	var center := blast_origin()
	GasCan.fuel_blast(get_parent(), center, blast_size, burn_time, fade_time)
	remove_from_group("physics_props")  # not thrown by its own blast
	GasCan.blast_at(get_tree(), center, blast_radius, blast_damage, blast_push)
	queue_free()
