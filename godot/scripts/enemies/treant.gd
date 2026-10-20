class_name Treant
extends Enemy
## The treant (assets/enemies/enemy_treant.glb): a walking stump with glowing eyes and
## long hooked claws, haunting the woods. Left alone it mostly stands rooted, still as a
## stump with its eyes and grin dimmed to embers, only its leaves stirring; now and
## then it lumbers off a few meters to root somewhere else. It's easy to walk up on.
##
## Once aggroed (Enemy: the player inside its ring and in sight, or a shot) its eyes
## flare, it shakes itself awake with a creaking groan and lumbers after them, slower
## than they can run. It has two attacks:
##   * the rake, within `rake_range`: it rears up with both arms raised and claws
##     spread (`rake_windup`, glowing), then lunges and rakes both claws down through
##     the space in front of it. A player in front of it and in reach takes
##     `rake_damage` and is knocked back (one hit per rake).
##   * the slam, from `slam_range` away and in sight, every `slam_cooldown` seconds: it
##     raises both claws high over its head (`slam_windup`), drives them into the ground
##     and holds them there while roots (TreantRoots) burst up under where the player
##     was heading, after a short warning.
## When killed it bursts into splinters, leaves and embers (loot and respawning come
## from Enemy).
##
## It's animated procedurally on its rig (see enemy_treant in the asset generator). The
## walk cycle advances with the distance covered: its short legs swing from the hip,
## each knee lifting as it comes through, and it rocks heavily from foot to foot with a
## thud at each step. The arms are posed by reaching each wrist for a target (two-bone
## IK): hanging and swinging against the legs as it walks, flung up for a wind-up and
## down for a blow, and the claws spread and clench. The leaves on its sprouts sway on
## springs, swinging with every lurch and stirring in the breeze.

const MODEL := preload("res://assets/enemies/enemy_treant.glb")
const SOUNDS := {
	"alert": preload("res://assets/sfx/treant_alert.wav"),
	"charge": preload("res://assets/sfx/treant_charge.wav"),
	"swipe": preload("res://assets/sfx/treant_swipe.wav"),
	"hit": preload("res://assets/sfx/treant_hit.wav"),
	"slam": preload("res://assets/sfx/treant_slam.wav"),
	"hurt": preload("res://assets/sfx/treant_hurt.wav"),
	"die": preload("res://assets/sfx/treant_die.wav"),
}
const STEP_SOUND := preload("res://assets/sfx/treant_step.wav")
const GLOW := preload("res://materials/ps1_glow.tres")
const CHARGE_COLOR := Color(1.0, 0.45, 0.1)
## The glow material's emission when dormant, awake and fully charged.
const EMBER := 0.25
const AWAKE := 1.2
const BLAZE := 3.0
## Meters (model units) covered per full walk cycle (two steps).
const CYCLE_LENGTH := 0.7
const LEG_SWING := 0.38
const KNEE_LIFT := 0.6
## Body bob (model units) and roll (radians) while walking.
const BOB := 0.04
const ROLL := 0.1
const SPROUTS := 3

@export var walk_speed := 0.8
@export var hunt_speed := 2.6
@export var turn_speed := 3.0
## It stays within this far of where it started (across the ground).
@export var wander_radius := 14.0
## How far each wander goes, at least and at most.
@export var walk_distance := Vector2(3.0, 8.0)
## Seconds it stands rooted between wanders.
@export var idle_time := Vector2(6.0, 14.0)

@export_group("Rake")
@export var rake_range := 2.3
@export var rake_windup := 0.6
@export var rake_time := 0.35
@export var rake_recover := 0.55
@export var rake_cooldown := Vector2(0.8, 1.5)
@export var rake_damage := 24.0
## Reach of the claws (across the ground from its middle) and their sweep either side.
@export var rake_reach := 2.6
@export var rake_arc := 70.0
## How hard a hit knocks the player back (m/s).
@export var rake_push := 6.0

@export_group("Slam")
## It slams when the player is between these distances (across the ground).
@export var slam_range := Vector2(4.5, 14.0)
@export var slam_windup := 0.8
@export var slam_hold := 0.9
@export var slam_cooldown := Vector2(5.0, 8.0)
@export var roots_damage := 20.0
@export var roots_radius := 1.4

