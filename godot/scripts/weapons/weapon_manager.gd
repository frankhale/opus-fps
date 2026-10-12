class_name WeaponManager
extends Node
## The player's weapons: inventory, ammo, firing and the held weapon (viewmodel).
##
## The viewmodel is drawn by its own camera into a transparent SubViewport layered
## over the game view (inside the low-res game viewport, so it still gets the PS1
## look). It only renders VIEW_LAYER, which the main camera skips, so the gun never
## clips into walls. Projectiles start at the muzzle as seen on screen and fly toward
## whatever is under the crosshair.

signal weapon_changed(weapon: WeaponData)
signal ammo_changed(ammo_type: String, amount: int)
signal message(text: String)

const MAX_AMMO := {"bullets": 200, "shells": 50, "rockets": 20, "cells": 150}
## Render layer 2 (bit value 2) holds viewmodel meshes only.
const VIEW_LAYER := 2

const HAND_RIGHT := preload("res://assets/viewmodel/hand_right_grip.glb")
const HAND_LEFT_GRIP := preload("res://assets/viewmodel/hand_left_grip.glb")
const HAND_LEFT_SUPPORT := preload("res://assets/viewmodel/hand_left_support.glb")
const FOREARM := preload("res://assets/viewmodel/forearm.glb")
## Where each hand model's wrist is (its own space); the forearm attaches here.
const WRIST_RIGHT := Vector3(0.024, -0.05, 0.075)
const WRIST_LEFT_GRIP := Vector3(-0.024, -0.05, 0.075)
const WRIST_LEFT_SUPPORT := Vector3(-0.036, -0.062, 0.08)

@export var viewmodel_fov := 68.0
@export var dry_fire_sound: AudioStream
@export var pickup_weapon_sound: AudioStream
@export var pickup_ammo_sound: AudioStream
@export var fire_volume_db := -6.0

@export_group("Arms")
## Shoulder positions in camera space, just off-screen below and behind the view.
## Forearms run from each wrist toward these, so the arms follow the weapon's motion.
@export var right_shoulder := Vector3(0.26, -0.75, 0.05)
@export var left_shoulder := Vector3(-0.24, -0.75, 0.05)

@export_group("Viewmodel motion")
## How far mouse movement swings the weapon (radians per screen pixel).
@export var sway_amount := 0.0012
@export var sway_limit := 0.09
@export var bob_scale := 1.0
@export var switch_time := 0.14

@onready var player: CharacterBody3D = get_parent()
@onready var camera: Camera3D = player.get_node("Head/Camera3D")

var weapons: Array[WeaponData] = []
var ammo := {}
var current: WeaponData

var _vm_viewport: SubViewport
var _vm_camera: Camera3D
var _vm_root: Node3D
var _model: Node3D
var _muzzle: Node3D
## [{hand, wrist, forearm, shoulder}] for the right and left arm.
var _arms: Array[Dictionary] = []
var _forearms: Array[Node3D] = []
var _flash: Node3D
var _flash_time := 0.0
var _flash_light: OmniLight3D
var _fire_audio: AudioStreamPlayer
var _ui_audio: AudioStreamPlayer
var _cooldown := 0.0
var _switching := false
var _lowered := 1.0
var _sway := Vector2.ZERO
var _kick := 0.0
var _kick_v := 0.0
var _sprint_pose := 0.0


func _ready() -> void:
	for t in MAX_AMMO:
		ammo[t] = 0
	camera.cull_mask &= ~VIEW_LAYER
	_fire_audio = AudioStreamPlayer.new()
	_fire_audio.max_polyphony = 4
	add_child(_fire_audio)
	_ui_audio = AudioStreamPlayer.new()
	add_child(_ui_audio)
	_build_viewmodel.call_deferred()


func _build_viewmodel() -> void:
	var game_viewport := camera.get_viewport()
	var layer := CanvasLayer.new()
	layer.name = "ViewmodelLayer"
	game_viewport.add_child(layer)
	_vm_viewport = SubViewport.new()
	_vm_viewport.transparent_bg = true
	_vm_viewport.size = Vector2i(game_viewport.get_visible_rect().size)
	_vm_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	layer.add_child(_vm_viewport)
	var rect := TextureRect.new()
	rect.texture = _vm_viewport.get_texture()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	layer.add_child(rect)
	_vm_camera = Camera3D.new()
	_vm_camera.cull_mask = VIEW_LAYER
	_vm_camera.fov = viewmodel_fov
	_vm_camera.near = 0.01
	_vm_camera.far = 10.0
	_vm_camera.environment = _viewmodel_environment()
	_vm_viewport.add_child(_vm_camera)
	_vm_camera.current = true
	_vm_root = Node3D.new()
	_vm_camera.add_child(_vm_root)
	for i in 2:
		var arm: Node3D = FOREARM.instantiate()
		_set_view_layer(arm)
		arm.visible = false
		_vm_camera.add_child(arm)
		_forearms.append(arm)


