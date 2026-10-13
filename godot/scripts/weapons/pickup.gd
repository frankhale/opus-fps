@tool
class_name Pickup
extends Area3D
## A floating, spinning weapon, ammo, health or gem pickup. Walking into it hands it to
## the player; once taken it disappears and respawns after `respawn_time` seconds with a
## sparkle and a chime. Anything the player can't use (full ammo or health) stays put.
## Loot dropped by enemies is `one_shot` (never respawns) and expires after `lifetime`;
## gems are collectibles, so they are always taken for good, with a sparkle.
## (@tool so the model also shows in the editor.)

enum Kind { WEAPON, AMMO, HEALTH, GEM }

const RESPAWN_SOUND := preload("res://assets/sfx/respawn.wav")
const HEAL_SOUND := preload("res://assets/sfx/heal.wav")
## Glow and sparkle color of gems (the gem model's green).
const GEM_COLOR := Color(0.45, 0.85, 0.25)
## Physics layer the player's body is on (bit value 2).
const PLAYER_LAYER := 2

@export var kind := Kind.AMMO
@export var weapon: WeaponData
@export_enum("bullets", "shells", "rockets", "cells") var ammo_type := "bullets"
## Ammo rounds, health points for HEALTH pickups, or gems for GEM pickups.
@export var amount := 20
## Ammo/health model; weapons use their own model.
@export var model: PackedScene
@export var model_scale := 1.4
@export var respawn_time := 15.0
@export var hover_height := 0.45
@export var spin_speed := 1.8
## Loot: taken once, never respawns.
@export var one_shot := false
## Seconds before an untaken pickup vanishes (0 = never). It blinks near the end.
@export var lifetime := 0.0

var _model: Node3D
var _base_scale := Vector3.ONE
var _available := true
var _t := 0.0
var _age := 0.0


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
	if kind == Kind.WEAPON and weapon or kind == Kind.GEM:
		var glow := OmniLight3D.new()
		glow.light_color = weapon.projectile_color if kind == Kind.WEAPON else GEM_COLOR
		glow.omni_range = 2.5
		glow.light_energy = 0.8
		glow.position.y = 0.5
		add_child(glow)
	if kind == Kind.GEM:
		one_shot = true

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
	if lifetime > 0.0 and _available:
		_age += delta
		if _age > lifetime - 3.0:
			_model.visible = fmod(_age * 8.0, 2.0) < 1.3  # blink before vanishing
		if _age > lifetime:
			queue_free()


## Toss the pickup out from `from` and let it drop onto the ground at its position.
func pop_from(from: Vector3) -> void:
	var landing := global_position
	global_position = from
	var tween := create_tween()
	tween.tween_property(self, "global_position", landing + Vector3(0, 0.8, 0), 0.25) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(self, "global_position", landing, 0.3) \
		.set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)


func _try_give(body: Node3D) -> void:
	if not _available:
		return
	var taken := false
	match kind:
		Kind.WEAPON, Kind.AMMO:
			var wm := body.get_node_or_null("WeaponManager")
			if wm == null:
				return
			taken = wm.give_weapon(weapon) if kind == Kind.WEAPON else wm.give_ammo(ammo_type, amount)
		Kind.HEALTH:
			if not body.has_method("heal"):
				return
			taken = body.heal(amount)
			if taken:
				_chime(HEAL_SOUND, get_parent())
		Kind.GEM:
			if not body.has_method("add_gems"):
				return
			taken = body.add_gems(amount)
			if taken:
				_chime(RESPAWN_SOUND, get_parent())
				var sparkle := FX.burst(GEM_COLOR, 24, 2.5, 0.08, 0.6, 1.0, 3.0)
				get_parent().add_child(sparkle)
				sparkle.global_position = global_position + Vector3(0, hover_height, 0)
				sparkle.emitting = true
				get_tree().create_timer(1.0).timeout.connect(sparkle.queue_free)
	if taken:
		_collect()


func _collect() -> void:
	_available = false
	var tween := create_tween()
	tween.tween_property(_model, "scale", _base_scale * 1.3, 0.06)
	tween.tween_property(_model, "scale", Vector3.ZERO, 0.1)
	if one_shot:
		tween.tween_callback(queue_free)
		return
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
	_chime(RESPAWN_SOUND, self)
	# The player may already be standing on the spot.
	for body in get_overlapping_bodies():
		_try_give(body)


## 3D sound at the pickup; parented to `holder` so it outlives a freed pickup.
func _chime(stream: AudioStream, holder: Node) -> void:
	var s := AudioStreamPlayer3D.new()
	s.stream = stream
	s.unit_size = 4.0
	s.volume_db = -6.0
	holder.add_child(s)
	s.global_position = global_position
	s.play()
	s.finished.connect(s.queue_free)