## Where it may go: (world point) -> bool. Set by the level; by default anywhere within
## wander_radius of home.
var can_stand: Callable

enum State { IDLE, MOVE, HUNT, WINDUP, RAKE, RECOVER, SLAM_UP, SLAM_DOWN, SLAM_HOLD }

var _state := State.IDLE
var _state_timer := 0.0
var _target := Vector3.ZERO
var _stuck_timer := 0.0
var _stuck_from := Vector3.ZERO
var _rake_timer := 0.0
var _slam_timer := 0.0
var _hit_done := false
var _gravity: float = ProjectSettings.get_setting("physics/3d/default_gravity")

## The eyes and grin: its own copy of the glow material, so it can dim and flare them.
var _glow_mat: ShaderMaterial
var _glow := EMBER
## Wind-up glow, 0 to 1.
var _charge := 0.0
## Shaking itself awake (seconds left).
var _wake := 0.0

var _skeleton: Skeleton3D
var _bones := {}
## Per arm: bones, rest points (skeleton space) and segment lengths, and the current
## wrist target, eased toward the pose it wants.
var _arms := {}
var _phase := 0.0
var _moving := 0.0
var _step_side := 0
var _lean := 0.0
var _crouch := 0.0
var _roll := 0.0
## Per sprout: spring offset and velocity (radians about the model's X and Z).
var _sprout_p: Array[Vector2] = []
var _sprout_v: Array[Vector2] = []
var _last_velocity := Vector3.ZERO
var _step_audio: AudioStreamPlayer3D
var _strike_audio: AudioStreamPlayer3D


func _init() -> void:
	max_health = 170.0
	knockback = 0.05
	model_scale = 1.15
	aggro_radius = 6.0
	loot_drops = Vector2i(1, 3)
	gem_drops = 2


func _ready() -> void:
	floor_snap_length = 0.3
	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.5 * model_scale
	capsule.height = 1.5 * model_scale
	shape.shape = capsule
	shape.position.y = 0.8 * model_scale
	add_child(shape)
	_setup(MODEL, SOUNDS)
	_model.rotation.y = PI  # the model faces its +Z; this node faces -Z
	add_to_group("treants")
	_step_audio = AudioStreamPlayer3D.new()
	_step_audio.stream = STEP_SOUND
	_step_audio.unit_size = 5.0
	_step_audio.max_polyphony = 2
	add_child(_step_audio)
	# The hit lands over the swipe's whoosh, so it gets its own player.
	_strike_audio = AudioStreamPlayer3D.new()
	_strike_audio.unit_size = 6.0
	add_child(_strike_audio)
	_glow_mat = GLOW.duplicate()
	for m: GeometryInstance3D in _meshes:
		var mi := m as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			if mi.get_active_material(i) == GLOW:
				mi.set_surface_override_material(i, _glow_mat)
	_state_timer = randf_range(idle_time.x, idle_time.y) * 0.5
	_setup_rig()


func _eye_point() -> Vector3:
	return global_position + Vector3.UP * 1.0 * model_scale