## The held weapon gets its own fill light so it reads clearly even when the sun is
## in front of the player. No bloom here: it would haze the gun's silhouette.
func _viewmodel_environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.62, 0.66)
	env.ambient_light_energy = 1.0
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.glow_enabled = false
	return env


# ---------------------------------------------------------------------------
# Inventory
# ---------------------------------------------------------------------------
## Returns true if anything was taken (new weapon or ammo that wasn't full).
func give_weapon(w: WeaponData) -> bool:
	var is_new := not weapons.has(w)
	var took_ammo := _add_ammo(w.ammo_type, w.ammo_on_pickup)
	if is_new:
		weapons.append(w)
		weapons.sort_custom(func(a, b): return a.slot < b.slot)
		_play(pickup_weapon_sound, -4.0)
		message.emit("Picked up the %s" % w.display_name)
		equip(w)
		return true
	if took_ammo:
		_play(pickup_ammo_sound, -8.0)
		message.emit("+%d %s" % [w.ammo_on_pickup, w.ammo_type])
	return took_ammo


func give_ammo(type: String, amount: int) -> bool:
	if not _add_ammo(type, amount):
		return false
	_play(pickup_ammo_sound, -8.0)
	message.emit("+%d %s" % [amount, type])
	return true


func _add_ammo(type: String, amount: int) -> bool:
	if ammo[type] >= MAX_AMMO[type]:
		return false
	ammo[type] = mini(ammo[type] + amount, MAX_AMMO[type])
	ammo_changed.emit(type, ammo[type])
	return true


func equip(w: WeaponData) -> void:
	if w == current or _switching or not weapons.has(w):
		return
	_switching = true
	var tween := create_tween()
	if current:
		tween.tween_property(self, "_lowered", 1.0, switch_time).set_trans(Tween.TRANS_SINE)
	tween.tween_callback(_swap_model.bind(w))
	tween.tween_property(self, "_lowered", 0.0, switch_time * 1.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func(): _switching = false)


func _swap_model(w: WeaponData) -> void:
	if _model:
		_model.queue_free()
	current = w
	_model = w.model.instantiate()
	_model.scale = Vector3.ONE * w.view_scale
	_vm_root.add_child(_model)
	_set_view_layer(_model)
	_muzzle = Node3D.new()
	_muzzle.position = w.muzzle
	_model.add_child(_muzzle)
	_attach_hands(w)
	_flash = _make_flash(w)
	_muzzle.add_child(_flash)
	_flash_light = OmniLight3D.new()
	_flash_light.light_color = w.projectile_color
	_flash_light.omni_range = 4.0
	_flash_light.light_energy = 0.0
	_muzzle.add_child(_flash_light)
	weapon_changed.emit(w)
	ammo_changed.emit(w.ammo_type, ammo[w.ammo_type])


## Muzzle flash sized to the weapon: a glowing star facing the camera plus a pair
## of crossed quads shooting forward out of the barrel, shown for a few frames.
func _make_flash(w: WeaponData) -> Node3D:
	var size := w.muzzle_flash_size()
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Alpha blending, not additive: additive quads disturb the alpha of the
	# transparent viewmodel layer and show up as faint rectangles in the game view.
	m.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_texture = FX.star_texture()
	# Above 1 so the overlapping star and spike burn to a white-hot core with
	# colored edges.
	var hot := w.projectile_color.lightened(0.35) * 1.8
	m.albedo_color = Color(hot.r, hot.g, hot.b, 1.0)
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var star_mat := m.duplicate() as StandardMaterial3D
	star_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	star_mat.billboard_keep_scale = true

	var flash := Node3D.new()
	flash.visible = false
	var star_quad := QuadMesh.new()
	star_quad.size = Vector2(size, size)
	flash.add_child(_flash_part(star_quad, star_mat, Vector3.ZERO, Basis.IDENTITY))
	# Forward spike: two crossed quads along -Z, starting at the muzzle.
	var spike := QuadMesh.new()
	spike.size = Vector2(size * 0.45, size * 2.2)
	var along_barrel := Basis(Vector3.RIGHT, deg_to_rad(-90.0))  # quad height -> -Z
	for roll in [0.0, 90.0]:
		var b := Basis(Vector3.BACK, deg_to_rad(roll)) * along_barrel
		flash.add_child(_flash_part(spike, m, Vector3(0, 0, -size * 1.1), b))
	return flash


