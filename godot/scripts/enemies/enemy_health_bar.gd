class_name EnemyHealthBar
extends MeshInstance3D
## A health bar floating over an enemy (Enemy adds one over its model), so you can see
## how much health it has left as you shoot it. It looks and behaves like the HUD's
## (HealthBar): green at full health through yellow to red, easing to each new value,
## and each hit leaves a pale chunk that drains away a moment later. It shows when the
## enemy is hit and fades out once it hasn't been hit for FADE_AFTER seconds, coming
## back with the next hit. Drawn by materials/enemy_health_bar.gdshader, which turns it
## to face the camera and keeps it readable far off.

const SHADER := preload("res://materials/enemy_health_bar.gdshader")
## Its size up close (m).
const SIZE := Vector2(1.0, 0.16)
const FADE_AFTER := 6.0
const FADE_IN := 0.1
const FADE_OUT := 0.6

var _mat: ShaderMaterial
## Displayed fractions (0..1) of the fill and of the damage trail behind it.
var _fill := 1.0
var _trail := 1.0
var _tween: Tween
## Seconds since the last hit, and how far it's faded in (0 to 1).
var _since_hit := INF
var _shown := 0.0


func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	mesh = quad
	_mat = ShaderMaterial.new()
	_mat.shader = SHADER
	_mat.set_shader_parameter("size", SIZE)
	_mat.render_priority = 2  # over the see-through things round it, like the sea
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The shader moves the quad about (facing the camera, growing with distance).
	custom_aabb = AABB(Vector3(-4, -1, -4), Vector3(8, 2, 8))
	layers = Enemy.ENEMY_VISUAL_LAYER  # off the minimap, like the enemy
	visible = false
	_apply()


## A hit: shows the bar and moves it to the new health.
func set_health(health: float, max_health: float) -> void:
	var target := clampf(health / maxf(max_health, 1.0), 0.0, 1.0)
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel()
	_tween.tween_method(_set_fill, _fill, target, HealthBar.FILL_TIME)
	if target < _trail:
		_tween.tween_method(_set_trail, _trail, target, HealthBar.TRAIL_TIME).set_delay(HealthBar.TRAIL_DELAY)
	else:
		_trail = target
	_since_hit = 0.0


## Full again and out of sight (the enemy died or came back).
func reset() -> void:
	if _tween:
		_tween.kill()
	_fill = 1.0
	_trail = 1.0
	_since_hit = INF
	_shown = 0.0
	visible = false


func _process(delta: float) -> void:
	_since_hit += delta
	var want := 1.0 if _since_hit < FADE_AFTER else 0.0
	_shown = move_toward(_shown, want, delta / (FADE_IN if want > _shown else FADE_OUT))
	visible = _shown > 0.0
	if visible:
		_apply()


func _set_fill(v: float) -> void:
	_fill = v


func _set_trail(v: float) -> void:
	_trail = v


func _apply() -> void:
	_mat.set_shader_parameter("fill", _fill)
	_mat.set_shader_parameter("trail", maxf(_trail, _fill))
	_mat.set_shader_parameter("fill_color", HealthBar.color_for(_fill))
	_mat.set_shader_parameter("opacity", _shown)