func _physics_process(delta: float) -> void:
	if dead:
		return
	_t += delta
	_hurt_cooldown -= delta
	_rake_timer -= delta
	_slam_timer -= delta
	_wake = maxf(_wake - delta, 0.0)
	_update_awareness(delta)
	if alerted and _state in [State.IDLE, State.MOVE]:
		_state = State.HUNT

	var desired := Vector3.ZERO
	var face_player := false
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
		State.HUNT:
			if not alerted:
				_stop()
			elif _wake > 0.0:
				face_player = true  # shaking itself awake first
			elif dist < rake_range and _rake_timer <= 0.0 and is_on_floor():
				_start(State.WINDUP, rake_windup, "charge")
			elif dist > slam_range.x and dist < slam_range.y and _slam_timer <= 0.0 and is_on_floor() \
					and _line_of_sight():
				_start(State.SLAM_UP, slam_windup, "charge")
			else:
				# Lumbers in, or waits just out of reach for its claws to be ready again.
				var stand_off := 0.0 if _rake_timer <= 0.0 else rake_range * 0.8
				desired = dir * hunt_speed * clampf((dist - stand_off) * 1.5, -0.5, 1.0)
				face_player = true
				if desired.length() > 0.01 and can_stand.is_valid() \
						and not can_stand.call(global_position + desired.normalized() * 0.8):
					desired = Vector3.ZERO
		State.WINDUP:
			face_player = true
			_charge = move_toward(_charge, 1.0, delta / rake_windup)
			if _state_timer <= 0.0:
				_start(State.RAKE, rake_time, "swipe")
				_hit_done = false
		State.RAKE:
			# Lunges into the blow, the claws sweeping through in the middle of it.
			var t := 1.0 - _state_timer / rake_time
			desired = -global_basis.z * 2.0 * sin(PI * clampf(t, 0.0, 1.0))
			if not _hit_done and t > 0.3 and t < 0.8:
				_check_rake_hit()
			if _state_timer <= 0.0:
				_state = State.RECOVER
				_state_timer = rake_recover
		State.RECOVER:
			face_player = alerted
			if _state_timer <= 0.0:
				_rake_timer = randf_range(rake_cooldown.x, rake_cooldown.y)
				_after_attack()
		State.SLAM_UP:
			face_player = true
			_charge = move_toward(_charge, 1.0, delta / slam_windup)
			if _state_timer <= 0.0:
				_state = State.SLAM_DOWN
				_state_timer = 0.16
		State.SLAM_DOWN:
			if _state_timer <= 0.0:
				_slam()
				_state = State.SLAM_HOLD
				_state_timer = slam_hold
		State.SLAM_HOLD:
			if _state_timer <= 0.0:
				_slam_timer = randf_range(slam_cooldown.x, slam_cooldown.y)
				_state = State.RECOVER
				_state_timer = rake_recover

	if _state not in [State.WINDUP, State.SLAM_UP]:
		_charge = move_toward(_charge, 0.0, delta * 2.5)

	var attacking := _state in [State.WINDUP, State.RAKE, State.RECOVER, State.SLAM_UP, State.SLAM_DOWN, State.SLAM_HOLD]
	var hv := Vector3(velocity.x, 0.0, velocity.z).lerp(desired, 1.0 - exp(-(8.0 if attacking else 4.0) * delta))
	velocity.x = hv.x
	velocity.z = hv.z
	velocity.y = 0.0 if is_on_floor() else velocity.y - _gravity * delta
	var before := global_position
	move_and_slide()
	if face_player and _player:
		_face(to_player, delta, 6.0 if _state in [State.WINDUP, State.SLAM_UP] else turn_speed)
	elif hv.length() > 0.05 and _state == State.MOVE:
		_face(hv, delta, turn_speed)
	var moved := Vector2(global_position.x - before.x, global_position.z - before.z).length()

	# Eyes: embers while it stands dormant, lit while it's awake, blazing as it winds up.
	var want := EMBER if not alerted and _state in [State.IDLE, State.MOVE] else AWAKE
	_glow = lerpf(_glow, want + (BLAZE - AWAKE) * _charge, 1.0 - exp(-4.0 * delta))
	_glow_mat.set_shader_parameter("emission_strength", _glow)
	_flash_amount = move_toward(_flash_amount, 0.0, delta * 6.0)
	_set_glow(CHARGE_COLOR, maxf(_flash_amount, _charge * 0.25))
	_animate(delta, moved / model_scale)


## Wandering toward its target; stops on arrival or when it gets stuck.
func _wander_velocity(delta: float) -> Vector3:
	var to := _target - global_position
	to.y = 0.0
	var dist := to.length()
	if dist < 0.5 or (can_stand.is_valid() and not can_stand.call(global_position + to / dist * 0.8)):
		_stop()
		return Vector3.ZERO
	_stuck_timer -= delta
	if _stuck_timer <= 0.0:
		if global_position.distance_to(_stuck_from) < 0.3:
			_stop()  # walked into something; it'll root here
			return Vector3.ZERO
		_stuck_timer = 1.5
		_stuck_from = global_position
	return to / dist * walk_speed


## Lumbers off somewhere nearby. Returns false if there was nowhere to go (or it's busy
## hunting the player).
func set_out() -> bool:
	if dead or _state not in [State.IDLE, State.MOVE]:
		return false
	var allowed := can_stand if can_stand.is_valid() else func(_p: Vector3) -> bool: return true
	for i in 32:
		var a := randf() * TAU
		var p := global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(walk_distance.x, walk_distance.y)
		if Vector2(p.x - _home.x, p.z - _home.z).length() < wander_radius and allowed.call(p):
			_target = p
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
		_wake = 0.7