func _flash_part(mesh: Mesh, mat: Material, pos: Vector3, orientation: Basis) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = Transform3D(orientation, pos)
	mi.layers = VIEW_LAYER
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


## Re-grip for this weapon: right hand on the grip, left hand on its pump, handguard
## or front grip. Hands live under the pose root (not the model) so a weapon's
## view_scale never shrinks them.
func _attach_hands(w: WeaponData) -> void:
	for a in _arms:
		a.hand.queue_free()
	_arms.clear()
	var left_grip := w.left_hand_style == "grip"
	_arms.append(_make_arm(HAND_RIGHT, WRIST_RIGHT, w.right_hand_position, w.right_hand_rotation_degrees,
		_forearms[0], right_shoulder))
	_arms.append(_make_arm(HAND_LEFT_GRIP if left_grip else HAND_LEFT_SUPPORT,
		WRIST_LEFT_GRIP if left_grip else WRIST_LEFT_SUPPORT, w.left_hand_position, w.left_hand_rotation_degrees,
		_forearms[1], left_shoulder))
	for f in _forearms:
		f.visible = true


func _make_arm(scene: PackedScene, wrist: Vector3, pos: Vector3, rot_deg: Vector3, forearm: Node3D,
		shoulder: Vector3) -> Dictionary:
	var hand: Node3D = scene.instantiate()
	_set_view_layer(hand)
	_vm_root.add_child(hand)
	var rot := Vector3(deg_to_rad(rot_deg.x), deg_to_rad(rot_deg.y), deg_to_rad(rot_deg.z))
	hand.transform = Transform3D(Basis.from_euler(rot), _model.transform * pos)
	return {"hand": hand, "wrist": wrist, "forearm": forearm, "shoulder": shoulder}


## Point each forearm from its wrist toward the shoulder (after the pose update).
func _update_arms() -> void:
	var up := _vm_camera.global_basis.y
	for a in _arms:
		var forearm: Node3D = a.forearm
		forearm.global_position = a.hand.global_transform * a.wrist
		forearm.look_at(_vm_camera.global_transform * a.shoulder, up)


func _set_view_layer(root: Node) -> void:
	for vi in root.find_children("*", "VisualInstance3D", true, false):
		vi.layers = VIEW_LAYER
		if vi is GeometryInstance3D:
			vi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _cycle(step: int) -> void:
	if weapons.is_empty():
		return
	var i := weapons.find(current)
	equip(weapons[wrapi(i + step, 0, weapons.size())])


# ---------------------------------------------------------------------------
# Input and firing
# ---------------------------------------------------------------------------
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_sway = (_sway + event.screen_relative * sway_amount).limit_length(sway_limit)
	elif event.is_action_pressed("next_weapon"):
		_cycle(1)
	elif event.is_action_pressed("prev_weapon"):
		_cycle(-1)
	else:
		for w in weapons:
			if event.is_action_pressed("weapon_%d" % w.slot):
				equip(w)


func _process(delta: float) -> void:
	if _vm_camera == null:
		return
	var game_size := Vector2i(camera.get_viewport().get_visible_rect().size)
	if _vm_viewport.size != game_size:
		_vm_viewport.size = game_size
	_vm_camera.global_transform = camera.global_transform

	_cooldown -= delta
	if current and not _switching and not player.dead and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var pressed := Input.is_action_pressed("fire") if current.automatic else Input.is_action_just_pressed("fire")
		if pressed and _cooldown <= 0.0:
			if ammo[current.ammo_type] > 0:
				_fire()
			elif Input.is_action_just_pressed("fire"):
				_play(dry_fire_sound, -6.0)
				_cooldown = 0.25
	_update_pose(delta)
	_update_arms()
	if _flash_light:
		_flash_light.light_energy = move_toward(_flash_light.light_energy, 0.0, delta * 40.0)
		_flash_time -= delta
		_flash.visible = _flash_time > 0.0


