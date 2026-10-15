class_name Golem
extends Enemy
## The rock golem: a slow, heavy brute of mossy boulders with no legs, held up off the
## ground by an electric charge that crackles from its hips down to the ground
## (ElectricArcs), with a low electric hum. Once the player comes near it drifts
## after them. Out of reach it throws a ball of lightning; up close it gathers its
## charge and discharges it into the ground, a shock ring that hurts and throws back anyone nearby
## (and sets off gas cans and explosive barrels). Both are telegraphed: arcs crawl up
## its body, its crack and eyes glow and the buzz rises. Shots barely move it. When
## killed the charge bursts and it falls apart into rubble, leaving three gems.

const BOLT := preload("res://weapons/enemy_golem_bolt.tres")
const MODEL := preload("res://assets/enemies/enemy_golem.glb")
const HUM := preload("res://assets/sfx/golem_hum.wav")
const SOUNDS := {
	"alert": preload("res://assets/sfx/golem_alert.wav"),
	"charge": preload("res://assets/sfx/golem_charge.wav"),
	"fire": preload("res://assets/sfx/golem_fire.wav"),
	"shock": preload("res://assets/sfx/golem_shock.wav"),
	"hurt": preload("res://assets/sfx/golem_hurt.wav"),
	"die": preload("res://assets/sfx/golem_die.wav"),
}
const CHARGE_COLOR := Color(0.5, 0.85, 1.0)
## How far out the arcs under it land, in meters.
const ARC_SPREAD := 1.0
## Where the arcs leave the model, in its own space (+Z is its front, y up from its
## origin at the bottom of the hips): the undersides of the two hip boulders it would stand on...
const LEG_POINTS := [
	Vector3(-0.25, 0.04, 0.0), Vector3(-0.37, 0.12, 0.1), Vector3(-0.15, 0.12, -0.12),
	Vector3(0.25, 0.04, 0.0), Vector3(0.37, 0.12, 0.1), Vector3(0.15, 0.12, -0.12),
]
## ...and, while it gathers its charge, the rest of the body: arms, shoulders, chest.
const BODY_POINTS := [
	Vector3(-1.02, 0.88, 0.12), Vector3(1.02, 0.88, 0.12), Vector3(-1.0, 1.4, 0.05),
	Vector3(1.0, 1.4, 0.05), Vector3(-0.88, 1.95, 0.0), Vector3(0.88, 1.95, 0.0),
	Vector3(0.0, 1.65, 0.6), Vector3(0.0, 0.95, 0.4),
]

@export var speed := 2.2
## Gap between its lowest boulders and the ground.
@export var hover_height := 0.85
@export var preferred_distance := 2.5
## Closer than this it shocks; farther away it throws lightning.
@export var shock_range := 4.0
@export var shock_radius := 5.0
@export var shock_damage := 30.0
## How hard the shock throws the player back, in m/s at the center.
@export var shock_push := 9.0
@export var shock_cooldown := 2.5
@export var bolt_interval := Vector2(2.4, 3.6)
## Wind-up before each attack, so the player can react (the shock's is longer).
@export var bolt_telegraph := 0.7
@export var shock_telegraph := 0.9

var _arcs: ElectricArcs
var _hum: AudioStreamPlayer3D
## Height of the model, scaled.
var _height := 2.6
## How far the model is raised so its lowest point sits on this node's origin, unscaled.
var _lift := 0.0
## "" or the attack being wound up: "bolt" or "shock".
var _winding := ""
var _windup := 0.0
## 0..1 through a wind-up.
var _charge := 0.0
var _bolt_timer := 0.0
var _shock_timer := 0.0
## Extra arc intensity after a shock, dying away.
var _surge := 0.0
var _wander := Vector3.ZERO
var _wander_timer := 0.0


func _init() -> void:
	max_health = 320.0
	memory = 6.0
	respawn_time = 60.0
	model_scale = 1.15
	knockback = 0.02
	loot_drops = Vector2i(2, 3)
	gem_drops = 3


func _ready() -> void:
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	_setup(MODEL, SOUNDS)
	_model.rotation.y = PI  # the model faces +Z; this node "faces" -Z
	# Stand the model's lowest point on this node's origin.
	var box := AABB()
	for m: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false):
		var b := (_model.global_transform.affine_inverse() * m.global_transform) * m.get_aabb()
		box = b if box.size == Vector3.ZERO else box.merge(b)
	_lift = -box.position.y
	_model.position.y = _lift * model_scale
	_height = box.size.y * model_scale

	var shape := CollisionShape3D.new()
	var capsule := CapsuleShape3D.new()
	capsule.radius = 1.0 * model_scale
	capsule.height = _height
	shape.shape = capsule
	shape.position.y = _height / 2.0
	add_child(shape)

	_arcs = ElectricArcs.new()
	_arcs.color = CHARGE_COLOR
	_arcs.drop = hover_height
	_arcs.spread = ARC_SPREAD
	_arcs.sources = _points(LEG_POINTS)
	_arcs.climb_sources = _points(BODY_POINTS)
	add_child(_arcs)

	_hum = AudioStreamPlayer3D.new()
	_hum.stream = HUM
	_hum.unit_size = 3.0
	_hum.max_distance = 30.0
	_hum.volume_db = -8.0
	_hum.autoplay = true
	add_child(_hum)
	_bolt_timer = randf_range(bolt_interval.x, bolt_interval.y)