func _on_lost_sight() -> void:
	if _state == State.HUNT:
		_stop()
	elif _state in [State.WINDUP, State.SLAM_UP]:
		_state = State.RECOVER  # calls off the blow
		_state_timer = rake_recover


# ---------------------------------------------------------------------------
# Attacks
# ---------------------------------------------------------------------------
## Lands the rake if the player is in front of it and in reach of its claws.
func _check_rake_hit() -> void:
	if _player == null or _player.get("dead"):
		return
	var off := _player.global_position - global_position
	var flat := Vector3(off.x, 0.0, off.z)
	if flat.length() > rake_reach or off.y > 2.0 or off.y < -1.5:
		return
	if rad_to_deg((-global_basis.z).angle_to(flat)) > rake_arc and flat.length() > 0.8:
		return
	_hit_done = true
	var dir := flat.normalized()
	_player.take_damage(rake_damage, _player.global_position + Vector3.UP, dir)
	if _player is CharacterBody3D:
		(_player as CharacterBody3D).velocity += dir * rake_push + Vector3.UP * 2.5
	_strike_audio.stream = _sounds["hit"]
	_strike_audio.volume_db = 4.0
	_strike_audio.pitch_scale = randf_range(0.9, 1.1)
	_strike_audio.play()
	var sparks := FX.burst(CHARGE_COLOR, 10, 3.5, 0.06, 0.4, -9.8, 2.0)
	get_parent().add_child(sparks)
	sparks.global_position = _player.global_position + Vector3.UP * 1.1
	sparks.emitting = true
	get_tree().create_timer(1.0).timeout.connect(sparks.queue_free)


