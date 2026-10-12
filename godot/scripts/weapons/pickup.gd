@tool
class_name Pickup
extends Area3D
## A floating, spinning weapon or ammo pickup. Walking into it hands it to the
## player's WeaponManager; once taken it disappears and respawns after
## `respawn_time` seconds with a sparkle and a chime. A full ammo supply leaves it
## in place. (@tool so the model also shows in the editor.)

enum Kind { WEAPON, AMMO }

const RESPAWN_SOUND := preload("res://assets/sfx/respawn.wav")
## Physics layer the player's body is on (bit value 2).
const PLAYER_LAYER := 2

@export var kind := Kind.AMMO
@export var weapon: WeaponData
@export_enum("bullets", "shells", "rockets", "cells") var ammo_type := "bullets"
@export var amount := 20
## Ammo model; weapons use their own model.
@export var model: PackedScene
@export var model_scale := 1.4
@export var respawn_time := 15.0
@export var hover_height := 0.45
@export var spin_speed := 1.8

var _model: Node3D
var _base_scale := Vector3.ONE
var _available := true
var _t := 0.0


func _ready() -> void:
	collision_layer = 0
	collision_mask = PLAYER_LAYER
	var shape := CollisionShape3D.new()
	var sphere := SphereShape3D.new()
	sphere.radius = 0.9
	shape.shape = sphere
	shape.position.y = 0.6
	add_child(shape)

	var scene := weapon.model if kind == Kind.WEAPON and weapon else model
	if scene:
		_model = scene.instantiate()
		_base_scale = Vector3.ONE * (weapon.pickup_scale if kind == Kind.WEAPON and weapon else model_scale)
		_model.scale = _base_scale
		_model.position.y = hover_height
		add_child(_model)
	if kind == Kind.WEAPON and weapon:
		var glow := OmniLight3D.new()
		glow.light_color = weapon.projectile_color
		glow.omni_range = 2.5
		glow.light_energy = 0.8
		glow.position.y = 0.5
		add_child(glow)

	if Engine.is_editor_hint():
		return
	_t = randf() * TAU
	body_entered.connect(_try_give)


func _process(delta: float) -> void:
	if Engine.is_editor_hint() or _model == null:
		return
	_t += delta
	_model.rotate_y(spin_speed * delta)
	_model.position.y = hover_height + sin(_t * 2.0) * 0.1


func _try_give(body: Node3D) -> void:
	if not _available:
		return
	var wm := body.get_node_or_null("WeaponManager")
	if wm == null:
		return
	var taken: bool = wm.give_weapon(weapon) if kind == Kind.WEAPON else wm.give_ammo(ammo_type, amount)
	if taken:
		_collect()


func _collect() -> void:
	_available = false
	var tween := create_tween()
	tween.tween_property(_model, "scale", _base_scale * 1.3, 0.06)
	tween.tween_property(_model, "scale", Vector3.ZERO, 0.1)
	tween.tween_callback(func(): _model.visible = false)
	get_tree().create_timer(respawn_time).timeout.connect(_respawn)


func _respawn() -> void:
	_available = true
	_model.visible = true
	_model.scale = Vector3.ZERO
	create_tween().tween_property(_model, "scale", _base_scale, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	var color := weapon.projectile_color if kind == Kind.WEAPON and weapon else Color(1.0, 0.85, 0.4)
	var sparkle := FX.burst(color, 24, 2.5, 0.08, 0.6, 1.0, 3.0)
	sparkle.position.y = hover_height
	add_child(sparkle)
	sparkle.emitting = true
	get_tree().create_timer(1.0).timeout.connect(sparkle.queue_free)
	var chime := AudioStreamPlayer3D.new()
	chime.stream = RESPAWN_SOUND
	chime.unit_size = 4.0
	chime.volume_db = -6.0
	add_child(chime)
	chime.play()
	chime.finished.connect(chime.queue_free)
	# The player may already be standing on the spot.
	for body in get_overlapping_bodies():
		_try_give(body)
