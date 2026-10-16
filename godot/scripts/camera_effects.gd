extends Camera3D
## Procedural camera feel for the player. Purely visual: it only offsets this camera
## relative to its parent Head node (which owns mouse pitch), so it never affects
## aiming or movement.
##  * head bob with lateral sway and a "foot plant" dip, scaled by speed
##  * leaning into strafes and slides
##  * FOV kick when sprinting and sliding, and a wide stretch on going through a portal
##  * jumps: a dip and FOV pop on take-off, the view tipping up while rising and
##    down while falling, a pull-up on vaulting a ledge
##  * spring-damped landing dip and pitch kick, shake on hard landings
##  * subtle breathing when standing still
## Emits `footstep` on every foot plant so audio stays in sync with the bob.

signal footstep(intensity: float)

@export_group("FOV")
@export var base_fov := 74.0
@export var sprint_fov := 82.0
@export var slide_fov := 88.0
@export var fov_speed := 7.0
## Extra FOV the view snaps to after going through a portal, easing back.
@export var teleport_fov := 30.0
## Extra FOV popped on jumping, easing back.
@export var jump_fov := 4.0

@export_group("Bob")
## Height of the dip at each foot plant, in meters (at walk speed).
@export var bob_vertical := 0.045
## Side-to-side sway, in meters (at walk speed).
@export var bob_horizontal := 0.03
## Radians of bob phase per meter travelled; one step every pi radians.
@export var bob_rate := 2.0
@export var sprint_bob_scale := 1.35

@export_group("Lean")
## Roll in degrees when strafing at walk speed.
@export var strafe_roll := 1.8
@export var slide_roll := 4.0
@export var lean_speed := 8.0

@export_group("Landing")
## Downward camera velocity added per m/s of fall speed.
@export var land_kick := 0.32
## Degrees of downward pitch kick per m/s of fall speed.
@export var land_pitch := 0.55
@export var spring_stiffness := 170.0
@export var spring_damping := 17.0
## Fall speeds above this (m/s) also shake the camera.
@export var shake_threshold := 8.0

@export_group("Air")
## Degrees of pitch per m/s of vertical speed while airborne (up rising, down falling).
@export var air_pitch := 0.35
@export var air_pitch_limit := 3.0

@onready var player: CharacterBody3D = get_parent().get_parent()

## Bob state, read by the weapon viewmodel so it moves in step with the camera.
var bob_phase := 0.0
var bob_amount := 0.0
var _roll := 0.0
var _offset_y := 0.0
var _offset_v := 0.0
var _pitch := 0.0
var _pitch_v := 0.0
var _air_pitch := 0.0
var _trauma := 0.0
var _time := 0.0


func _ready() -> void:
	fov = base_fov
	player.landed.connect(_on_landed)
	player.jumped.connect(_on_jumped)
	player.vaulted.connect(_on_vaulted)
	player.teleported.connect(func(): fov = base_fov + teleport_fov)


func _on_landed(impact: float) -> void:
	if impact < 1.5:
		return
	_offset_v -= impact * land_kick
	_pitch_v -= impact * land_pitch * 10.0
	_trauma = minf(_trauma + maxf(impact - shake_threshold, 0.0) * 0.08, 1.0)
	footstep.emit(clampf(impact / 6.0, 0.5, 1.0))


## Camera shake, 0..1 (squared internally, so small values stay subtle).
func add_trauma(amount: float) -> void:
	_trauma = minf(_trauma + amount, 1.0)


## Visual recoil: pitches the view up briefly, then springs back.
func kick(degrees: float) -> void:
	_pitch_v += degrees * 14.0


func _on_jumped() -> void:
	_offset_v -= 0.9
	_pitch_v += 26.0
	fov += jump_fov


## Hauling yourself up: the view dips and pitches down toward the ledge, then rights.
func _on_vaulted(height: float) -> void:
	_offset_v -= 0.6 + height * 0.8
	_pitch_v -= 40.0 + height * 30.0
	footstep.emit(0.6)


func _process(delta: float) -> void:
	_time += delta
	var speed: float = player.horizontal_speed()
	var grounded: bool = player.is_on_floor()
	var walk: float = player.walk_speed

	# --- Bob: advance by distance travelled so stride length is constant. ---
	var bobbing: bool = grounded and not player.is_sliding and speed > 0.3
	var target_amount := clampf(speed / walk, 0.0, 1.0) if bobbing else 0.0
	if player.is_sprinting and bobbing:
		target_amount *= sprint_bob_scale
	bob_amount = lerpf(bob_amount, target_amount, 1.0 - exp(-10.0 * delta))
	if bobbing:
		var step_before := floori(bob_phase / PI)
		bob_phase += speed * bob_rate * delta
		if floori(bob_phase / PI) != step_before:
			footstep.emit(clampf(speed / player.sprint_speed, 0.35, 1.0) * (0.6 if player.is_crouching else 1.0))
	var bob_y := -absf(sin(bob_phase)) * bob_vertical * bob_amount
	var bob_x := cos(bob_phase) * bob_horizontal * bob_amount
	var breathe := sin(_time * 1.7) * 0.006 * (1.0 - clampf(bob_amount, 0.0, 1.0))

	# --- Lean: roll into strafes, and a steady lean while sliding. ---
	var lateral := player.global_transform.basis.x.dot(player.velocity)
	var target_roll := -lateral / walk * strafe_roll
	if player.is_sliding:
		target_roll -= slide_roll
	target_roll += cos(bob_phase) * 0.35 * bob_amount
	_roll = lerpf(_roll, target_roll, 1.0 - exp(-lean_speed * delta))

	# --- Springs: landing dip and pitch kick settle back to rest. ---
	_offset_v += (-spring_stiffness * _offset_y - spring_damping * _offset_v) * delta
	_offset_y += _offset_v * delta
	_pitch_v += (-spring_stiffness * _pitch - spring_damping * _pitch_v) * delta
	_pitch += _pitch_v * delta

	# --- Shake: trauma squared, decaying. ---
	_trauma = maxf(_trauma - delta * 1.6, 0.0)
	var shake := _trauma * _trauma
	var shake_rot := Vector3(sin(_time * 47.0), sin(_time * 39.0 + 1.3), sin(_time * 53.0 + 2.1)) * shake * 0.04
	var shake_pos := Vector3(sin(_time * 41.0 + 0.7), sin(_time * 57.0), 0.0) * shake * 0.05

	# --- Air: tip with vertical speed, settling back on the ground. ---
	var air_target := 0.0
	if not grounded and not player.is_climbing:
		air_target = clampf(player.velocity.y * air_pitch, -air_pitch_limit, air_pitch_limit)
	_air_pitch = lerpf(_air_pitch, air_target, 1.0 - exp(-6.0 * delta))

	position = Vector3(bob_x, bob_y + _offset_y + breathe, 0.0) + shake_pos
	rotation = Vector3(deg_to_rad(_pitch + _air_pitch), 0.0, deg_to_rad(_roll)) + shake_rot

	# --- FOV kick. ---
	var target_fov := base_fov
	if player.is_sliding:
		target_fov = slide_fov
	elif player.is_sprinting and speed > walk + 0.5:
		target_fov = sprint_fov
	fov = lerpf(fov, target_fov, 1.0 - exp(-fov_speed * delta))
