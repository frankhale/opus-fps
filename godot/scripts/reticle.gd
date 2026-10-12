extends Control
## Aiming reticle drawn at the screen centre.
##  * its shape follows the weapon (cross, circle or dot) and its gap shows the
##    weapon's true current spread, which opens with firing and movement
##  * it turns red when an enemy is under the crosshair
##  * hit markers: a white X when a shot lands, a bigger red X on a kill
## Hidden while dead and while sprinting with the weapon lowered.

@export var weapons_path: NodePath
@export var hit_sound: AudioStream
@export var kill_sound: AudioStream

const COLOR := Color(0.95, 0.92, 0.85)
const ENEMY_COLOR := Color(1.0, 0.2, 0.15)
const OUTLINE := Color(0.0, 0.0, 0.0, 0.75)
const LINE := 2.0
const LENGTH := 9.0

var _weapons: WeaponManager
var _player: Node
var _gap := 6.0
var _on_enemy := false
var _hit_time := 0.0
var _hit_kill := false
var _audio: AudioStreamPlayer
var _last_sound_ms := 0


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_weapons = get_node(weapons_path)
	_player = _weapons.get_parent()
	_weapons.hit_confirmed.connect(_on_hit)
	_audio = AudioStreamPlayer.new()
	_audio.volume_db = -8.0
	add_child(_audio)


func _on_hit(killed: bool) -> void:
	_hit_kill = killed or (_hit_kill and _hit_time > 0.0)
	_hit_time = 0.35 if killed else maxf(_hit_time, 0.15)
	# Shotgun pellets land together; one tick per volley is enough.
	var now := Time.get_ticks_msec()
	if killed or now - _last_sound_ms > 60:
		_last_sound_ms = now
		_audio.stream = kill_sound if killed else hit_sound
		_audio.play()


func _process(delta: float) -> void:
	_hit_time = maxf(_hit_time - delta, 0.0)
	if _hit_time == 0.0:
		_hit_kill = false
	_on_enemy = _aiming_at_enemy()
	_gap = lerpf(_gap, _target_gap(), 1.0 - exp(-18.0 * delta))
	queue_redraw()


## Screen-space radius of the current spread cone at the reticle.
func _target_gap() -> float:
	var cam := _weapons.camera
	var spread := deg_to_rad(_weapons.current_spread())
	var half_height := get_viewport_rect().size.y / 2.0
	return maxf(tan(spread) / tan(deg_to_rad(cam.fov) / 2.0) * half_height, 3.0)


func _aiming_at_enemy() -> bool:
	if _weapons.current == null or _player.dead:
		return false
	var cam := _weapons.camera
	var from := cam.global_position
	var to := from - cam.global_basis.z * 200.0
	var q := PhysicsRayQueryParameters3D.create(from, to, 1 | Projectile.LAYER_ENEMIES, [_player.get_rid()])
	var hit := cam.get_world_3d().direct_space_state.intersect_ray(q)
	return hit and hit.collider is Node and (hit.collider as Node).is_in_group("enemies")


func _draw() -> void:
	if _player.dead:
		return
	var c := size / 2.0
	var w := _weapons.current
	var color := ENEMY_COLOR if _on_enemy else COLOR
	var lowered: bool = _weapons._sprint_pose > 0.5 or _weapons._switching

	if w == null:
		_dot(c, 2.0, color)
	elif not lowered:
		match w.reticle:
			"circle":
				_ring(c, maxf(_gap, 10.0), color)
				_dot(c, 1.5, color)
			"dot":
				_ring(c, 7.0 + _gap * 0.5, color)
				_dot(c, 2.0, color)
			_:
				var g := _gap + 2.0
				for d in [Vector2.UP, Vector2.DOWN, Vector2.LEFT, Vector2.RIGHT]:
					_line(c + d * g, c + d * (g + LENGTH), color)
				_dot(c, 1.0, color)

	if _hit_time > 0.0:
		var k := _hit_time / (0.35 if _hit_kill else 0.15)
		var hit_color := ENEMY_COLOR if _hit_kill else Color.WHITE
		hit_color.a = clampf(k * 1.5, 0.0, 1.0)
		var inner := 6.0
		var outer := 14.0 if _hit_kill else 11.0
		for d in [Vector2(1, 1), Vector2(-1, 1), Vector2(1, -1), Vector2(-1, -1)]:
			var n: Vector2 = d.normalized()
			_line(c + n * inner, c + n * outer, hit_color)


func _line(a: Vector2, b: Vector2, color: Color) -> void:
	var outline := OUTLINE
	outline.a *= color.a
	var d := (b - a).normalized()
	draw_line(a - d, b + d, outline, LINE + 2.0)
	draw_line(a, b, color, LINE)


func _dot(at: Vector2, r: float, color: Color) -> void:
	draw_circle(at, r + 1.0, OUTLINE)
	draw_circle(at, r, color)


func _ring(at: Vector2, r: float, color: Color) -> void:
	draw_arc(at, r, 0.0, TAU, 24, OUTLINE, LINE + 2.0)
	draw_arc(at, r, 0.0, TAU, 24, color, LINE)