func _fire() -> void:
	var w := current
	_cooldown = w.fire_interval
	ammo[w.ammo_type] -= 1
	ammo_changed.emit(w.ammo_type, ammo[w.ammo_type])

	var space := player.get_world_3d().direct_space_state
	var eye := camera.global_position
	var forward := -camera.global_basis.z
	var aim := PhysicsRayQueryParameters3D.create(eye, eye + forward * 400.0, 1 | Projectile.LAYER_ENEMIES, [player.get_rid()])
	var hit := space.intersect_ray(aim)
	var target: Vector3 = hit.position if hit else eye + forward * 400.0

	# Start where the muzzle appears on screen; if a wall is in the way (gun poking
	# into it), detonate right there instead.
	var spawn := _muzzle_world_point()
	var block := space.intersect_ray(PhysicsRayQueryParameters3D.create(eye, spawn, 1, [player.get_rid()]))
	for i in w.projectiles_per_shot:
		var p := Projectile.new()
		p.data = w
		p.exclude = [player.get_rid()]
		var dir := _spread((target - spawn).normalized(), w.spread_degrees)
		p.velocity = dir * w.projectile_speed
		player.get_parent().add_child(p)
		p.global_position = spawn
		if block:
			p.explode(block.position, block.normal)

	_flash.visible = true
	_flash.rotation.z = randf() * TAU
	_flash.scale = Vector3.ONE * randf_range(0.85, 1.2)
	_flash_time = 0.06
	_flash_light.light_energy = 1.5 + w.muzzle_flash_size() * 6.0
	_kick_v += 9.0 * w.recoil
	if camera.has_method("kick"):
		camera.kick(0.9 * w.recoil)
	if w.recoil >= 2.0 and camera.has_method("add_trauma"):
		camera.add_trauma(0.12 * w.recoil)
	_play(w.fire_sound, fire_volume_db, _fire_audio)


func _muzzle_world_point() -> Vector3:
	# The viewmodel camera has its own FOV, so map the muzzle through screen space:
	# the returned point appears exactly at the muzzle in the main camera's view.
	var mp := _muzzle.global_position
	var depth := (mp - _vm_camera.global_position).dot(-_vm_camera.global_basis.z)
	return camera.project_position(_vm_camera.unproject_position(mp), depth)


func _spread(dir: Vector3, degrees: float) -> Vector3:
	if degrees <= 0.0:
		return dir
	var r := sqrt(randf()) * deg_to_rad(degrees)
	var theta := randf() * TAU
	return (Basis.looking_at(dir) * Vector3(sin(r) * cos(theta), sin(r) * sin(theta), -cos(r))).normalized()


# ---------------------------------------------------------------------------
# Viewmodel motion
# ---------------------------------------------------------------------------
func _update_pose(delta: float) -> void:
	if current == null:
		return
	_sway = _sway.lerp(Vector2.ZERO, 1.0 - exp(-7.0 * delta))
	_kick_v += (-220.0 * _kick - 20.0 * _kick_v) * delta
	_kick += _kick_v * delta
	var sprinting: bool = player.is_sprinting and player.horizontal_speed() > player.walk_speed + 0.5 and _cooldown < -0.2
	_sprint_pose = lerpf(_sprint_pose, 1.0 if sprinting else 0.0, 1.0 - exp(-8.0 * delta))

	var phase: float = camera.bob_phase
	var amount: float = camera.bob_amount * bob_scale
	var bob := Vector3(cos(phase) * 0.012, -absf(sin(phase)) * 0.012, 0.0) * amount
	var pos := current.view_position + bob
	pos += Vector3(-_sway.x * 0.15, _sway.y * 0.15, _kick * 0.035)
	pos += Vector3(-0.04, -0.05, 0.02) * _sprint_pose
	pos.y -= _lowered * 0.35
	var rot := current.view_rotation_degrees
	rot += Vector3(rad_to_deg(_sway.y) * 0.8 + _kick * 5.0, rad_to_deg(_sway.x) * 0.8, rad_to_deg(-_sway.x) * 0.5)
	rot += Vector3(-12.0, 28.0, 10.0) * _sprint_pose
	rot.x -= _lowered * 30.0
	_vm_root.position = pos
	_vm_root.rotation_degrees = rot


func _play(stream: AudioStream, db: float, to: AudioStreamPlayer = null) -> void:
	if stream == null:
		return
	var p := to if to else _ui_audio
	if p.stream != stream:
		p.stream = stream
	p.volume_db = db
	p.pitch_scale = randf_range(0.96, 1.04)
	p.play()
