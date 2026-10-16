class_name GunRecoil
extends RefCounted
## A held gun's recoil: each shot snaps it back toward the shoulder and up, tips the
## muzzle up and gives it a random twist and roll, so no two shots look the same. Damped
## springs pull it home with a little overshoot. The offsets are added to the gun's
## pose (position in meters, rotation in degrees, camera space; +Z is back toward the
## camera, +X rotation tips the muzzle up).

## Peak offsets for a recoil of 1 (the pistol).
const BACK := 0.075
const LIFT := 0.018
const PITCH := 13.0
const YAW := 3.0
const ROLL := 7.0
## Springs: position snaps back quickly, rotation settles a touch slower.
const POS_STIFFNESS := 260.0
const POS_DAMPING := 15.0
const ROT_STIFFNESS := 180.0
const ROT_DAMPING := 11.0
## How far rapid fire can stack it, in single kicks.
const MAX_STACK := 1.3

var position := Vector3.ZERO
var rotation := Vector3.ZERO
var _pos_v := Vector3.ZERO
var _rot_v := Vector3.ZERO


## One shot. `strength` is the weapon's recoil; big guns kick harder but tamer than
## linearly, so the heaviest still stay on screen. `side` is 1 for a gun in the right
## hand and -1 for the left, so the roll throws each outward.
func fire(strength: float, side := 1.0) -> void:
	var s := pow(strength, 0.7)
	# Velocities that peak at about the offsets above (impulse = peak * frequency, and
	# a bit more for what the damping takes off).
	var wp := sqrt(POS_STIFFNESS) * 2.6
	var wr := sqrt(ROT_STIFFNESS) * 2.8
	# Rapid fire stacks the kicks, but each one only has the room left before the cap,
	# so a long burst settles into a shudder instead of climbing off the screen.
	var cap := MAX_STACK * s
	var room_back := clampf(1.0 - position.z / (BACK * cap), 0.0, 1.0)
	var room_pitch := clampf(1.0 - rotation.x / (PITCH * cap), 0.0, 1.0)
	_pos_v += Vector3(randf_range(-0.15, 0.15) * BACK, LIFT * room_pitch, BACK * room_back) * wp * s
	_rot_v += Vector3(PITCH * randf_range(0.85, 1.15) * room_pitch, YAW * randf_range(-1.0, 1.0),
		ROLL * side * randf_range(0.3, 1.0)) * wr * s


func update(delta: float) -> void:
	_pos_v += (-POS_STIFFNESS * position - POS_DAMPING * _pos_v) * delta
	position += _pos_v * delta
	_rot_v += (-ROT_STIFFNESS * rotation - ROT_DAMPING * _rot_v) * delta
	rotation += _rot_v * delta
