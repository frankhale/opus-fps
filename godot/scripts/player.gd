extends CharacterBody3D
## First-person movement with AAA-style feel:
##  * snappy ground acceleration and braking, momentum-preserving air control
##  * sprint, crouch and sprint-slide
##  * jump with coyote time, input buffering, variable height and snappier falls
##  * automatic step-up over low ledges
##  * climbing ladders (Ladder areas)
##  * health: damage, healing, death and respawning at the start point
##  * a count of the gems collected (god_mode: no damage, all weapons, unlimited ammo)
##  * powerups: invulnerability turns all damage away for a while (see ShieldVeil)
## Camera feel lives in camera_effects.gd and sounds in player_audio.gd; both react
## to this script's signals and public state.

signal jumped
signal landed(impact_speed: float)
signal slide_started
signal slide_ended
signal health_changed(health: float, max_health: float)
signal damaged(amount: float, from: Vector3)
signal died
signal respawned
signal message(text: String)
signal teleported
signal gems_changed(count: int)
## A powerup was picked up (or topped up) and now lasts `duration` seconds.
signal powerup_started(powerup: String, duration: float)
signal powerup_ended(powerup: String)
## Damage the invulnerability shield turned away.
signal shield_hit(amount: float, from: Vector3)

@export_group("Speed")
@export var walk_speed := 5.0
@export var sprint_speed := 8.0
@export var crouch_speed := 2.6
## Acceleration toward the wished-for velocity on the ground, in m/s².
@export var ground_accel := 50.0
## Braking when there is no input, in m/s².
@export var ground_friction := 34.0
## Steering in the air, in m/s²; air movement never bleeds off speed by itself.
@export var air_accel := 10.0

@export_group("Jump")
@export var jump_velocity := 5.2
## Extra gravity while falling, for a snappier arc.
@export var fall_gravity_scale := 1.6
## Share of upward velocity kept when jump is released early (short hops).
@export var jump_cut := 0.5
## Grace period to still jump after walking off a ledge.
@export var coyote_time := 0.12
## A jump pressed this long before landing still fires on touchdown.
@export var jump_buffer := 0.12

@export_group("Crouch and slide")
@export var stand_height := 1.8
@export var crouch_height := 1.1
@export var stand_eye := 1.6
@export var crouch_eye := 1.0
@export var crouch_transition := 12.0
## Slide starts at least this fast; sprinting into crouch triggers it.
@export var slide_speed := 10.5
@export var slide_friction := 7.0
## Slide ends below this speed.
@export var slide_min_speed := 3.5
@export var slide_cooldown := 0.6

@export_group("Ladders")
## Climbing speed up and down a ladder, in m/s.
@export var climb_speed := 3.0
## How far a climber hangs out from the ladder; they can't back off further mid-climb.
@export var climb_reach := 0.45
## After jumping off a ladder, it can't be grabbed again for this long.
@export var ladder_regrab := 0.4
## Sideways shuffling speed on a ladder, in m/s.
@export var climb_side_speed := 1.2
## Shuffling further than this (m) from the middle of a ladder steps off its side.
@export var climb_side_limit := 0.25
## How far down you can look while climbing, in degrees (the hands are on the rungs
## above; looking further down would show the arms ending in mid-air).
@export var climb_look_down := 30.0

@export_group("Health")
@export var max_health := 100.0
@export var respawn_delay := 3.0

@export_group("Look")
@export var mouse_sensitivity := 0.0022
## Ledges up to this height (steps, curbs, rocks) are climbed automatically.
@export var max_step_height := 0.35

@onready var head: Node3D = $Head
@onready var collider: CollisionShape3D = $CollisionShape3D
@onready var capsule: CapsuleShape3D = collider.shape

