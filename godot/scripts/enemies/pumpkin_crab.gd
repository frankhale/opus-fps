class_name PumpkinCrab
extends Enemy
## The pumpkin crab (assets/enemies/enemy_pumpkin_crab.glb): a big crab whose shell is a
## carved jack-o'-lantern under a witch's hat, with little lanterns hanging off its horns.
## Left alone it potters about its stretch of beach the way crabs do, scuttling sideways
## in quick bursts and stopping to look about and clack its claws, its face flickering
## low like a candle.
##
## Once aggroed (Enemy: the player inside its ring and in sight, or a shot) its face
## flares, it rears up clacking both claws and comes after them, facing them and sidling
## in. It has two attacks:
##   * the pinch, within `pinch_range`: it raises one claw with the jaw gaping
##     (`pinch_windup`, glowing), then lunges and snaps it shut through the space in front
##     of it. A player in front of it and in reach takes `pinch_damage` and is knocked
##     back (one hit per pinch). It pinches with each claw in turn.
##   * the lantern, from `throw_range` away and in sight, every `throw_cooldown` seconds:
##     it reaches up and plucks one of the lanterns off its back (`throw_windup`), then
##     lobs it in an arc at where the player is heading (PumpkinBomb), where it bursts
##     into flame. The lantern grows back on its string `regrow_time` later.
## When killed it bursts in a shower of rind and embers (loot and respawning come from
## Enemy).
##
## It's animated procedurally on its rig (see enemy_pumpkin_crab in the asset generator).
## Its eight legs walk as the spider's do: each toe stays planted until the body has
## moved on too far from it, then steps in a quick arc to a spot ahead, in two
## alternating sets, each knee bent to reach its toe (two-bone IK). The body settles to
## its feet, rears up and lunges. The claws reach for where each action wants them
## (two-bone IK) and their upper fingers open and snap shut. The hat and the hanging
## lanterns swing on springs with every lurch. Embers drift up from its eyes and the
## corners of its grin like sparks off a fire, thicker as its face flares.

const MODEL := preload("res://assets/enemies/enemy_pumpkin_crab.glb")
const SOUNDS := {
	"alert": preload("res://assets/sfx/crab_alert.wav"),
	"charge": preload("res://assets/sfx/crab_charge.wav"),
	"snap": preload("res://assets/sfx/crab_snap.wav"),
	"hit": preload("res://assets/sfx/crab_hit.wav"),
	"throw": preload("res://assets/sfx/crab_throw.wav"),
	"hurt": preload("res://assets/sfx/crab_hurt.wav"),
	"die": preload("res://assets/sfx/crab_die.wav"),
}
const STEP_SOUND := preload("res://assets/sfx/crab_step.wav")
const GLOW := preload("res://materials/ps1_glow.tres")
const FLAME := Color(1.0, 0.5, 0.12)
## The glow material's emission when calm, awake and fully charged: well over the
## world's glow threshold, so the face and lanterns bloom even in daylight.
const EMBER := 2.0
const AWAKE := 3.2
const BLAZE := 5.5
## Keeps it a deep, fiery orange (with yellow at the heart of each cut) as it brightens.
const GLOW_TINT := Vector3(1.0, 0.55, 0.28)
const LANTERNS := 6
## The carved face in the model's own space (+Z is its front), where its light sits.
const FACE := Vector3(0.0, 0.85, 0.6)
## Where embers rise from, in the same space: its eyes and the corners of its grin.
const EMBER_SPOTS := [Vector3(0.28, 1.13, 0.37), Vector3(-0.28, 1.13, 0.37),
	Vector3(0.45, 0.78, 0.31), Vector3(-0.45, 0.78, 0.31)]
## Embers per second from each spot when calm, and at full blaze.
const EMBER_RATE := Vector2(12.0, 30.0)

@export var walk_speed := 1.8
@export var hunt_speed := 3.4
@export var turn_speed := 5.0
## It stays within this far of where it started (across the ground).
@export var wander_radius := 10.0
## How far each scuttle goes, at least and at most.
@export var walk_distance := Vector2(2.0, 6.0)
## Seconds it stands about between scuttles.
@export var idle_time := Vector2(1.5, 4.5)

@export_group("Pinch")
@export var pinch_range := 2.0
@export var pinch_windup := 0.45
@export var pinch_time := 0.22
@export var pinch_recover := 0.4
@export var pinch_cooldown := Vector2(0.6, 1.2)
@export var pinch_damage := 18.0
## Reach of the claws (across the ground from its middle) and their sweep either side.
@export var pinch_reach := 2.4
@export var pinch_arc := 60.0
## How hard a hit knocks the player back (m/s).
@export var pinch_push := 5.0

@export_group("Lantern")
## It throws when the player is between these distances (across the ground).
@export var throw_range := Vector2(5.0, 16.0)
@export var throw_windup := 0.7
@export var throw_time := 0.3
@export var throw_cooldown := Vector2(3.5, 6.0)
@export var bomb_damage := 22.0
@export var bomb_radius := 2.2
@export var regrow_time := 8.0

