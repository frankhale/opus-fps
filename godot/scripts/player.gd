extends CharacterBody3D
## First-person movement with AAA-style feel:
##  * snappy ground acceleration and braking, momentum-preserving air control
##  * sprint, crouch and sprint-slide
##  * jump with coyote time, input buffering, variable height and snappier falls
##  * automatic step-up over low ledges
##  * health: damage, healing, death and respawning at the start point
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

var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")
var _coyote := 0.0
var _buffer := 0.0
var _was_on_floor := true
var _slide_dir := Vector3.ZERO
var _slide_timer := 0.0
var _spawn: Transform3D


func _ready() -> void:
	add_to_group("player")
	# Collide with the world and with enemies (physics layers 1 and 3).
	collision_mask = 1 | 4
	health = max_health
	_spawn = global_transform


func take_damage(amount: float, at := Vector3.ZERO, _dir := Vector3.ZERO) -> void:
	if dead:
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


func _die() -> void:
	dead = true
	if is_sliding:
		_end_slide()
	died.emit()
	get_tree().create_timer(respawn_delay).timeout.connect(_respawn)


func _respawn() -> void:
	global_transform = _spawn
	velocity = Vector3.ZERO
	head.rotation.x = 0.0
	health = max_health
	dead = false
	health_changed.emit(health, max_health)
	respawned.emit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not dead:
		# screen_relative ignores the low-res viewport's scaling, so sensitivity
		# stays the same whatever the PS1 render resolution is.
		var d: Vector2 = event.screen_relative * mouse_sensitivity
		rotate_y(-d.x)
		head.rotation.x = clampf(head.rotation.x - d.y, deg_to_rad(-89.0), deg_to_rad(89.0))


func horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func _physics_process(delta: float) -> void:
	var on_floor := is_on_floor()
	_coyote = coyote_time if on_floor else maxf(_coyote - delta, 0.0)
	_buffer = jump_buffer if Input.is_action_just_pressed("jump") and not dead else maxf(_buffer - delta, 0.0)
	_slide_timer = maxf(_slide_timer - delta, 0.0)

	var input := Vector2.ZERO if dead else Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	var wish := transform.basis * Vector3(input.x, 0.0, input.y)
	is_sprinting = Input.is_action_pressed("sprint") and input.y < -0.5 and not is_crouching

	_update_crouch(on_floor, delta)
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