var is_sprinting := false
var is_crouching := false
var is_sliding := false
var health := 100.0
var dead := false
## Gems collected (see Pickup); kept through death.
var gems := 0
## Seconds of invulnerability left (0 = none).
var invulnerable_time := 0.0
## Set from the dev console: damage is ignored, and turning it on hands over every
## weapon with unlimited ammo (see WeaponManager).
var god_mode := false:
	set(on):
		god_mode = on
		var wm := get_node_or_null("WeaponManager") as WeaponManager
		if wm:
			wm.infinite_ammo = on
			if on:
				wm.give_all_weapons()

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _coyote := 0.0
var _buffer := 0.0
var _was_on_floor := true
var _slide_dir := Vector3.ZERO
var _slide_timer := 0.0
var _spawn: Transform3D
var _invulnerable := false
## Ladders the body is touching (most recent last).
var _ladders: Array[Ladder] = []
var _ladder_cooldown := 0.0
## True while climbing a ladder.
var is_climbing := false


func _ready() -> void:
	add_to_group("player")
	# Collide with the world and with enemies (physics layers 1 and 3).
	collision_mask = 1 | 4
	health = max_health
	_spawn = global_transform


func take_damage(amount: float, at := Vector3.ZERO, _dir := Vector3.ZERO) -> void:
	if dead or god_mode:
		return
	if invulnerable_time > 0.0:
		shield_hit.emit(amount, at)
		return
	health = maxf(health - amount, 0.0)
	health_changed.emit(health, max_health)
	damaged.emit(amount, at)
	var cam := head.get_node("Camera3D")
	if cam.has_method("add_trauma"):
		cam.add_trauma(clampf(amount / 40.0, 0.15, 0.5))
	if health <= 0.0:
		_die()


## Returns false (pickup stays) when already at full health.
func heal(amount: float) -> bool:
	if dead or health >= max_health:
		return false
	health = minf(health + amount, max_health)
	health_changed.emit(health, max_health)
	message.emit("+%d health" % amount)
	return true


## Starts a powerup, or tops it back up to `duration`. Always taken while alive.
func give_powerup(powerup: String, duration: float) -> bool:
	if dead:
		return false
	match powerup:
		"invulnerability":
			invulnerable_time = maxf(invulnerable_time, duration)
			_invulnerable = true
			message.emit("Invulnerability!")
		_:
			return false
	powerup_started.emit(powerup, duration)
	return true


## Always taken: gems have no limit.
func add_gems(amount: int) -> bool:
	gems += amount
	gems_changed.emit(gems)
	message.emit("Picked up a gem" if amount == 1 else "Picked up %d gems" % amount)
	return true


func _die() -> void:
	dead = true
	if is_sliding:
		_end_slide()
	died.emit()
	get_tree().create_timer(respawn_delay).timeout.connect(_respawn)


func _respawn() -> void:
	_end_invulnerability()
	global_transform = _spawn
	velocity = Vector3.ZERO
	head.rotation.x = 0.0
	health = max_health
	dead = false
	health_changed.emit(health, max_health)
	respawned.emit()


func enter_ladder(ladder: Ladder) -> void:
	if ladder not in _ladders:
		_ladders.append(ladder)


func exit_ladder(ladder: Ladder) -> void:
	_ladders.erase(ladder)


## The ladder being touched (the latest one), or null.
func current_ladder() -> Ladder:
	return null if _ladders.is_empty() else _ladders.back()


## Moves the body instantly (portals). Head pitch is kept; yaw comes from `to`.
func teleport(to: Transform3D, new_velocity: Vector3) -> void:
	global_transform = to
	velocity = new_velocity
	teleported.emit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not dead:
		# screen_relative ignores the low-res viewport's scaling, so sensitivity
		# stays the same whatever the PS1 render resolution is.
		var d: Vector2 = event.screen_relative * mouse_sensitivity
		rotate_y(-d.x)
		var low := -climb_look_down if is_climbing else -89.0
		head.rotation.x = clampf(head.rotation.x - d.y, minf(deg_to_rad(low), head.rotation.x), deg_to_rad(89.0))


func horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func _process(delta: float) -> void:
	if is_climbing:
		# Grabbing a ladder while looking further down lifts the view to the limit.
		head.rotation.x = move_toward(head.rotation.x, maxf(head.rotation.x, deg_to_rad(-climb_look_down)),
			4.0 * delta)
	if invulnerable_time > 0.0:
		invulnerable_time -= delta
		if invulnerable_time <= 0.0:
			_end_invulnerability()