@export_group("Legs")
## How far (model units) a toe may fall behind its resting spot before it steps.
@export var stride := 0.3
@export var step_time := 0.1
@export var step_height := 0.16

## Where it may go: (world point) -> bool. Set by the level; by default anywhere within
## wander_radius of home.
var can_stand: Callable

enum State { IDLE, MOVE, HUNT, WINDUP, PINCH, RECOVER, THROW_WINDUP, THROW }

var _state := State.IDLE
var _state_timer := 0.0
var _target := Vector3.ZERO
## The way it faces while it scuttles: side-on to where it's going.
var _side_on := Vector3.ZERO
var _stuck_timer := 0.0
var _stuck_from := Vector3.ZERO
var _pinch_timer := 0.0
var _throw_timer := 0.0
var _hit_done := false
var _strafe_dir := 1.0
## The claw that pinches or throws next ("l" or "r"), and the lantern being thrown.
var _claw := "l"
var _lantern := 0
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

var _glow_mat: ShaderMaterial
var _glow := EMBER
var _light: OmniLight3D
var _embers: Array[GPUParticles3D] = []
## Wind-up glow, 0 to 1.
var _charge := 0.0
## Rearing up clacking its claws as it notices the player (seconds left).
var _wake := 0.0

var _skeleton: Skeleton3D
var _bones := {}
var _body_rest: Transform3D
## The current body offset from the rest pose (bob, settling, rearing), skeleton space.
var _body_pose := Transform3D.IDENTITY
var _lift := 0.0
var _pitch := 0.0
## One entry per leg: bones, rest points (skeleton space), segment lengths, the planted
## toe (world), and the step in progress.
var _legs: Array[Dictionary] = []
## Per claw: arm bones, rest points and lengths, the wrist and the way the claw points
## (eased toward the pose it wants), the upper finger's bone and hinge axis, and how far
## it's open.
var _arms := {}
## Per lantern: seconds until it grows back (0 when it's there) and its size.
var _lantern_gone: Array[float] = []
var _lantern_size: Array[float] = []
## Springs (radians about the model's X and Z) for the lanterns and the hat.
var _lantern_p: Array[Vector2] = []
var _lantern_v: Array[Vector2] = []
var _hat_p := Vector2.ZERO
var _hat_v := Vector2.ZERO
var _last_velocity := Vector3.ZERO
var _step_audio: AudioStreamPlayer3D
var _strike_audio: AudioStreamPlayer3D


func _init() -> void:
	max_health = 120.0
	knockback = 0.08
	aggro_radius = 6.0
	loot_drops = Vector2i(1, 2)
	gem_drops = 2


func _ready() -> void:
	floor_snap_length = 0.4
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.6 * model_scale
	shape.shape = sphere
	shape.position.y = 0.75 * model_scale
	add_child(shape)
	_setup(MODEL, SOUNDS)
	_model.rotation.y = PI  # the model faces its +Z; this node faces -Z
	_step_audio = AudioStreamPlayer3D.new()
	_step_audio.stream = STEP_SOUND
	_step_audio.unit_size = 4.0
	_step_audio.max_polyphony = 2
	add_child(_step_audio)
	# The hit lands over the snap, so it gets its own player.
	_strike_audio = AudioStreamPlayer3D.new()
	_strike_audio.unit_size = 6.0
	add_child(_strike_audio)
	# Its face and lanterns: its own copy of the glow material, so they can flicker.
	_glow_mat = GLOW.duplicate()
	_glow_mat.set_shader_parameter("emission_tint", GLOW_TINT)
	for m: GeometryInstance3D in _meshes:
		var mi := m as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			if mi.get_active_material(i) == GLOW:
				mi.set_surface_override_material(i, _glow_mat)
	# A candle in the shell, lighting what's in front of its face (hidden with the model).
	_light = OmniLight3D.new()
	_light.light_color = FLAME
	_light.omni_range = 4.0
	_light.position = FACE
	_model.add_child(_light)
	_strafe_dir = 1.0 if randf() < 0.5 else -1.0
	_state_timer = randf_range(idle_time.x, idle_time.y)
	_setup_rig()
	_setup_embers()


func _eye_point() -> Vector3:
	return global_position + Vector3.UP * 0.9 * model_scale