## Claws into the ground: a thud and a spray of dirt at its feet, and roots on their
## way up under where the player is heading.
func _slam() -> void:
	_play("slam", 5.0)
	var dirt := FX.burst(Color(0.29, 0.21, 0.16), 24, 4.0, 0.12, 0.7, -9.8, 0.7)
	get_parent().add_child(dirt)
	dirt.global_position = global_position - global_basis.z * 0.7 * model_scale + Vector3.UP * 0.1
	dirt.emitting = true
	get_tree().create_timer(1.2).timeout.connect(dirt.queue_free)
	if _player == null or _player.get("dead"):
		return
	var aim := _player.global_position
	if _player is CharacterBody3D:
		var v := (_player as CharacterBody3D).velocity
		aim += Vector3(v.x, 0.0, v.z) * 0.45
	var roots := TreantRoots.new()
	roots.radius = roots_radius
	roots.damage = roots_damage
	get_parent().add_child(roots)
	var from := aim + Vector3.UP * 2.0
	# The player's body is on the world layer too: look past it for the ground.
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 30.0, 1, [_player.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	roots.global_position = hit.position if hit else Vector3(aim.x, _player.global_position.y, aim.z)


func _on_death() -> void:
	_state = State.IDLE
	_charge = 0.0
	for c in [Color(0.36, 0.25, 0.19), Color(0.5, 0.38, 0.28), Color(0.44, 0.72, 0.23), CHARGE_COLOR]:
		var puff := FX.burst(c, 18, 5.0, 0.12, 1.0, -9.8, 3.0 if c == CHARGE_COLOR else 0.7)
		add_child(puff)
		puff.position.y = 0.9 * model_scale
		puff.emitting = true
		get_tree().create_timer(1.3).timeout.connect(puff.queue_free)


func _on_respawn() -> void:
	_stop()
	_glow = EMBER


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
	var rest := func(bone: String) -> Vector3: return _skeleton.get_bone_global_rest(_bones[bone]).origin
	for side in ["l", "r"]:
		var shoulder: Vector3 = rest.call("arm_%s_0" % side)
		var elbow: Vector3 = rest.call("arm_%s_1" % side)
		var wrist: Vector3 = rest.call("hand_%s" % side)
		_arms[side] = {
			"bones": [_bones["arm_%s_0" % side], _bones["arm_%s_1" % side]],
			"root": shoulder, "rest": wrist, "wrist": wrist,
			"lengths": [shoulder.distance_to(elbow), elbow.distance_to(wrist)],
			"pole": elbow - (shoulder + wrist) * 0.5,  # bent outward as at rest
		}
	for k in SPROUTS:
		_sprout_p.append(Vector2.ZERO)
		_sprout_v.append(Vector2.ZERO)


func _animate(delta: float, moved: float) -> void:
	if _skeleton == null:
		return
	var walking := _state in [State.MOVE, State.HUNT] and moved > 0.001
	_moving = move_toward(_moving, 1.0 if walking else 0.0, delta * 3.0)
	_phase = fmod(_phase + moved / CYCLE_LENGTH, 1.0)
	var phi := _phase * TAU
	# A thud each time a foot comes down (twice a cycle).
	var side := 0 if _phase < 0.5 else 1
	if side != _step_side:
		_step_side = side
		if _moving > 0.5:
			_step_audio.pitch_scale = randf_range(0.85, 1.05)
			_step_audio.volume_db = -2.0
			_step_audio.play()

	# Body: lean and crouch for the attacks, the waddle's bob and roll, and a shake as
	# it wakes.
	var lean := 0.0
	var crouch := 0.0
	match _state:
		State.WINDUP:
			lean = -0.18
			crouch = 0.04
		State.RAKE:
			lean = 0.3
			crouch = 0.08
		State.SLAM_UP:
			lean = -0.22
		State.SLAM_DOWN, State.SLAM_HOLD:
			lean = 0.42
			crouch = 0.14
	_lean = lerpf(_lean, lean, 1.0 - exp(-(14.0 if _state in [State.RAKE, State.SLAM_DOWN] else 6.0) * delta))
	_crouch = lerpf(_crouch, crouch, 1.0 - exp(-10.0 * delta))
	var shake := sin(_t * 40.0) * 0.06 * (_wake / 0.7)
	_roll = sin(phi) * ROLL * _moving + shake
	var breath := sin(_t * 0.9) * 0.012
	# Pitching about X by +angle tips the model's front (the node's -Z) down: it's turned
	# half round. Position and rotation are set apart from scale, which Enemy tweens on
	# respawn.
	_model.rotation = Vector3(_lean + 0.05 * _moving, PI, _roll)
	_model.position = Vector3(0.0, (-BOB * absf(cos(phi)) * _moving - _crouch + breath) * model_scale, 0.0)

	for leg in ["l", "r"]:
		var p := phi if leg == "l" else phi + PI
		var swing := LEG_SWING * sin(p) * _moving
		var bend := KNEE_LIFT * maxf(cos(p), 0.0) * _moving + _crouch * 3.0
		_turn("leg_%s_0" % leg, Quaternion(Vector3.RIGHT, -swing - _crouch * 1.5))
		_turn("leg_%s_1" % leg, Quaternion(Vector3.RIGHT, bend))
		_turn("foot_%s" % leg, Quaternion(Vector3.RIGHT, swing - bend + _crouch * 1.5 - _lean))
	_animate_arms(delta, phi)
	_animate_sprouts(delta)


## Reaches each wrist for where the current action wants it, and spreads or clenches
## the claws.
func _animate_arms(delta: float, phi: float) -> void:
	var rate := 6.0
	var spread := 0.0
	var t := 1.0 - _state_timer / maxf(rake_time, 0.01)
	for side in ["l", "r"]:
		var arm: Dictionary = _arms[side]
		var s := 1.0 if side == "l" else -1.0
		var rest: Vector3 = arm.rest
		var p := phi + (PI if side == "l" else 0.0)  # against the leg on its side
		# Hanging, swinging as it walks and swaying a little when it stands.
		var want := rest + Vector3(0.0, 0.05 * absf(sin(p)) * _moving, 0.16 * sin(p) * _moving) \
			+ Vector3(0.0, 0.0, sin(_t * 0.8 + s) * 0.02)
		match _state:
			State.HUNT:
				# Claws held a little forward and up, ready.
				want += Vector3(-s * 0.05, 0.12, 0.18) * (1.0 - _moving * 0.5)
			State.WINDUP:
				want = Vector3(s * 0.6, 1.5, -0.2)
				spread = 1.0
				rate = 8.0
			State.RAKE:
				# Down through the front, crossing in.
				want = Vector3(s * 0.62, 1.4, -0.1).lerp(Vector3(s * 0.15, 0.45, 0.65), smoothstep(0.0, 0.7, t))
				spread = 1.0 - t
				rate = 30.0
			State.RECOVER:
				want = rest + Vector3(-s * 0.1, 0.1, 0.3)
				spread = -0.6
				rate = 4.0
			State.SLAM_UP:
				want = Vector3(s * 0.22, 1.62, 0.05)
				spread = 0.7
				rate = 7.0
			State.SLAM_DOWN, State.SLAM_HOLD:
				want = Vector3(s * 0.3, 0.05, 0.62)
				spread = -0.3
				rate = 35.0
		if _wake > 0.0:
			want += Vector3(s * 0.15, 0.25, 0.1) * sin(_wake / 0.7 * PI)
		arm.wrist = (arm.wrist as Vector3).lerp(want, 1.0 - exp(-rate * delta))
		_reach(arm, arm.wrist)
		# Claws: spread fans them apart, below zero clenches them shut.
		for k in 4:
			var o := 1.0 - k if k < 3 else -1.5
			var bone: int = _bones["claw_%s_%d" % [side, k]]
			var rest_rot := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
			var fan := Quaternion(Vector3.FORWARD, o * 0.25 * maxf(spread, 0.0))
			var curl := Quaternion(Vector3.RIGHT, -0.5 * minf(spread, 0.0) + sin(_t * 1.1 + k + s) * 0.03)
			_skeleton.set_bone_pose_rotation(bone, rest_rot * fan * curl)


## Bends an arm so its wrist reaches `target` (skeleton space), as near as it can.
func _reach(arm: Dictionary, target: Vector3) -> void:
	var root: Vector3 = arm.root
	var lengths: Array = arm.lengths
	var dir := (target - root).normalized()
	var end := root + dir * minf(root.distance_to(target), lengths[0] + lengths[1] - 0.001)
	var joint := _two_bone(root, end, lengths[0], lengths[1], arm.pole)
	_aim(arm.bones[0], root, joint)
	_aim(arm.bones[1], joint, end)


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


## Poses a bone at `from` pointing (its +Y) at `to`, turned from its rest orientation by
## the shortest rotation.
func _aim(bone: int, from: Vector3, to: Vector3) -> void:
	var base := _skeleton.get_bone_global_rest(bone).basis.orthonormalized()
	var want := (to - from).normalized()
	var turn := Quaternion(base.y.normalized(), want) if base.y.normalized().dot(want) > -0.999 else Quaternion.IDENTITY
	_skeleton.set_bone_global_pose(bone, Transform3D(Basis(turn) * base, from))


## Sprouts on springs: they swing against the body's lurches and turns and stir in a
## breeze.
func _animate_sprouts(delta: float) -> void:
	var v := velocity
	var accel := global_basis.inverse() * (v - _last_velocity) / maxf(delta, 0.001)
	_last_velocity = v
	for k in SPROUTS:
		var breeze := Vector2(sin(_t * 1.3 + k * 2.1), sin(_t * 1.7 + k)) * 0.05
		# The node faces -Z: speeding up forward (accel.z < 0) throws the sprouts back.
		var force := Vector2(accel.z, -accel.x) * 0.05 + Vector2(_lean, _roll) * -6.0
		_sprout_v[k] += (force - _sprout_p[k] * 40.0 - _sprout_v[k] * 5.0) * delta
		_sprout_p[k] += _sprout_v[k] * delta
		_sprout_p[k] = _sprout_p[k].limit_length(0.6)
		var sway := _sprout_p[k] + breeze
		_turn("sprout_%d" % k, Quaternion(Vector3.RIGHT, sway.x) * Quaternion(Vector3.FORWARD, sway.y))


## Turns a bone from its rest pose by `turn`, given in skeleton space.
func _turn(bone_name: String, turn: Quaternion) -> void:
	var bone: int = _bones[bone_name]
	var g := _skeleton.get_bone_global_rest(bone).basis.get_rotation_quaternion()
	var rest := _skeleton.get_bone_rest(bone).basis.get_rotation_quaternion()
	_skeleton.set_bone_pose_rotation(bone, rest * (g.inverse() * turn * g))
