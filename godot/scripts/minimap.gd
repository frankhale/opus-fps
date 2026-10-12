extends Control
## North-up map of the level with an arrow for the player's position and facing.
## The map is a top-down orthographic render of the world, taken once at startup
## (call refresh() to retake it). The corner minimap shows a window around the
## player that scrolls as they move; the "toggle_map" action shows the whole map.

@export var player_path: NodePath
## Viewport whose World3D is drawn (the game's SubViewport).
@export var world_viewport_path: NodePath
## Half-width of the area shown, in meters, centered on the world origin.
@export var world_extent := 42.0
## Render resolution of the whole map (about 0.44 m per pixel at the default extent).
@export var map_pixels := 192
## Map pixels visible across the corner minimap (64 px is about 28 m).
@export var window_pixels := 64
## Screen pixels per map pixel for the corner minimap and the full map.
@export var small_scale := 3
@export var large_scale := 2
@export var margin := 12.0

const FRAME_COLOR := Color(0.91, 0.85, 0.7)
const BACKDROP_COLOR := Color(0.08, 0.09, 0.1, 0.75)
const ARROW_COLOR := Color(0.91, 0.24, 0.2)

var _player: Node3D
var _map_viewport: SubViewport
var _large := false


func _ready() -> void:
	_player = get_node(player_path)
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_map_camera()
	get_viewport().size_changed.connect(_layout)
	_layout()


func _build_map_camera() -> void:
	_map_viewport = SubViewport.new()
	_map_viewport.size = Vector2i(map_pixels, map_pixels)
	_map_viewport.world_3d = (get_node(world_viewport_path) as Viewport).find_world_3d()
	_map_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	add_child(_map_viewport)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.13, 0.15, 0.16)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.64, 0.68)
	env.ambient_light_energy = 0.9
	env.fog_enabled = false

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = world_extent * 2.0
	cam.near = 1.0
	cam.far = 250.0
	# Looking straight down with screen-up = -Z, so north is up and +X is right.
	cam.position = Vector3(0.0, 120.0, 0.0)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	cam.environment = env
	cam.cull_mask = 1  # world only (no viewmodel layer)
	_map_viewport.add_child(cam)
	cam.current = true


func refresh() -> void:
	_map_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_map"):
		_large = not _large
		_layout()


func _layout() -> void:
	var side := float(map_pixels * large_scale if _large else window_pixels * small_scale)
	size = Vector2(side, side)
	var screen := get_viewport_rect().size
	position = (screen - size) / 2.0 if _large else Vector2(screen.x - side - margin, margin)
	queue_redraw()


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	draw_rect(Rect2(Vector2(-4, -4), size + Vector2(8, 8)), BACKDROP_COLOR)
	# World XZ -> map pixels (north-up: +X right, +Z down).
	var p := _player.global_position
	var player_px := Vector2(p.x + world_extent, p.z + world_extent) / (world_extent * 2.0) * map_pixels
	var region := Rect2(Vector2.ZERO, Vector2(map_pixels, map_pixels))
	if not _large:
		# Window centered on the player, held inside the map at its edges.
		var w := float(window_pixels)
		var origin := (player_px - Vector2(w, w) / 2.0).clamp(Vector2.ZERO, Vector2(map_pixels - w, map_pixels - w))
		region = Rect2(origin.round(), Vector2(w, w))
	draw_texture_rect_region(_map_viewport.get_texture(), Rect2(Vector2.ZERO, size), region)
	draw_rect(Rect2(Vector2.ZERO, size), FRAME_COLOR, false, 2.0)

	var font := ThemeDB.fallback_font
	var fs := 14 if _large else 11
	draw_string(font, Vector2(size.x / 2.0 - fs * 0.35, fs + 2.0), "N", HORIZONTAL_ALIGNMENT_LEFT, -1, fs, FRAME_COLOR)

	var center := ((player_px - region.position) * size / region.size).clamp(Vector2.ZERO, size)
	var yaw := _player.global_rotation.y
	var fwd := Vector2(-sin(yaw), -cos(yaw))
	var side := Vector2(-fwd.y, fwd.x)
	var r := 7.0 if _large else 5.0
	var arrow := PackedVector2Array([
		center + fwd * r * 1.6,
		center - fwd * r + side * r,
		center - fwd * r * 0.4,
		center - fwd * r - side * r,
	])
	draw_colored_polygon(arrow, ARROW_COLOR)
	arrow.append(arrow[0])
	draw_polyline(arrow, Color.BLACK, 1.5)