## Model-space points (see LEG_POINTS) in this node's space.
func _points(list: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	for p: Vector3 in list:
		out.append(Vector3(-p.x, p.y + _lift, -p.z) * model_scale)  # the model is turned around
	return out


func _eye_point() -> Vector3:
	return global_position + Vector3.UP * _height * 0.8


## Its chest, front and center, where the lightning is thrown from.
func _chest() -> Vector3:
	return global_position + Vector3.UP * _height * 0.6 - global_basis.z * 0.9 * model_scale


func _physics_process(delta: float) -> void:
	if dead:
		return
	_t += delta
	_hurt_cooldown -= delta
	_shock_timer -= delta
	_update_awareness(delta)

	var desired := Vector3.ZERO
	if alerted and _player:
		var to_player := _player.global_position - global_position
		var flat := Vector3(to_player.x, 0.0, to_player.z)
		var dist := flat.length()
		if _winding == "":
			var approach := clampf((dist - preferred_distance) * 0.5, -0.5, 1.0)
			desired = flat / maxf(dist, 0.01) * approach * speed
		_face(flat, delta, 2.0)
		_update_attack(delta, dist)
	else:
		_wander_timer -= delta
		if _wander_timer <= 0.0 or global_position.distance_to(_wander) < 1.0:
			var a := randf() * TAU
			_wander = _home + Vector3(cos(a), 0.0, sin(a)) * randf_range(2.0, 6.0)
			_wander_timer = randf_range(4.0, 8.0)
		var w := _wander - global_position
		w.y = 0.0
		desired = w.limit_length(1.0) * speed * 0.4
		if w.length() > 0.5:
			_face(w, delta, 1.2)

	# Float on the charge with a slow bob; it sinks a little as it gathers a shock.
	var ground := _ground_y()
	var sink := _charge * 0.35 if _winding == "shock" else 0.0
	var target_y := ground + hover_height - sink + sin(_t * 1.3) * 0.07
	desired.y = clampf((target_y - global_position.y) * 3.0, -3.0, 3.0)
	velocity = velocity.lerp(desired, 1.0 - exp(-2.5 * delta))
	move_and_slide()

	# Heavy, slow sway; arcs, hum and glow follow the charge.
	_model.rotation.x = sin(_t * 0.8) * 0.025
	_model.rotation.z = sin(_t * 0.6) * 0.03
	_surge = move_toward(_surge, 0.0, delta * 3.0)
	_arcs.drop = maxf(global_position.y - ground, 0.05)
	_arcs.intensity = 1.0 + _charge * 1.6 + _surge
	_hum.pitch_scale = 1.0 + _charge * 0.6
	_flash_amount = move_toward(_flash_amount, 0.0, delta * 6.0)
	_set_glow(CHARGE_COLOR, maxf(_flash_amount * 0.8, _charge * 0.7))


func _on_alert() -> void:
	_bolt_timer = randf_range(0.8, 1.6)


func _on_lost_sight() -> void:
	_winding = ""
	_charge = 0.0


func _update_attack(delta: float, dist: float) -> void:
	if _winding != "":
		_windup += delta
		var length := shock_telegraph if _winding == "shock" else bolt_telegraph
		_charge = clampf(_windup / length, 0.0, 1.0)
		if _windup >= length:
			if _winding == "shock":
				_shock()
			else:
				_fire()
			_winding = ""
			_charge = 0.0
		return
	if dist < shock_range and _shock_timer <= 0.0:
		_wind_up("shock")
		return
	_bolt_timer -= delta
	if dist >= shock_range and _bolt_timer <= 0.0 and _line_of_sight():
		_wind_up("bolt")


func _wind_up(attack: String) -> void:
	_winding = attack
	_windup = 0.0
	_play("charge", 0.0)


func _fire() -> void:
	var from := _chest()
	var p := Projectile.new()
	p.data = BOLT
	p.exclude = [get_rid()]
	p.collision_mask = 1 | 2  # world and player
	p.velocity = (_player_center() - from).normalized() * BOLT.projectile_speed
	get_parent().add_child(p)
	p.global_position = from
	_play("fire", 0.0)
	_bolt_timer = randf_range(bolt_interval.x, bolt_interval.y)


## Dumps the charge into the ground: a ring of lightning racing out across it.
func _shock() -> void:
	_shock_timer = shock_cooldown
	_bolt_timer = maxf(_bolt_timer, 1.0)
	_surge = 1.6
	velocity.y += 2.5  # kicked up off the ground by the discharge
	var center := Vector3(global_position.x, _ground_y(), global_position.z)
	_play("shock", 4.0)
	_shock_effect(center)

	if _player and not _player.get("dead"):
		var off := _player.global_position - center
		var d := Vector2(off.x, off.z).length()
		if d < shock_radius and absf(off.y) < 2.5:
			var falloff := clampf(1.2 - d / shock_radius, 0.3, 1.0)
			var dir := Vector3(off.x, 0.0, off.z).normalized()
			_player.take_damage(shock_damage * falloff, center, dir)
			if _player is CharacterBody3D:
				(_player as CharacterBody3D).velocity += dir * shock_push * falloff + Vector3.UP * 4.0 * falloff
	PhysicsProp.blast(get_tree(), center, shock_radius, 160.0)
	GasCan.ignite_near(get_tree(), center, shock_radius * 0.6)


func _shock_effect(center: Vector3) -> void:
	var fx := Node3D.new()
	get_parent().add_child(fx)
	fx.global_position = center + Vector3.UP * 0.05

	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 0.85
	torus.outer_radius = 1.0
	torus.rings = 24
	torus.ring_segments = 4
	ring.mesh = torus
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.75, 0.92, 1.0)
	ring.material_override = mat
	ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.scale = Vector3(0.6, 0.3, 0.6)
	fx.add_child(ring)
	var t := fx.create_tween().set_parallel()
	t.tween_property(ring, "scale", Vector3(shock_radius, 0.15, shock_radius), 0.35) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	t.tween_property(mat, "albedo_color:a", 0.0, 0.45).set_delay(0.1)

	# Arcs racing out along the ground with the ring.
	var arcs := ElectricArcs.new()
	arcs.color = CHARGE_COLOR
	arcs.drop = 0.0
	arcs.spread = shock_radius * 0.8
	arcs.intensity = 2.5
	arcs.light_energy = 3.0
	var starts := PackedVector3Array()
	for i in 8:
		var a := TAU * i / 8.0
		starts.append(Vector3(cos(a), 0.3, sin(a)) * 0.6)
	arcs.sources = starts
	fx.add_child(arcs)
	t.tween_property(arcs, "intensity", 0.0, 0.5).set_delay(0.15)

	var sparks := FX.burst(CHARGE_COLOR, 60, 9.0, 0.08, 0.7, -9.8, 4.0)
	fx.add_child(sparks)
	sparks.emitting = true
	t.chain().tween_interval(0.6)
	t.chain().tween_callback(fx.queue_free)


