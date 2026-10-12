class_name WeaponData
extends Resource
## Static description of a weapon: its model and how it's held, how it fires, which
## ammo it uses and what its projectiles and explosions look like.

@export var display_name := "Weapon"
## Number key that selects it, and its order when cycling with the mouse wheel.
@export var slot := 1
@export var model: PackedScene

@export_group("Viewmodel")
## Where the model's grip sits relative to the camera (camera looks down -Z).
@export var view_position := Vector3(0.16, -0.16, -0.3)
@export var view_rotation_degrees := Vector3(0.0, 4.0, 0.0)
@export var view_scale := 1.0
## Muzzle position in the model's own space; projectiles and flashes start here.
@export var muzzle := Vector3(0.0, 0.05, -0.2)
## Scale of the floating model on its world pickup.
@export var pickup_scale := 1.5

@export_group("Hands")
## Right hand on the grip, in the model's own space (grip centre, hand's rotation).
@export var right_hand_position := Vector3(0.0, -0.04, 0.02)
@export var right_hand_rotation_degrees := Vector3(-20.0, 0.0, 0.0)
## "support" cradles a barrel, pump or handguard from below; "grip" closes around a
## vertical front grip, like the right hand.
@export_enum("support", "grip") var left_hand_style := "support"
@export var left_hand_position := Vector3(0.0, 0.03, -0.35)
@export var left_hand_rotation_degrees := Vector3.ZERO

@export_group("Firing")
## Hold to keep firing (otherwise one shot per click).
@export var automatic := false
@export var fire_interval := 0.3
@export var projectiles_per_shot := 1
@export var spread_degrees := 0.5
## Scales the viewmodel kick and camera recoil.
@export var recoil := 1.0
@export var fire_sound: AudioStream
## Reticle shape: lines with a gap ("cross"), a ring showing the spread ("circle"),
## or a small ring around a dot ("dot", for slow, precise weapons).
@export_enum("cross", "circle", "dot") var reticle := "cross"

@export_group("Ammo")
@export_enum("bullets", "shells", "rockets", "cells") var ammo_type := "bullets"
## Ammo granted when the weapon is picked up.
@export var ammo_on_pickup := 20

@export_group("Projectile")
@export var projectile_speed := 60.0
## Radius of the projectile core in meters. Trails, muzzle flash and impact
## explosion all scale from this, so a bigger gun means a bigger everything.
@export var projectile_size := 0.03
@export var projectile_color := Color(1.0, 0.75, 0.35)
## Brightness multiplier of the projectile; values above 1 bloom.
@export var glow_energy := 4.0
@export var projectile_gravity := 0.0
@export var smoke_trail := false
@export var explosion_color := Color(1.0, 0.6, 0.2)
## Damage per projectile on a direct hit.
@export var damage := 10.0
## Area damage around the impact (rockets), falling off to zero at the radius.
@export var splash_radius := 0.0
@export var splash_damage := 0.0
## Detonates when it passes this close to an enemy (0 = only on contact), so slow
## projectiles still catch fast, dodging targets.
@export var proximity_radius := 0.0

## Explosion size per meter of projectile radius.
const EXPLOSION_PER_SIZE := 20.0


## Size of the impact explosion, derived from the projectile so the two always match
## (1.0 is a large grenade-sized blast).
func explosion_size() -> float:
	return projectile_size * EXPLOSION_PER_SIZE


## Muzzle flash size in meters, also derived from the projectile (and the number of
## pellets, so a shotgun blast flashes bigger than a single pistol round).
func muzzle_flash_size() -> float:
	return clampf(projectile_size * 12.0 * sqrt(projectiles_per_shot), 0.25, 0.55)