func _physics_process(delta: float) -> void:
	if dead:
		return
	_t += delta
	_hurt_cooldown -= delta
	_pinch_timer -= delta
	_throw_timer -= delta
	_wake = maxf(_wake - delta, 0.0)
	_update_lanterns(delta)
	_update_awareness(delta)
	if alerted and _state in [State.IDLE, State.MOVE]:
		_state = State.HUNT

	var desired := Vector3.ZERO
	var face := Vector3.ZERO  # which way to turn, if any
	var to_player := _player.global_position - global_position if _player else Vector3.ZERO
	var dist := Vector2(to_player.x, to_player.z).length()
	var dir := Vector3(to_player.x, 0.0, to_player.z) / maxf(dist, 0.01)
	_state_timer -= delta
	match _state:
		State.IDLE:
			if _state_timer <= 0.0:
				set_out()
		State.MOVE:
			desired = _wander_velocity(delta)
			face = _side_on
		State.HUNT:
			face = dir
			if not alerted:
				_stop()
			elif _wake > 0.0:
				pass  # rearing up, clacking its claws at them
			elif dist < pinch_range and _pinch_timer <= 0.0 and is_on_floor():
				_claw = "r" if _claw == "l" else "l"
				_start(State.WINDUP, pinch_windup, "charge")
			elif dist > throw_range.x and dist < throw_range.y and _throw_timer <= 0.0 and is_on_floor() \
					and _pick_lantern() >= 0 and _line_of_sight():
				_lantern = _pick_lantern()
				var side: Vector3 = _skeleton.get_bone_global_rest(_bones["lantern_%d" % _lantern]).origin
				_claw = "l" if side.x > 0.0 else "r"
				_start(State.THROW_WINDUP, throw_windup, "charge")
			else:
				# Sidles in, or waits just out of reach for its claws to be ready again.
				var stand_off := 0.0 if _pinch_timer <= 0.0 else pinch_range * 0.9
				if randf() < delta * 0.4:
					_strafe_dir = -_strafe_dir
				var side := dir.cross(Vector3.UP) * _strafe_dir * 0.5
				desired = (dir * clampf((dist - stand_off) * 1.5, -0.5, 1.0) + side).limit_length(1.0) * hunt_speed
				if desired.length() > 0.01 and can_stand.is_valid() \
						and not can_stand.call(global_position + desired.normalized() * 0.8):
					desired = Vector3.ZERO
		State.WINDUP:
			face = dir
			_charge = move_toward(_charge, 1.0, delta / pinch_windup)
			if _state_timer <= 0.0:
				_start(State.PINCH, pinch_time, "snap")
				_hit_done = false
		State.PINCH:
			# Lunges into the snap.
			var t := 1.0 - _state_timer / pinch_time
			desired = -global_basis.z * 3.0 * sin(PI * clampf(t, 0.0, 1.0))
			if not _hit_done and t > 0.35:
				_check_pinch_hit()
			if _state_timer <= 0.0:
				_pinch_timer = randf_range(pinch_cooldown.x, pinch_cooldown.y)
				_state = State.RECOVER
				_state_timer = pinch_recover
		State.RECOVER:
			if alerted:
				face = dir
			if _state_timer <= 0.0:
				_after_attack()
		State.THROW_WINDUP:
			face = dir
			_charge = move_toward(_charge, 1.0, delta / throw_windup)
			if _state_timer <= 0.0:
				_throw()
				_state = State.THROW
				_state_timer = throw_time
		State.THROW:
			if _state_timer <= 0.0:
				_throw_timer = randf_range(throw_cooldown.x, throw_cooldown.y)
				_state = State.RECOVER
				_state_timer = pinch_recover

	if _state not in [State.WINDUP, State.THROW_WINDUP]:
		_charge = move_toward(_charge, 0.0, delta * 2.5)

	var attacking := _state not in [State.IDLE, State.MOVE, State.HUNT]
	var hv := Vector3(velocity.x, 0.0, velocity.z).lerp(desired, 1.0 - exp(-(10.0 if attacking else 6.0) * delta))
	velocity.x = hv.x
	velocity.z = hv.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
	move_and_slide()
	if face.length() > 0.01:
		_face(face, delta, 8.0 if _state in [State.WINDUP, State.THROW_WINDUP] else turn_speed)

	# Face and lanterns: a low candle while it's calm, lit up once it's awake, blazing as
	# it winds up, and always flickering.
	var want := EMBER if not alerted and _state in [State.IDLE, State.MOVE] else AWAKE
	_glow = lerpf(_glow, want + (BLAZE - AWAKE) * _charge, 1.0 - exp(-4.0 * delta))
	var flicker := 0.88 + 0.12 * sin(_t * 17.0) * sin(_t * 7.3 + 1.0)
	_glow_mat.set_shader_parameter("emission_strength", _glow * flicker)
	_light.light_energy = 0.3 * _glow * flicker
	var heat := clampf((_glow - EMBER) / (BLAZE - EMBER), 0.0, 1.0)
	for e in _embers:
		e.amount_ratio = lerpf(EMBER_RATE.x, EMBER_RATE.y, heat) / EMBER_RATE.y
	_flash_amount = move_toward(_flash_amount, 0.0, delta * 6.0)
	_set_glow(FLAME, maxf(_flash_amount, _charge * 0.25))
	_animate(delta)


