@tool
class_name Portal
extends Node3D
## A stone ring gate filled with a shimmering, see-through membrane of blue light
## (assets/scenery/portal.glb with materials/ps1_portal.tres). Walking through the
## membrane from either side sends the player out of the `exit` portal, keeping their
## offset, facing and momentum relative to the gate: step into one portal's front and
## you come out of the other's front, walking away from it.
## Or, given a `level`, walking through takes the player to that level instead (the hub's
## portals), and a `title` floats above the ring.
## The frame is solid; the membrane is not. The gold runes on the ring pulse, and flare
## with the light when someone passes through. (@tool so the model shows in the editor.)

const MODEL := preload("res://assets/scenery/portal.glb")
const HUM := preload("res://assets/sfx/portal_hum.wav")
const WHOOSH := preload("res://assets/sfx/teleport.wav")
## The membrane disc in the model, in meters at scale 1 (see tools/generate_assets.py).
const MEMBRANE_CENTER := 0.885
const MEMBRANE_RADIUS := 1.45
## The player is tested at this point above its feet, roughly the middle of the body.
const BODY_HEIGHT := 0.9
const LIGHT_COLOR := Color(0.35, 0.65, 1.0)
## The gold runes pulse PULSE_SPEED times a second, from a dim, unlit gold (albedo
## scaled by RUNE_DIM, no glow) up to a bright glow of RUNE_GLOW, so the swing reads even
## in daylight.
const RUNE_DIM := 0.35
const RUNE_GLOW := 0.8
const PULSE_SPEED := 0.6
## The title: gold lettering with a dark outline (like the gallery's headings), this far
## above the top of the ring.
const TITLE_COLOR := Color(0.95, 0.85, 0.55)
const TITLE_SIZE := 96
const TITLE_PIXEL := 0.012
const TITLE_GAP := 1.6

## The portal this one sends the player to.
@export var exit_path: NodePath
## A level to go to instead (a key of Main.LEVELS, such as "island"): walking through
## loads it. Leave empty for a portal with an exit.
@export var level := ""
## Written above the ring (none if empty).
@export var title := "":
	set(v):
		title = v
		if _title:
			_title.text = v
			_title.visible = v != ""
@export var model_scale := 1.3:
	set(v):
		model_scale = v
		if _model:
			_model.scale = Vector3.ONE * v
		if _title:
			_title.position.y = _title_height()

var _model: Node3D
var _title: Label3D
var _light: OmniLight3D
var _rune_glow: ShaderMaterial
var _whoosh: AudioStreamPlayer
var _exit: Portal
var _player: CharacterBody3D
var _prev := Vector3.ZERO
var _has_prev := false
var _flare := 0.0
var _t := 0.0


func _ready() -> void:
	_model = MODEL.instantiate()
	_model.scale = Vector3.ONE * model_scale
	add_child(_model)
	var c := MEMBRANE_CENTER * model_scale
	_light = OmniLight3D.new()
	_light.light_color = LIGHT_COLOR
	_light.omni_range = 4.0 * model_scale
	_light.position = Vector3(0.0, c, 0.0)
	add_child(_light)
	_title = Label3D.new()
	_title.text = title
	_title.visible = title != ""
	_title.font_size = TITLE_SIZE
	_title.pixel_size = TITLE_PIXEL
	_title.modulate = TITLE_COLOR
	@warning_ignore("integer_division")
	_title.outline_size = TITLE_SIZE / 6  # whole pixels
	_title.outline_modulate = Color(0.05, 0.05, 0.06)
	_title.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
	_title.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_title.position.y = _title_height()
	add_child(_title)
	_own_rune_material()
	if Engine.is_editor_hint():
		return
	_build_frame_collision()
	var hum := AudioStreamPlayer3D.new()
	hum.stream = HUM
	hum.position = _light.position
	hum.volume_db = -6.0
	hum.unit_size = 3.0
	hum.max_distance = 22.0
	hum.autoplay = true
	add_child(hum)
	_whoosh = AudioStreamPlayer.new()
	_whoosh.stream = WHOOSH
	_whoosh.volume_db = -4.0
	add_child(_whoosh)
	if level != "":
		Main.preload_level(level)  # loads in the background, ready for when you step through
	_exit = get_node_or_null(exit_path) as Portal
	if _exit == null and level == "":
		push_warning("%s has no exit portal or level" % name)


