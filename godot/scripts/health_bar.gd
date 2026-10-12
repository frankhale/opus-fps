class_name HealthBar
extends Control
## Health bar that fades from green through yellow to red as health runs out. The
## fill eases to its new value, and damage leaves a pale chunk behind that drains
## away a moment later so the size of each hit is easy to read.

const FULL_COLOR := Color(0.3, 0.85, 0.25)
const HALF_COLOR := Color(0.95, 0.85, 0.2)
const EMPTY_COLOR := Color(0.9, 0.15, 0.1)
const FRAME_COLOR := Color(0.91, 0.85, 0.7)
const BACKDROP_COLOR := Color(0.08, 0.09, 0.1, 0.75)
const TRAIL_COLOR := Color(1.0, 0.95, 0.85, 0.7)

## Seconds the fill takes to reach a new value, and the damage chunk's wait before draining.
const FILL_TIME := 0.15
const TRAIL_DELAY := 0.35
const TRAIL_TIME := 0.4

## Displayed fractions (0..1) of the fill and of the damage trail behind it.
var _fill := 1.0
var _trail := 1.0
var _tween: Tween


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func set_health(health: float, max_health: float) -> void:
	var target := clampf(health / maxf(max_health, 1.0), 0.0, 1.0)
	if _tween:
		_tween.kill()
	_tween = create_tween().set_parallel()
	_tween.tween_method(_set_fill, _fill, target, FILL_TIME)
	if target < _trail:
		_tween.tween_method(_set_trail, _trail, target, TRAIL_TIME).set_delay(TRAIL_DELAY)
	else:
		_trail = target  # healing: no trail, the fill grows into place


func _set_fill(v: float) -> void:
	_fill = v
	queue_redraw()


func _set_trail(v: float) -> void:
	_trail = v
	queue_redraw()


## Green at full health, yellow at half, red when empty.
static func color_for(fraction: float) -> Color:
	if fraction >= 0.5:
		return HALF_COLOR.lerp(FULL_COLOR, (fraction - 0.5) * 2.0)
	return EMPTY_COLOR.lerp(HALF_COLOR, fraction * 2.0)


func _draw() -> void:
	var inner := Rect2(Vector2.ZERO, size)
	draw_rect(inner.grow(3.0), BACKDROP_COLOR)
	if _trail > _fill:
		draw_rect(Rect2(inner.size.x * _fill, 0.0, inner.size.x * (_trail - _fill), inner.size.y), TRAIL_COLOR)
	var c := color_for(_fill)
	var fill := Rect2(Vector2.ZERO, Vector2(inner.size.x * _fill, inner.size.y))
	draw_rect(fill, c)
	# A lighter band along the top gives the fill a little depth.
	draw_rect(Rect2(fill.position, Vector2(fill.size.x, fill.size.y * 0.3)), c.lightened(0.25))
	draw_rect(inner, FRAME_COLOR, false, 2.0)
