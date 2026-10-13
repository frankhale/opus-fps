class_name GemCounter
extends Control
## HUD gem count: a small spinning 3D gem (the pickup model, rendered at low resolution
## to match the PS1 look of the game) followed by "x N". The icon square is as tall as
## this control. A new gem makes the count pop and the gem spin faster for a moment.

const GEM := preload("res://assets/pickups/pickup_gem.glb")
## Screen pixels per rendered pixel.
const PIXEL_SIZE := 2
const SPIN := 1.6
## The gem model spans 0.12-0.39 m up from its origin; frame it with a little margin.
const GEM_CENTER := Vector3(0.0, 0.255, 0.0)
const VIEW_SIZE := 0.42

var _gem: Node3D
var _label: Label
var _spin := SPIN
var _pop: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var icon := size.y
	var container := SubViewportContainer.new()
	container.stretch = true
	container.stretch_shrink = PIXEL_SIZE
	container.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	container.offset_right = icon
	add_child(container)

	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	viewport.transparent_bg = true
	container.add_child(viewport)

	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = VIEW_SIZE
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.7, 0.7, 0.72)
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	camera.environment = env
	viewport.add_child(camera)
	# Looking slightly down so the crown's facets show.
	camera.look_at_from_position(GEM_CENTER + Vector3(0.0, 0.5, 2.0), GEM_CENTER)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40.0, 30.0, 0.0)
	viewport.add_child(light)

	_gem = GEM.instantiate()
	viewport.add_child(_gem)

	_label = Label.new()
	var settings := LabelSettings.new()
	settings.font_size = 22
	settings.font_color = Color(0.91, 0.85, 0.7)
	settings.outline_size = 5
	settings.outline_color = Color(0, 0, 0, 0.85)
	_label.label_settings = settings
	_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_label.offset_left = icon + 4.0
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	add_child(_label)
	set_count(0)


func _process(delta: float) -> void:
	_spin = move_toward(_spin, SPIN, delta * 12.0)
	_gem.rotate_y(_spin * delta)


func set_count(count: int) -> void:
	_label.text = "x %d" % count
	if count == 0:
		return
	_spin = 14.0
	_label.pivot_offset = Vector2(0.0, _label.size.y / 2.0)
	if _pop:
		_pop.kill()
	_pop = create_tween()
	_label.scale = Vector2.ONE * 1.35
	_pop.tween_property(_label, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