## Scuttling toward its target in quick bursts; stops on arrival or when it gets stuck.
func _wander_velocity(delta: float) -> Vector3:
	var to := _target - global_position
	to.y = 0.0
	var dist := to.length()
	if dist < 0.4 or (can_stand.is_valid() and not can_stand.call(global_position + to / dist * 0.8)):
		_stop()
		return Vector3.ZERO
	_stuck_timer -= delta
	if _stuck_timer <= 0.0:
		if global_position.distance_to(_stuck_from) < 0.3:
			_stop()  # ran into something
			return Vector3.ZERO
		_stuck_timer = 1.5
		_stuck_from = global_position
	var burst := 1.0 if fmod(_t * 0.9, 1.0) < 0.7 else 0.0
	return to / dist * walk_speed * burst


## Scuttles off somewhere nearby, side-on. Returns false if there was nowhere to go (or
## it's busy hunting the player).
func set_out() -> bool:
	if dead or _state not in [State.IDLE, State.MOVE]:
		return false
	var allowed := can_stand if can_stand.is_valid() else func(_p: Vector3) -> bool: return true
	for i in 32:
		var a := randf() * TAU
		var p := global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(walk_distance.x, walk_distance.y)
		if Vector2(p.x - _home.x, p.z - _home.z).length() < wander_radius and allowed.call(p):
			_target = p
			# Whichever side-on facing is nearer the way it faces now.
			var across := (p - global_position).cross(Vector3.UP).normalized()
			_side_on = across if across.dot(-global_basis.z) >= 0.0 else -across
			_state = State.MOVE
			_stuck_timer = 1.5
			_stuck_from = global_position
			return true
	_state_timer = 2.0
	return false


func _stop() -> void:
	_state = State.IDLE
	_state_timer = randf_range(idle_time.x, idle_time.y)


func _start(state: State, time: float, sound: String) -> void:
	_state = state
	_state_timer = time
	_play(sound, 3.0)


func _after_attack() -> void:
	if alerted:
		_state = State.HUNT
	else:
		_stop()


func _on_alert() -> void:
	if _state in [State.IDLE, State.MOVE]:
		_wake = 0.8


func _on_lost_sight() -> void:
	if _state == State.HUNT:
		_stop()
	elif _state in [State.WINDUP, State.THROW_WINDUP]:
		_state = State.RECOVER  # calls off the attack
		_state_timer = pinch_recover


# ---------------------------------------------------------------------------
# Attacks
# ---------------------------------------------------------------------------
## Lands the pinch if the player is in front of it and in reach of its claw.
func _check_pinch_hit() -> void:
	if _player == null or _player.get("dead"):
		return
	var off := _player.global_position - global_position
	var flat := Vector3(off.x, 0.0, off.z)
	if flat.length() > pinch_reach or off.y > 2.0 or off.y < -1.5:
		return
	if rad_to_deg((-global_basis.z).angle_to(flat)) > pinch_arc and flat.length() > 0.8:
		return
	_hit_done = true
	var dir := flat.normalized()
	_player.take_damage(pinch_damage, _player.global_position + Vector3.UP, dir)
	if _player is CharacterBody3D:
		(_player as CharacterBody3D).velocity += dir * pinch_push + Vector3.UP * 2.0
	_strike_audio.stream = _sounds["hit"]
	_strike_audio.volume_db = 4.0
	_strike_audio.pitch_scale = randf_range(0.9, 1.1)
	_strike_audio.play()
	var sparks := FX.burst(FLAME, 10, 3.5, 0.06, 0.4, -9.8, 2.0)
	get_parent().add_child(sparks)
	sparks.global_position = _player.global_position + Vector3.UP * 1.1
	sparks.emitting = true
	get_tree().create_timer(1.0).timeout.connect(sparks.queue_free)


