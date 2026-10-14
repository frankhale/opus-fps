class_name ShieldVeil
extends Node3D
## The invulnerability powerup's shield: a shimmering veil around the player while it lasts
## (materials/shield_veil.gdshader). It's a bubble around the camera that keeps its world
## orientation, so its ripples drift across the view as you turn. It flashes up when
## taken, hums, flickers over the last few seconds as a warning, flares toward any hit it
## turns away, and fades out with a falling chime. Lives under the Player.

const SHADER := preload("res://materials/shield_veil.gdshader")
const UP_SOUND := preload("res://assets/sfx/shield_up.wav")
const HUM_SOUND := preload("res://assets/sfx/shield_hum.wav")
const DOWN_SOUND := preload("res://assets/sfx/shield_down.wav")

## The veil starts flickering this many seconds before it runs out.
@export var warning_time := 3.0
@export var radius := 0.6

var _player: Node3D
var _camera: Camera3D
var _mesh: MeshInstance3D
var _material: ShaderMaterial
var _hum: AudioStreamPlayer
var _light: OmniLight3D
var _strength := 0.0
var _hit := 0.0
var _active := false
var _t := 0.0


func _ready() -> void:
	_player = get_parent()
	_camera = _player.get_node("Head/Camera3D")
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 24
	sphere.rings = 12
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	_mesh = MeshInstance3D.new()
	_mesh.mesh = sphere
	_mesh.material_override = _material
	_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mesh.top_level = true  # keeps its world orientation instead of turning with the player
	_mesh.visible = false
	add_child(_mesh)
	# A faint cyan glow on the ground and walls around the player.
	_light = OmniLight3D.new()
	_light.light_color = Pickup.POWERUP_COLOR
	_light.omni_range = 4.0
	_light.light_energy = 0.0
	_light.position.y = 1.2
	add_child(_light)
	_hum = AudioStreamPlayer.new()
	_hum.stream = HUM_SOUND
	_hum.volume_db = -14.0
	add_child(_hum)
	_player.powerup_started.connect(_on_started)
	_player.powerup_ended.connect(_on_ended)
	_player.shield_hit.connect(_on_hit)


func _process(delta: float) -> void:
	if not _mesh.visible:
		return
	_t += delta
	_mesh.global_position = _camera.global_position
	var target := 0.0
	if _active:
		target = 1.0
		var left: float = _player.invulnerable_time
		if left < warning_time:
			# Flicker, faster as it runs out.
			var rate := lerpf(14.0, 5.0, left / warning_time)
			target = 0.25 if fmod(_t * rate, 2.0) < 0.8 else 1.0
	_strength = move_toward(_strength, target, delta * (6.0 if _active else 2.5))
	_hit = move_toward(_hit, 0.0, delta * 2.5)
	_material.set_shader_parameter("strength", _strength + _hit * 0.5)
	_material.set_shader_parameter("hit", _hit)
	_light.light_energy = (_strength * 0.6 + _hit) * (1.0 + 0.15 * sin(_t * 9.0))
	_hum.volume_db = linear_to_db(maxf(_strength, 0.001)) - 14.0
	if not _active and _strength <= 0.0:
		_mesh.visible = false
		_light.light_energy = 0.0
		_hum.stop()


func _on_started(powerup: String, _duration: float) -> void:
	if powerup != "invulnerability":
		return
	_active = true
	_mesh.visible = true
	_hit = 1.0  # bright flash as it comes up
	_play(UP_SOUND, -4.0)
	if not _hum.playing:
		_hum.play()


func _on_ended(powerup: String) -> void:
	if powerup != "invulnerability" or not _active:
		return
	_active = false
	_play(DOWN_SOUND, -6.0)


func _on_hit(_amount: float, from: Vector3) -> void:
	_hit = 1.0
	var dir := from - _camera.global_position
	if from != Vector3.ZERO and dir.length() > 0.01:
		_material.set_shader_parameter("hit_dir", dir.normalized())


func _play(stream: AudioStream, volume: float) -> void:
	var s := AudioStreamPlayer.new()
	s.stream = stream
	s.volume_db = volume
	add_child(s)
	s.play()
	s.finished.connect(s.queue_free)
