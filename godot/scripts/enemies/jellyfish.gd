class_name Jellyfish
extends CharacterBody3D
## The jellyfish (assets/enemies/enemy_jellyfish.glb): a big pink-and-blue jellyfish that
## swims through the air over the island. It's harmless, like the arcane eye: no aggro
## ring, health or attack. It's solid to shots, which just stop on its bell, and stays off
## the minimap.
##
## It drifts slowly between spots near home, `hover_height` above whatever is below (or
## above `floor_min`, so over the sea it keeps above the water), but swims the way a
## jellyfish does, in pulses: every `pulse_period` seconds its bell squeezes in and
## stretches tall, it surges up and on toward where it's heading, then the bell relaxes
## open as it glides and slowly sinks. It tips into its drift, sways and turns slowly
## round as it goes, and a soft violet light round it brightens with each pulse.
##
## Its hangings are rigged (see enemy_jellyfish in the asset generator): each oral arm
## and tentacle is a chain of bones, simulated here as a rope (HangingRopes). They stream
## and trail behind its surges, bunch as it rises and spread as it sinks, and the long
## tentacles waft in a faint breeze. The bell pulses by scaling its `bell` bone.

const MODEL := preload("res://assets/enemies/enemy_jellyfish.glb")
const LIGHT_COLOR := Color(0.75, 0.45, 1.0)
## The furthest any segment of a hanging swings from straight down (radians).
const MAX_SWING := deg_to_rad(75.0)
## A light pull on the hangings: they float, trailing rather than dropping.
const HANGING_PULL := Vector3.DOWN * 4.0
## The bell squeezed in at the height of a pulse: across, and tall.
const SQUEEZE := Vector2(0.8, 1.15)
## Share of each pulse spent squeezing; the rest it relaxes and glides.
const SQUEEZE_SHARE := 0.22

@export var model_scale := 1.0
@export var speed := 0.8
## How high its bell's rim floats above whatever is below.
@export var hover_height := 4.2
## The lowest ground it hovers over (the island sets the sea's surface, so out over the
## water it stays above the waves, not the sea bed).
@export var floor_min := -1000.0
## It stays within this far of where it started (across the ground).
@export var wander_radius := 20.0
@export var pulse_period := 2.6

## Where it may drift to: (world point) -> bool. Set by the level; by default anywhere
## within wander_radius of home.
var can_hover: Callable

var _home := Vector3.ZERO
var _target := Vector3.ZERO
var _wander_timer := 0.0
var _t := 0.0
var _pulse := 0.0
var _model: Node3D
var _skeleton: Skeleton3D
var _bell := -1
var _light: OmniLight3D
var _ropes: HangingRopes


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	collision_layer = Enemy.ENEMY_LAYER  # shots stop on it
	collision_mask = 1
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.75 * model_scale
	shape.shape = sphere
	shape.position.y = 0.35 * model_scale
	add_child(shape)

	_model = MODEL.instantiate()
	_model.scale = Vector3.ONE * model_scale
	add_child(_model)
	# Kept out of the minimap's snapshot of the level, like the enemies.
	for g: GeometryInstance3D in _model.find_children("*", "GeometryInstance3D", true, false):
		g.layers = Enemy.ENEMY_VISUAL_LAYER

	_light = OmniLight3D.new()
	_light.light_color = LIGHT_COLOR
	_light.omni_range = 5.0
	_light.position = Vector3(0.0, 0.2 * model_scale, 0.0)
	add_child(_light)

	_home = global_position
	_target = global_position
	_t = randf() * 10.0
	_pulse = randf()
	var found := _model.find_children("*", "Skeleton3D", true, false)
	if not found.is_empty():
		_skeleton = found[0]
		_bell = _skeleton.find_bone("bell")
		_setup_ropes.call_deferred()  # once it's in place in the world


func _physics_process(delta: float) -> void:
	_t += delta
	_wander_timer -= delta
	if _wander_timer <= 0.0 or Vector2(_target.x - global_position.x, _target.z - global_position.z).length() < 1.0:
		_pick_target()

	var to := _target - global_position
	to.y = 0.0
	var ahead := to.normalized() if to.length() > 0.1 else Vector3.ZERO

	# Each pulse starts with a surge up and on toward where it's heading.
	var was := _pulse
	_pulse = fmod(_pulse + delta / pulse_period, 1.0)
	if _pulse < was:
		var target_y := maxf(_ground_y(), floor_min) + hover_height
		var lift := clampf(1.0 + (target_y - global_position.y) * 0.6, 0.2, 1.8)
		velocity += Vector3.UP * lift + ahead * speed * 1.2

	# Between surges the air (water, really) slows it, and it settles back toward a gentle
	# drift and a slow sink.
	var drift := ahead * speed * 0.3 + Vector3.DOWN * 0.25
	velocity = velocity.lerp(drift, 1.0 - exp(-1.2 * delta))
	move_and_slide()

	# Tips into its drift (forward speed, in this node's frame), sways and turns slowly.
	rotation.y += delta * 0.15
	var local_v := global_basis.inverse() * velocity
	_model.rotation = Vector3(clampf(-local_v.z * 0.15, -0.3, 0.3) + sin(_t * 0.7) * 0.05, 0.0,
		clampf(local_v.x * 0.15, -0.3, 0.3) + sin(_t * 0.55) * 0.05)

	# The bell squeezes in quickly at the start of a pulse and relaxes open over the rest.
	var squeeze := smoothstep(0.0, 1.0, _pulse / SQUEEZE_SHARE) if _pulse < SQUEEZE_SHARE \
		else 1.0 - smoothstep(SQUEEZE_SHARE, 1.0, _pulse)
	if _bell >= 0:
		_skeleton.set_bone_pose_scale(_bell, Vector3(lerpf(1.0, SQUEEZE.x, squeeze), lerpf(1.0, SQUEEZE.y, squeeze),
			lerpf(1.0, SQUEEZE.x, squeeze)))
	_light.light_energy = 0.6 + 0.6 * squeeze
	if _ropes:
		_ropes.step(delta, _t)


## Starts the oral arms (arm_<k>_<j>) and tentacles (tentacle_<k>_<j>) hanging at rest.
## The arms are heavier and a little stiff; the tentacles waft freely in the breeze.
func _setup_ropes() -> void:
	_ropes = HangingRopes.new(_skeleton, MAX_SWING, HANGING_PULL)
	_ropes.add_named("arm_", 0.5, 1.4, 0.25)
	_ropes.add_named("tentacle_", 0.15, 0.9, 0.6)


func _pick_target() -> void:
	var allowed := can_hover if can_hover.is_valid() else func(_p: Vector3) -> bool: return true
	for i in 24:
		var a := randf() * TAU
		var p := global_position + Vector3(cos(a), 0.0, sin(a)) * randf_range(4.0, 10.0)
		if Vector2(p.x - _home.x, p.z - _home.z).length() < wander_radius and allowed.call(p):
			_target = p
			_wander_timer = randf_range(8.0, 16.0)
			return
	_target = _home  # nowhere new: drift back home
	_wander_timer = 6.0


func _ground_y() -> float:
	var from := global_position + Vector3.UP
	var q := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 40.0, 1, [get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(q)
	return hit.position.y if hit else global_position.y - hover_height