## Lobs the plucked lantern at where the player is heading.
func _throw() -> void:
	_play("throw", 2.0)
	_lantern_gone[_lantern] = regrow_time
	_lantern_size[_lantern] = 0.0
	if _player == null or _player.get("dead"):
		return
	var aim := _player.global_position
	if _player is CharacterBody3D:
		var v := (_player as CharacterBody3D).velocity
		aim += Vector3(v.x, 0.0, v.z) * 0.6
	# The player's body is on the world layer too: look past it for the ground.
	var q := PhysicsRayQueryParameters3D.create(aim + Vector3.UP * 2.0, aim + Vector3.DOWN * 30.0, 1, [_player.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	var bomb := PumpkinBomb.new()
	bomb.damage = bomb_damage
	bomb.radius = bomb_radius
	bomb.exclude = [get_rid()]
	get_parent().add_child(bomb)
	var claw: int = _bones["pincer_%s" % _claw]
	bomb.launch(_skeleton.global_transform * _skeleton.get_bone_global_pose(claw).origin,
		hit.position if hit else aim)


## A lantern that's on its string, at random, or -1 if they're all thrown.
func _pick_lantern() -> int:
	var hanging: Array[int] = []
	for i in _lantern_gone.size():
		if _lantern_gone[i] <= 0.0:
			hanging.append(i)
	return hanging.pick_random() if not hanging.is_empty() else -1


func _update_lanterns(delta: float) -> void:
	for i in _lantern_gone.size():
		if _lantern_gone[i] > 0.0:
			_lantern_gone[i] -= delta
		else:
			_lantern_size[i] = move_toward(_lantern_size[i], 1.0, delta * 1.5)


## Embers rising from its eyes and the corners of its grin: tiny glowing sparks, yellow
## as they leave, cooling through orange to a dull red and winking out as they drift up
## and away on the air. They're left behind in the world as it moves, so they trail
## off it. Each emitter rides on its body bone, so they follow its face as it rears.
func _setup_embers() -> void:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.05
	m.direction = Vector3(0.0, 1.0, 0.3)
	m.spread = 35.0
	m.initial_velocity_min = 0.25
	m.initial_velocity_max = 0.7
	m.gravity = Vector3(0.0, 0.9, 0.0)  # carried up on the heat
	m.damping_min = 0.4
	m.damping_max = 1.0
	m.turbulence_enabled = true
	m.turbulence_noise_strength = 0.6
	m.turbulence_noise_scale = 2.5
	m.turbulence_influence_min = 0.05
	m.turbulence_influence_max = 0.15
	m.scale_min = 0.05
	m.scale_max = 0.09
	m.scale_curve = FX.curve([Vector2(0, 1), Vector2(0.7, 0.7), Vector2(1, 0)])
	m.color_ramp = FX.ramp([Color(1.0, 0.7, 0.2), Color(1.0, 0.42, 0.06), Color(0.8, 0.14, 0.03),
		Color(0.35, 0.05, 0.02, 0.0)], [0.0, 0.3, 0.7, 1.0])
	# Solid rather than additive, so they show up against the bright sand and sky; bright
	# enough to bloom.
	var mesh := FX.quad(false, 1.5)
	var parent: Node3D = _model
	if _skeleton:
		var bone := BoneAttachment3D.new()
		bone.bone_name = "body"
		_skeleton.add_child(bone)
		parent = bone
	for spot: Vector3 in EMBER_SPOTS:
		var e := FX.emitter(int(EMBER_RATE.y * 1.6), 1.6, m, mesh, false)
		e.randomness = 0.5
		e.layers = ENEMY_VISUAL_LAYER
		parent.add_child(e)
		# Placed by the rest pose: the attachment carries it with the body from there.
		e.position = (_body_rest.affine_inverse() * spot) if _skeleton else spot
		e.emitting = true
		_embers.append(e)


func _on_death() -> void:
	for e in _embers:
		e.emitting = false
	_state = State.IDLE
	_charge = 0.0
	for e in [[Color(0.5, 0.33, 0.2), 0.7], [Color(0.78, 0.35, 0.12), 0.8], [FLAME, 3.0], [Color(1.0, 0.8, 0.3), 3.0]]:
		var puff := FX.burst(e[0], 18, 5.0, 0.12, 1.0, -9.8, e[1])
		add_child(puff)
		puff.position.y = 0.8 * model_scale
		puff.emitting = true
		get_tree().create_timer(1.3).timeout.connect(puff.queue_free)


func _on_respawn() -> void:
	_stop()
	for e in _embers:
		e.emitting = true
	_glow = EMBER
	for i in _lantern_gone.size():
		_lantern_gone[i] = 0.0
		_lantern_size[i] = 1.0
	# Feet start under the body again.
	if _skeleton:
		for leg in _legs:
			leg.foot = _skeleton.global_transform * (leg.rest_toe as Vector3)
			leg.t = 1.0


# ---------------------------------------------------------------------------
# Animation
# ---------------------------------------------------------------------------
func _setup_rig() -> void:
	var found := _model.find_children("*", "Skeleton3D", true, false)
	if found.is_empty():
		return
	_skeleton = found[0]
	for i in _skeleton.get_bone_count():
		_bones[_skeleton.get_bone_name(i)] = i
	_body_rest = _skeleton.get_bone_global_rest(_bones["body"])
	# Legs: leg_<side>_<k>_0 hip to knee and _1 knee to toe, whose tail is on the ground.
	for side in ["l", "r"]:
		for k in 4:
			var hip: int = _bones["leg_%s_%d_0" % [side, k]]
			var shin: int = _bones["leg_%s_%d_1" % [side, k]]
			var h := _skeleton.get_bone_global_rest(hip)
			var s := _skeleton.get_bone_global_rest(shin)
			var down := s.basis.y.normalized()
			var toe := s.origin + down * (s.origin.y / -down.y)
			var leg := {
				"hip": hip, "shin": shin,
				"hip_rest": h, "shin_rest": s,
				"rest_hip": h.origin, "rest_knee": s.origin, "rest_toe": toe,
				"l1": h.origin.distance_to(s.origin), "l2": s.origin.distance_to(toe),
				# Alternating sets: front-left steps with the second-right, and so on.
				"set": (k + (0 if side == "l" else 1)) % 2,
				"t": 1.0,
			}
			leg.foot = _skeleton.global_transform * toe
			leg.from = leg.foot
			leg.to = leg.foot
			_legs.append(leg)
	for side in ["l", "r"]:
		var arm0: int = _bones["arm_%s_0" % side]
		var arm1: int = _bones["arm_%s_1" % side]
		var pincer: int = _bones["pincer_%s" % side]
		var shoulder := _skeleton.get_bone_global_rest(arm0).origin
		var elbow := _skeleton.get_bone_global_rest(arm1).origin
		var wrist := _skeleton.get_bone_global_rest(_bones["claw_%s" % side]).origin
		var finger := _skeleton.get_bone_global_rest(pincer).basis.y.normalized()
		var claw := _skeleton.get_bone_global_rest(_bones["claw_%s" % side])
		_arms[side] = {
			"bones": [arm0, arm1], "rests": [_skeleton.get_bone_global_rest(arm0), _skeleton.get_bone_global_rest(arm1)],
			"root": shoulder, "rest": wrist, "wrist": wrist,
			"claw": _bones["claw_%s" % side], "claw_rest": claw,
			"rest_point": claw.basis.y.normalized(), "point": claw.basis.y.normalized(),
			"lengths": [shoulder.distance_to(elbow), elbow.distance_to(wrist)],
			"pole": elbow - (shoulder + wrist) * 0.5,  # bent up and out, as at rest
			# Turning about this lifts the finger, opening the jaw.
			"pincer": pincer, "hinge": finger.cross(Vector3.UP).normalized(), "open": 0.0,
		}
	for i in LANTERNS:
		_lantern_gone.append(0.0)
		_lantern_size.append(1.0)
		_lantern_p.append(Vector2.ZERO)
		_lantern_v.append(Vector2.ZERO)


func _animate(delta: float) -> void:
	if _skeleton == null:
		return
	# Body: rear up to wind up and throw, dip into a pinch, rock as it wakes.
	var pitch := 0.0
	match _state:
		State.WINDUP:
			pitch = 0.12
		State.PINCH:
			pitch = -0.15
		State.THROW_WINDUP:
			pitch = 0.28
		State.THROW:
			pitch = -0.1
	pitch += 0.3 * sin(_wake / 0.8 * PI) if _wake > 0.0 else 0.0
	_pitch = lerpf(_pitch, pitch, 1.0 - exp(-10.0 * delta))
	var roll := sin(_t * 30.0) * 0.06 * (_wake / 0.8)
	_animate_legs(delta, roll)
	_animate_arms(delta)
	_animate_springs(delta)


func _animate_legs(delta: float, roll: float) -> void:
	var sk := _skeleton.global_transform
	var to_sk := sk.affine_inverse()
	var size := sk.basis.get_scale().x
	var flat_v := Vector3(velocity.x, 0.0, velocity.z)
	var moving := flat_v.length()
	var step_t := step_time * clampf(4.0 / maxf(moving, 2.5), 0.8, 1.6)

	# Which set may step: the other must have all its feet down.
	var stepping := [false, false]
	for leg in _legs:
		if leg.t < 1.0:
			stepping[leg.set] = true
	var space := get_world_3d().direct_space_state
	var feet_y := 0.0
	var bob := 0.0
	for leg in _legs:
		# Where this toe would rest now, pushed ahead along the movement so it lands
		# in front and isn't left behind straight away.
		var home: Vector3 = sk * leg.rest_toe + flat_v * step_t * 1.6
		home.y = _ground_at(space, home)
		var off: Vector3 = home - leg.foot
		off.y = 0.0
		if leg.t >= 1.0:
			if off.length() > stride * size * 3.5:
				leg.foot = home  # knocked far out of place: just put it down
			elif off.length() > stride * size and not stepping[1 - leg.set]:
				leg.from = leg.foot
				leg.to = home
				leg.t = 0.0
				stepping[leg.set] = true
		else:
			leg.to = home  # keep aiming at the moving resting spot
			leg.t = minf(leg.t + delta / step_t, 1.0)
			var e: float = leg.t * leg.t * (3.0 - 2.0 * leg.t)
			leg.foot = (leg.from as Vector3).lerp(leg.to, e) + Vector3.UP * sin(leg.t * PI) * step_height * size
			bob += sin(leg.t * PI)
			if leg.t >= 1.0 and leg.set == 0 and moving > 1.0 and not _step_audio.playing:
				_step_audio.pitch_scale = randf_range(0.85, 1.2)
				_step_audio.volume_db = -6.0
				_step_audio.play()
		feet_y += (to_sk * leg.foot).y

	# Body: settle to the feet's height, bob with the steps, pitch and roll.
	feet_y /= maxf(_legs.size(), 1)
	_lift = lerpf(_lift, feet_y - bob * 0.01, 1.0 - exp(-10.0 * delta))
	var breathe := sin(_t * 1.8) * 0.01
	_body_pose = Transform3D(Basis(Vector3.RIGHT, -_pitch) * Basis(Vector3.BACK, roll),
		Vector3(0.0, _lift + breathe + 0.1 * maxf(_pitch, 0.0), 0.0))
	# The rest pose is around the body's own origin; turn about that point.
	_body_pose = Transform3D(_body_pose.basis, _body_pose.origin + _body_rest.origin - _body_pose.basis * _body_rest.origin)
	_skeleton.set_bone_global_pose(_bones["body"], _body_pose * _body_rest)
	for leg in _legs:
		_solve_leg(leg, to_sk * (leg.foot as Vector3))


## Two-bone IK: bend the knee (up and out, as at rest) so the toe reaches `toe`
## (skeleton space).
func _solve_leg(leg: Dictionary, toe: Vector3) -> void:
	var hip: Vector3 = _body_pose * (leg.rest_hip as Vector3)
	var pole: Vector3 = _body_pose.basis * ((leg.rest_knee as Vector3) - (leg.rest_hip as Vector3))
	var knee := _two_bone(hip, toe, leg.l1, leg.l2, pole)
	var reach := hip + (toe - hip).normalized() * minf(hip.distance_to(toe), leg.l1 + leg.l2 - 0.001)
	_aim_bone(leg.hip, leg.hip_rest, hip, knee)
	_aim_bone(leg.shin, leg.shin_rest, knee, reach)


## Reaches each wrist for where the current action wants it (in the body's rest space,
## +Z its front and +X its left) and opens or snaps shut each claw's upper finger.
func _animate_arms(delta: float) -> void:
	var t := 1.0 - _state_timer / maxf(pinch_time if _state == State.PINCH else throw_time, 0.01)
	for side: String in ["l", "r"]:
		var arm: Dictionary = _arms[side]
		var s := 1.0 if side == "l" else -1.0
		var rest: Vector3 = arm.rest
		var active := side == _claw
		var rate := 6.0
		# Held a little off the ground, swaying, clacking now and then.
		var want := rest + Vector3(0.0, 0.04 * sin(_t * 1.3 + s), 0.0)
		var point: Vector3 = arm.rest_point
		var open := 0.3 * pow(maxf(sin(_t * 1.7 + s * 2.0), 0.0), 12.0)
		match _state:
			State.HUNT:
				# Raised and ready, snapping at them.
				want = rest + Vector3(-s * 0.05, 0.22, 0.08)
				point = point + Vector3(0.0, 0.4, 0.0)
				open = 0.45 * maxf(sin(_t * 7.0 + s * 1.5), 0.0)
			State.WINDUP:
				want = rest + (Vector3(s * 0.12, 0.55, -0.15) if active else Vector3(-s * 0.05, 0.15, 0.05))
				point = Vector3(s * 0.2, 0.8, 0.5) if active else point
				open = 0.9 if active else 0.1
				rate = 9.0
			State.PINCH:
				if active:
					want = (rest + Vector3(s * 0.12, 0.55, -0.15)).lerp(Vector3(s * 0.25, 0.6, 1.45), smoothstep(0.0, 0.6, t))
					point = Vector3(-s * 0.15, -0.1, 1.0)
					open = 0.9 * (1.0 - smoothstep(0.2, 0.5, t)) - 0.05
					rate = 30.0
				else:
					want = rest + Vector3(-s * 0.05, 0.15, 0.05)
			State.RECOVER:
				want = rest + Vector3(0.0, 0.1, 0.15)
				rate = 4.0
			State.THROW_WINDUP:
				if active:
					# Up to the lantern, closing on its string as the wind-up ends.
					want = _skeleton.get_bone_global_rest(_bones["lantern_%d" % _lantern]).origin + Vector3(0.0, -0.15, 0.1)
					point = Vector3(0.0, 1.0, 0.2)
					open = 0.7 * (1.0 - smoothstep(0.6, 0.9, 1.0 - _state_timer / throw_windup))
					rate = 7.0
				else:
					want = rest + Vector3(0.0, 0.15, 0.0)
			State.THROW:
				if active:
					want = Vector3(s * 0.35, 1.0, 1.2)
					point = Vector3(0.0, 0.5, 1.0)
					open = 0.8
					rate = 25.0
		if _wake > 0.0:
			want += Vector3(s * 0.1, 0.5, 0.1) * sin(_wake / 0.8 * PI)
			point = Vector3(s * 0.2, 1.0, 0.3)
			open = 0.8 * absf(sin(_t * 14.0 + s))
		arm.wrist = (arm.wrist as Vector3).lerp(want, 1.0 - exp(-rate * delta))
		arm.point = (arm.point as Vector3).lerp(point.normalized(), 1.0 - exp(-rate * delta)).normalized()
		arm.open = lerpf(arm.open, open, 1.0 - exp(-(30.0 if _state == State.PINCH else 14.0) * delta))
		var root: Vector3 = _body_pose * (arm.root as Vector3)
		var target: Vector3 = _body_pose * (arm.wrist as Vector3)
		var lengths: Array = arm.lengths
		var end := root + (target - root).normalized() * minf(root.distance_to(target), lengths[0] + lengths[1] - 0.001)
		var elbow := _two_bone(root, end, lengths[0], lengths[1], _body_pose.basis * (arm.pole as Vector3))
		_aim_bone(arm.bones[0], arm.rests[0], root, elbow)
		_aim_bone(arm.bones[1], arm.rests[1], elbow, end)
		_aim_bone(arm.claw, arm.claw_rest, end, end + _body_pose.basis * (arm.point as Vector3))
		_turn(arm.pincer, Quaternion(arm.hinge, arm.open))


## The hat and lanterns on springs: they swing against the body's lurches and turns, and
## the lanterns hang straight down as it rears and dips.
func _animate_springs(delta: float) -> void:
	var v := velocity
	var a := global_basis.inverse() * (v - _last_velocity) / maxf(delta, 0.001)
	_last_velocity = v
	var accel := Vector2(-a.z, a.x)  # in the model's space, turned half round from this node's
	for i in LANTERNS:
		# Swinging about X by +angle moves a lantern back, about Z toward its left.
		var breeze := Vector2(sin(_t * 1.1 + i * 2.3), sin(_t * 1.6 + i)) * 0.03
		var force := accel * 0.05 + (Vector2(_pitch, 0.0) - _lantern_p[i]) * 30.0 - _lantern_v[i] * 2.5
		_lantern_v[i] += force * delta
		_lantern_p[i] = (_lantern_p[i] + _lantern_v[i] * delta).limit_length(1.2)
		var bone: int = _bones["lantern_%d" % i]
		var sway := _lantern_p[i] + breeze
		_turn(bone, Quaternion(Vector3.RIGHT, sway.x) * Quaternion(Vector3.BACK, sway.y))
		_skeleton.set_bone_pose_scale(bone, Vector3.ONE * maxf(_lantern_size[i] * _lantern_size[i], 0.001))
	_hat_v += (accel * 0.015 - _hat_p * 60.0 - _hat_v * 6.0) * delta
	_hat_p = (_hat_p + _hat_v * delta).limit_length(0.4)
	var wobble := _hat_p + Vector2(sin(_t * 0.9), sin(_t * 1.3)) * 0.02
	_turn(_bones["hat"], Quaternion(Vector3.RIGHT, wobble.x * 0.5) * Quaternion(Vector3.BACK, wobble.y * 0.5))
	_turn(_bones["hat_tip"], Quaternion(Vector3.RIGHT, wobble.x) * Quaternion(Vector3.BACK, wobble.y))


## The middle joint of a two-bone chain from `root` reaching for `target`, bent toward
## `pole`.
static func _two_bone(root: Vector3, target: Vector3, l1: float, l2: float, pole: Vector3) -> Vector3:
	var d := target - root
	var dist := clampf(d.length(), absf(l1 - l2) + 0.001, l1 + l2 - 0.001)
	var dir := d.normalized()
	var a := (l1 * l1 - l2 * l2 + dist * dist) / (2.0 * dist)
	var h := sqrt(maxf(l1 * l1 - a * a, 0.0))
	var side := (pole - dir * pole.dot(dir)).normalized()
	return root + dir * a + side * h


## Poses a bone at `from` pointing (its +Y) at `to`, turned from its rest orientation
## (carried along by the body) by the shortest rotation.
func _aim_bone(bone: int, rest: Transform3D, from: Vector3, to: Vector3) -> void:
	var base := (_body_pose.basis * rest.basis).orthonormalized()
	var want := (to - from).normalized()
	var turn := Quaternion(base.y.normalized(), want) if base.y.normalized().dot(want) > -0.999 else Quaternion.IDENTITY
	_skeleton.set_bone_global_pose(bone, Transform3D(Basis(turn) * base, from))


## Turns a bone from its rest pose by `turn`, given in skeleton space.
func _turn(bone: int, turn: Quaternion) -> void:
	var g := _skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion()
	var rest := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
	_skeleton.set_bone_pose_rotation(bone, rest * (g.inverse() * turn * g))


func _ground_at(space: PhysicsDirectSpaceState3D, p: Vector3) -> float:
	var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 1.5, p + Vector3.DOWN * 2.5, 1, [get_rid()])
	var hit := space.intersect_ray(q)
	return hit.position.y if hit else global_position.y
