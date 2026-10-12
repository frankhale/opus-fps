class_name AmmoDisplay
extends Control
## HUD ammo counter drawn with one 3D round per unit of ammo, lined up in rows from
## the right edge (like a bandolier) and rendered at low resolution so it matches the
## PS1 look of the game. Spent rounds pop up and vanish; new ones grow in. Counts above
## what fits are shown as "+N" beside the rows, and the rounds turn red when low.

## Per ammo type: the round model, how many fit in a row, how many rows, the height a
## round is drawn at (in display units; the view is VIEW_HEIGHT units tall), the
## distance between rounds, and the count at or below which the counter turns red.
const TYPES := {
	"bullets": {"model": preload("res://assets/ammo/ammo_round_bullet.glb"),
		"per_row": 25, "rows": 2, "height": 1.0, "spacing": 0.5, "low": 10},
	"shells": {"model": preload("res://assets/ammo/ammo_round_shell.glb"),
		"per_row": 20, "rows": 2, "height": 1.0, "spacing": 0.62, "low": 4},
	"rockets": {"model": preload("res://assets/ammo/ammo_round_rocket.glb"),
		"per_row": 10, "rows": 1, "height": 2.2, "spacing": 1.15, "low": 1},
	"cells": {"model": preload("res://assets/ammo/ammo_round_cell.glb"),
		"per_row": 20, "rows": 2, "height": 1.0, "spacing": 0.62, "low": 15},
}
const VIEW_HEIGHT := 2.6
const ROW_GAP := 0.25
## Screen pixels per rendered pixel.
const PIXEL_SIZE := 2
const LOW_TINT := Color(1.0, 0.4, 0.35)

var _viewport: SubViewport
var _camera: Camera3D
var _overflow: Label
## Pooled round instances per ammo type, built on first use.
var _rounds := {}
var _type := ""
var _count := 0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var container := SubViewportContainer.new()
	container.stretch = true
	container.stretch_shrink = PIXEL_SIZE
	container.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(container)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	container.add_child(_viewport)

	_camera = Camera3D.new()
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = VIEW_HEIGHT
	_camera.environment = _environment()
	_viewport.add_child(_camera)
	# Looking slightly down on the rows so the rounds read as solid shapes.
	var center := Vector3(0.0, VIEW_HEIGHT * 0.5 - 0.1, 0.0)
	_camera.look_at_from_position(center + Vector3(0.0, 2.0, 10.0), center)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-35.0, 30.0, 0.0)
	light.light_energy = 1.1
	_viewport.add_child(light)

	# Sits just left of the rows, which are full whenever there is an overflow.
	_overflow = Label.new()
	_overflow.add_theme_font_size_override("font_size", 18)
	_overflow.add_theme_color_override("font_outline_color", Color.BLACK)
	_overflow.add_theme_constant_override("outline_size", 4)
	_overflow.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_overflow.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_overflow.anchor_top = 0.5
	_overflow.anchor_bottom = 0.5
	_overflow.offset_left = -90.0
	_overflow.offset_right = -6.0
	_overflow.offset_top = -14.0
	_overflow.offset_bottom = 14.0
	add_child(_overflow)

	resized.connect(func(): _layout(_type))


func _environment() -> Environment:
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.72)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	return env


## Show `count` rounds of `type` ("" hides the counter).
func show_ammo(type: String, count: int) -> void:
	visible = type != ""
	if not visible:
		return
	if type != _type:
		if _type != "":
			for r in _rounds[_type]:
				r.visible = false
		_type = type
		_count = 0
		_build(type)
		_layout(type)
	var rounds: Array = _rounds[type]
	var shown := mini(count, rounds.size())
	var before := mini(_count, rounds.size())
	for i in range(shown, before):
		_spend(rounds[i])
	for i in range(before, shown):
		_load(rounds[i], i - before)
	_count = count
	var extra := count - rounds.size()
	_overflow.text = "+%d" % extra if extra > 0 else ""
	modulate = LOW_TINT if count <= TYPES[type].low else Color.WHITE


## Instance a type's rounds the first time it is shown, stacking rows bottom-up.
func _build(type: String) -> void:
	if _rounds.has(type):
		return
	var cfg: Dictionary = TYPES[type]
	var list: Array[Node3D] = []
	var s := 1.0
	for i in cfg.per_row * cfg.rows:
		var r: Node3D = cfg.model.instantiate()
		if i == 0:
			s = cfg.height / _model_height(r)
		r.visible = false
		r.rotation_degrees.y = 25.0
		r.scale = Vector3.ONE * s
		r.position.y = (i / cfg.per_row) * (cfg.height + ROW_GAP)
		r.set_meta("scale", s)
		r.set_meta("y", r.position.y)
		_viewport.add_child(r)
		list.append(r)
	_rounds[type] = list


## Line the rounds up from the right edge (the view's width follows the control's).
func _layout(type: String) -> void:
	if type == "" or size.y <= 0.0:
		return
	var cfg: Dictionary = TYPES[type]
	var half_width := VIEW_HEIGHT * size.x / size.y * 0.5
	for i in _rounds[type].size():
		var col: int = i % cfg.per_row
		_rounds[type][i].position.x = half_width - cfg.spacing * (col + 0.6)


func _model_height(r: Node3D) -> float:
	var top := 0.0
	for m in r.find_children("*", "MeshInstance3D", true, false):
		var box: AABB = (m as MeshInstance3D).get_aabb()
		top = maxf(top, box.end.y)
	return maxf(top, 0.001)


## A new round grows into place, staggered so a pickup fills the row left to right.
func _load(r: Node3D, order: int) -> void:
	_kill_tween(r)
	var s: float = r.get_meta("scale")
	r.position.y = r.get_meta("y")
	r.scale = Vector3.ONE * s * 0.01
	r.visible = true
	var t := create_tween()
	t.tween_interval(minf(order * 0.015, 0.4))
	t.tween_property(r, "scale", Vector3.ONE * s, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	r.set_meta("tween", t)


## A spent round hops up and shrinks away.
func _spend(r: Node3D) -> void:
	_kill_tween(r)
	var s: float = r.get_meta("scale")
	var y: float = r.get_meta("y")
	var t := create_tween().set_parallel()
	t.tween_property(r, "position:y", y + 0.5, 0.16).set_ease(Tween.EASE_OUT)
	t.tween_property(r, "scale", Vector3.ONE * s * 0.01, 0.16).set_ease(Tween.EASE_IN)
	t.chain().tween_callback(func():
		r.visible = false
		r.position.y = y)
	r.set_meta("tween", t)


func _kill_tween(r: Node3D) -> void:
	if r.has_meta("tween"):
		var old: Tween = r.get_meta("tween")
		if old and old.is_valid():
			old.kill()