func _title_height() -> float:
	return (MEMBRANE_CENTER + MEMBRANE_RADIUS) * model_scale + TITLE_GAP


## Gives this portal its own copy of the shared glow material on its runes, so their
## pulse doesn't make every other glowing thing in the level pulse too.
func _own_rune_material() -> void:
	for mi: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false):
		for i in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(i)
			if mat is ShaderMaterial and mat.resource_name == "PS1_Glow":
				if _rune_glow == null:
					_rune_glow = mat.duplicate()
				mi.set_surface_override_material(i, _rune_glow)


## Static trimesh collision for the stone frame only, so the membrane stays open.
func _build_frame_collision() -> void:
	for mi: MeshInstance3D in _model.find_children("*", "MeshInstance3D", true, false):
		var solid := ArrayMesh.new()
		for i in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(i)
			if mat and mat.resource_name == "PS1_Portal":
				continue
			solid.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mi.mesh.surface_get_arrays(i))
		if solid.get_surface_count() == 0:
			continue
		var body := StaticBody3D.new()
		var shape := CollisionShape3D.new()
		shape.shape = solid.create_trimesh_shape()
		body.add_child(shape)
		mi.add_child(body)


func _process(delta: float) -> void:
	# The light breathes and flickers, and flares when someone passes through.
	_t += delta
	_flare = maxf(_flare - delta * 1.5, 0.0)
	_light.light_energy = 1.4 + 0.25 * sin(_t * 2.3) + 0.1 * sin(_t * 13.0) + _flare * 4.0
	if _rune_glow:
		var pulse := 0.5 - 0.5 * cos(_t * TAU * PULSE_SPEED)  # 0..1, smooth at both ends
		_rune_glow.set_shader_parameter("albedo_scale", lerpf(RUNE_DIM, 1.0, pulse))
		_rune_glow.set_shader_parameter("emission_strength", RUNE_GLOW * pulse + _flare * 3.0)


func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint() or (_exit == null and level == "") or _player_node() == null:
		return
	var p := to_local(_player.global_position + Vector3.UP * BODY_HEIGHT)
	# Crossing the membrane's plane (local z = 0) inside the ring sends the player through.
	# Big jumps (respawning) aren't walking through.
	if _has_prev and signf(p.z) != signf(_prev.z) and p.distance_to(_prev) < 2.0 and not _player.dead:
		var hit := _prev.lerp(p, absf(_prev.z) / (absf(_prev.z) + absf(p.z)))
		var r := MEMBRANE_RADIUS * model_scale
		if Vector2(hit.x, hit.y - MEMBRANE_CENTER * model_scale).length() < r:
			_send_player()
			return
	_prev = p
	_has_prev = true


func _send_player() -> void:
	if level != "":
		# Off to another level: the player stops at the membrane, the whoosh and a flare,
		# and the screen fades to the portal's light as the level changes.
		_flare = 1.0
		_whoosh.play()
		set_physics_process(false)
		_player.velocity = Vector3.ZERO
		_player.set_physics_process(false)
		var main := get_tree().current_scene as Main
		if main:
			main.fade_to_level(level, LIGHT_COLOR)
		else:
			Main.change_level(get_tree(), level)
		return
	# Through this portal and out of the exit, turned around so a body entering this
	# portal's front comes out of the exit's front (and back out of back).
	var turn := Transform3D(Basis(Vector3.UP, PI), Vector3.ZERO)
	var through := _exit.global_transform * turn * global_transform.affine_inverse()
	_player.teleport(through * _player.global_transform, through.basis * _player.velocity)
	_has_prev = false
	_flare = 1.0
	_exit.arrive()


## Called on the exit portal once the player has come through it.
func arrive() -> void:
	# Remember which side the player is on so arriving doesn't count as a crossing.
	_prev = to_local(_player_node().global_position + Vector3.UP * BODY_HEIGHT)
	_has_prev = true
	_flare = 1.0
	_whoosh.play()


func _player_node() -> CharacterBody3D:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player") as CharacterBody3D
	return _player