func _end_invulnerability() -> void:
	if _invulnerable:
		invulnerable_time = 0.0
		_invulnerable = false
		powerup_ended.emit("invulnerability")


func _physics_process(delta: float) -> void:
	var on_floor := is_on_floor()
	_coyote = coyote_time if on_floor else maxf(_coyote - delta, 0.0)
	_buffer = jump_buffer if Input.is_action_just_pressed("jump") and not dead else maxf(_buffer - delta, 0.0)
	_slide_timer = maxf(_slide_timer - delta, 0.0)

	var input := Vector2.ZERO if dead else Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish := transform.basis * Vector3(input.x, 0.0, input.y)
	is_sprinting = Input.is_action_pressed("sprint") and input.y < -0.5 and not is_crouching

	_update_crouch(on_floor, delta)
	_ladder_cooldown = maxf(_ladder_cooldown - delta, 0.0)
	is_climbing = _climb(wish, on_floor, delta)
	if is_climbing:
		move_and_slide()
		_was_on_floor = is_on_floor()
		return
	_apply_gravity(on_floor, delta)
	_try_jump()

	var hv := Vector3(velocity.x, 0.0, velocity.z)
	if is_sliding:
		hv = hv.move_toward(Vector3.ZERO, slide_friction * delta)
		# A little steering keeps slides controllable without turning them into walking.
		if wish != Vector3.ZERO and hv != Vector3.ZERO:
			var turn := clampf(_slide_dir.signed_angle_to(wish, Vector3.UP), -1.0, 1.0)
			hv = hv.rotated(Vector3.UP, turn * delta * 0.8)
			_slide_dir = hv.normalized()
		if hv.length() < slide_min_speed or not on_floor:
			_end_slide()
	elif on_floor:
		var target := wish * _move_speed()
		hv = hv.move_toward(target, (ground_accel if wish != Vector3.ZERO else ground_friction) * delta)
	elif wish != Vector3.ZERO:
		hv = hv.move_toward(wish * maxf(hv.length(), walk_speed), air_accel * delta)
	velocity.x = hv.x
	velocity.z = hv.z

	var fall_speed := -velocity.y
	move_and_slide()
	if is_on_floor() and is_on_wall() and wish != Vector3.ZERO:
		# Probe with the intended motion: after hitting the ledge, velocity is ~0.
		_try_step_up(wish * _move_speed() * delta)

	var now_on_floor := is_on_floor()
	if now_on_floor and not _was_on_floor:
		landed.emit(maxf(fall_speed, 0.0))
	_was_on_floor = now_on_floor


func _move_speed() -> float:
	if is_crouching:
		return crouch_speed
	return sprint_speed if is_sprinting else walk_speed


func _apply_gravity(on_floor: bool, delta: float) -> void:
	if on_floor:
		return
	var g_scale := fall_gravity_scale if velocity.y < 0.0 else 1.0
	velocity.y -= _gravity * g_scale * delta
	if Input.is_action_just_released("jump") and velocity.y > 0.0:
		velocity.y *= jump_cut