func _on_death() -> void:
	_winding = ""
	_charge = 0.0
	_arcs.visible = false
	_arcs.set_process(false)
	_hum.stop()
	var at := global_position + Vector3.UP * _height * 0.45
	var boom := Explosion.new()
	boom.size = 1.4
	boom.color = CHARGE_COLOR
	get_parent().add_child(boom)
	boom.global_position = at

	var fx := Node3D.new()
	get_parent().add_child(fx)
	fx.global_position = at
	for p in [_rubble(), _dust(), FX.burst(CHARGE_COLOR, 50, 7.0, 0.07, 0.8, -9.8, 4.0)]:
		fx.add_child(p)
		p.emitting = true
	get_tree().create_timer(3.0).timeout.connect(fx.queue_free)


func _on_respawn() -> void:
	_arcs.visible = true
	_arcs.set_process(true)
	_hum.play()


## Chunks of mossy stone flung out and tumbling down.
func _rubble() -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.8 * model_scale
	m.direction = Vector3.UP
	m.spread = 70.0
	m.initial_velocity_min = 2.0
	m.initial_velocity_max = 6.0
	m.gravity = Vector3(0, -12.0, 0)
	m.angle_min = -180.0
	m.angle_max = 180.0
	m.angular_velocity_min = -360.0
	m.angular_velocity_max = 360.0
	m.particle_flag_rotate_y = true
	m.scale_min = 0.6
	m.scale_max = 1.6
	m.scale_curve = FX.curve([Vector2(0, 1), Vector2(0.85, 1), Vector2(1, 0)])
	m.color_initial_ramp = FX.ramp([Color(0.48, 0.48, 0.45), Color(0.29, 0.3, 0.32), Color(0.35, 0.42, 0.24)],
		[0.0, 0.5, 1.0])
	var chunk := BoxMesh.new()
	chunk.size = Vector3(0.22, 0.18, 0.2)
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	chunk.material = mat
	return FX.emitter(30, 2.2, m, chunk, true)


## A cloud of grit and dust settling where it stood.
func _dust() -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.9 * model_scale
	m.direction = Vector3.UP
	m.spread = 90.0
	m.initial_velocity_min = 0.5
	m.initial_velocity_max = 1.5
	m.damping_min = 0.5
	m.damping_max = 1.0
	m.gravity = Vector3(0, -0.4, 0)
	m.scale_min = 0.9
	m.scale_max = 1.6
	m.scale_curve = FX.curve([Vector2(0, 0.6), Vector2(1, 1.8)])
	m.color_ramp = FX.ramp([Color(0.45, 0.42, 0.38, 0), Color(0.45, 0.42, 0.38, 0.6), Color(0.5, 0.48, 0.45, 0)],
		[0.0, 0.15, 1.0])
	return FX.emitter(20, 2.5, m, FX.quad(false), true)