## Ladders: push toward one to climb up it and pull away to climb down. Mid-climb you
## can't back off it (pulling away only takes you down), so you don't fall off by
## accident; strafing shuffles slowly sideways, and too far steps off the side and falls.
## Looking down is limited while climbing (climb_look_down). At the top, pushing on carries you over onto the landing; from the
## landing, walk off the edge onto the ladder to climb down. Jump to let go. Returns
## false (move normally) at the foot of the ladder and on the landing.
func _climb(wish: Vector3, on_floor: bool, delta: float) -> bool:
	if _ladders.is_empty() or dead or _ladder_cooldown > 0.0:
		return false
	var ladder := _ladders.back() as Ladder
	var at := ladder.to_local(global_position)  # feet, in the ladder's units
	if at.z < -ladder.landing_gap:
		return false  # on the landing
	var m := ladder.unit()
	var out := ladder.outward()
	var toward := -wish.dot(out)
	var dir := signf(toward) if absf(toward) > 0.2 else 0.0
	if on_floor and at.y * m < 0.3 and dir <= 0.0:
		return false  # standing at the foot
	if not is_climbing and not on_floor and dir == 0.0:
		return false  # falling past it: only grabbed by pushing toward or away from it
	if _buffer > 0.0:
		# Let go, pushing off backwards.
		_buffer = 0.0
		_ladder_cooldown = ladder_regrab
		velocity = out * 3.5 + Vector3.UP * 2.5
		jumped.emit()
		return false
	var side := ladder.global_basis.x.normalized()
	var off := at.x * m  # meters from the middle of the ladder
	var push := wish.dot(side)
	if is_climbing and absf(off) > climb_side_limit and push * signf(off) > 0.3:
		# Shuffled off the side: let go.
		_ladder_cooldown = ladder_regrab
		return false
	if is_sliding:
		_end_slide()
	var hv := wish * walk_speed * 0.6
	# Sideways: a slow shuffle, drawn back to the middle when not pushing aside.
	var lateral := push * climb_side_speed if absf(push) > 0.3 else clampf(-off * 6.0, -1.5, 1.5)
	hv += side * (lateral - hv.dot(side))
	# Over the top: stop rising once clear of the landing and step on over onto it,
	# unless pulling back down.
	if dir >= 0.0 and (at.y - ladder.height) * m > 0.1:
		dir = 0.0
		hv -= out * (walk_speed * 0.6 + hv.dot(out))
	if at.z * m > climb_reach:
		hv -= out * maxf(hv.dot(out), 0.0)
	var cur := Vector3(velocity.x, 0.0, velocity.z).move_toward(hv, ground_accel * delta)
	velocity = Vector3(cur.x, dir * climb_speed, cur.z)
	_coyote = 0.0
	return true


func _try_jump() -> void:
	if _buffer <= 0.0 or _coyote <= 0.0:
		return
	if is_crouching and not _has_headroom():
		return
	_buffer = 0.0
	_coyote = 0.0
	velocity.y = jump_velocity
	# Slide-jumps keep the slide's momentum.
	if is_sliding:
		_end_slide()
	is_crouching = false
	jumped.emit()


func _update_crouch(on_floor: bool, delta: float) -> void:
	var want := Input.is_action_pressed("crouch") or dead  # the body slumps when dead
	if want and not is_crouching:
		is_crouching = true
		if on_floor and not dead and horizontal_speed() > walk_speed + 0.5 and _slide_timer <= 0.0:
			_start_slide()
	elif not want and is_crouching and _has_headroom():
		is_crouching = false
		if is_sliding:
			_end_slide()

	var t := 1.0 - exp(-crouch_transition * delta)
	capsule.height = lerpf(capsule.height, crouch_height if is_crouching else stand_height, t)
	collider.position.y = capsule.height / 2.0
	head.position.y = lerpf(head.position.y, crouch_eye if is_crouching else stand_eye, t)


func _has_headroom() -> bool:
	var rise := stand_height - capsule.height
	return rise < 0.01 or not test_move(global_transform, Vector3(0.0, rise, 0.0))


func _start_slide() -> void:
	is_sliding = true
	_slide_dir = Vector3(velocity.x, 0.0, velocity.z).normalized()
	var speed := maxf(horizontal_speed(), slide_speed)
	velocity.x = _slide_dir.x * speed
	velocity.z = _slide_dir.z * speed
	slide_started.emit()


func _end_slide() -> void:
	if not is_sliding:
		return
	is_sliding = false
	_slide_timer = slide_cooldown
	slide_ended.emit()


## Lifts the body over a low ledge: test that there is room above, that the
## raised body can move forward, then drop it back down onto the ledge. The
## capsule's rounded bottom rides up the ledge's edge over a few frames.
func _try_step_up(motion: Vector3) -> void:
	if motion.length() < 0.001:
		return
	var up := Vector3(0.0, max_step_height, 0.0)
	if test_move(global_transform, up):
		return
	var raised := global_transform.translated(up)
	if test_move(raised, motion):
		return
	var ahead := raised.translated(motion)
	var hit := KinematicCollision3D.new()
	if not test_move(ahead, -up, hit):
		return
	var landed_at := ahead.origin + hit.get_travel()
	if landed_at.y > global_position.y + 0.005:
		global_position = landed_at
