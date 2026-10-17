class_name Main
extends Control
## The game around a level: the world (sky, sun, fog and the player, scenes/world.tscn),
## the HUD and the dev console. When it starts it loads the chosen level (see LEVELS) into
## the world; change_level() switches to another by reloading the whole game with it.
##
## Hosts the game world in a low-resolution SubViewport that is upscaled with
## nearest-neighbour filtering and run through the PS1 dither/color-depth shader.
## Also owns mouse capture (click to capture, Esc to release). The rest of its settings
## are worked from the dev console (scripts/dev_console.gd): set_ps1(), set_fullscreen()
## (the game starts fullscreen), set_minimap(), screenshot() and change_level().
## A portal to another level uses fade_to_level() instead: the screen fades to the
## portal's light, the level changes behind it and fades in from it. preload_level()
## starts loading a level in the background beforehand, so the change is quicker.

## Approximate vertical resolution to render at, in lines (each pixel a whole number of
## screen pixels). The PS1 mostly ran at 240 lines; 480 (its high-res mode) keeps the
## chunky look but with finer pixels.
@export var target_lines := 480
## The levels, by the name the dev console's `scene` command takes. Each is a plain scene
## holding just that level, so opening it in the editor shows exactly what you play.
const LEVELS := {
	"hub": "res://scenes/hub.tscn",
	"world": "res://scenes/level.tscn",
	"gallery": "res://scenes/gallery.tscn",
	"island": "res://scenes/island.tscn",
}
const MAIN_SCENE := "res://scenes/main.tscn"
## Fading to a level: seconds to fade out to the color, and for the new level to fade in
## from it.
const FADE_OUT := 0.15
const FADE_IN := 0.5

## The level the game loads when it starts: a key of LEVELS. It starts in the hub, whose
## portals lead to the others. Static, so it holds while change_level() reloads the game.
static var level := "hub"
## The console's PS1 filter and map settings. Static too, so they hold across levels.
static var _ps1_enabled := true
static var _minimap_shown := true
## The color the next level fades in from (none if clear).
static var _arrive_color := Color.TRANSPARENT

@onready var container: SubViewportContainer = $SubViewportContainer
@onready var hud: CanvasLayer = $HUD
@onready var minimap: Control = $HUD/Minimap

var _post: Material


## Plays the game in another level (a key of LEVELS).
static func change_level(tree: SceneTree, level_name: String) -> void:
	level = level_name
	tree.change_scene_to_file(MAIN_SCENE)


## Starts loading a level (a key of LEVELS) in the background, so changing to it later
## doesn't wait for the disk.
static func preload_level(level_name: String) -> void:
	var path: String = LEVELS[level_name]
	if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		ResourceLoader.load_threaded_request(path)


## Fades the screen to `color`, then changes level (see change_level()); the new level
## fades in from the same color, covering the moment it takes to build.
func fade_to_level(level_name: String, color: Color) -> void:
	var cover := _cover(Color(color, 0.0))
	var fade := create_tween()
	fade.tween_property(cover, "color:a", 1.0, FADE_OUT)
	fade.tween_callback(func() -> void:
		_arrive_color = color
		change_level(get_tree(), level_name))


## A full-screen color over everything, HUD included.
func _cover(color: Color) -> ColorRect:
	var layer := CanvasLayer.new()
	layer.layer = 100
	add_child(layer)
	var rect := ColorRect.new()
	rect.color = color
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(rect)
	return rect


## Puts the level into the world before anything in it is ready, ahead of the player, so
## it's in place as the game starts.
func _enter_tree() -> void:
	var world := $SubViewportContainer/SubViewport/World
	var path: String = LEVELS[level]
	var scene: PackedScene
	if ResourceLoader.load_threaded_get_status(path) != ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		scene = ResourceLoader.load_threaded_get(path)  # loaded ahead (preload_level()); waits if not done
	else:
		scene = load(path)
	var node := scene.instantiate()
	node.name = "Level"
	world.add_child(node)
	world.move_child(node, world.get_node("Player").get_index())


func _ready() -> void:
	_post = container.material
	get_viewport().size_changed.connect(_apply_resolution)
	_apply_resolution()
	minimap.visible = _minimap_shown
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if _arrive_color.a > 0.0:
		# Arrived through a portal: fade in from its light.
		var cover := _cover(_arrive_color)
		_arrive_color = Color.TRANSPARENT
		var fade := create_tween()
		fade.tween_property(cover, "color:a", 0.0, FADE_IN).set_ease(Tween.EASE_IN)
		fade.tween_callback(cover.get_parent().queue_free)


## Renders the world at about target_lines and blows it up to fill the screen. The
## pixel size is a whole number of physical screen pixels, so every pixel comes out the
## same size, but the stretch in canvas units can be fractional (with the 720-unit
## canvas on a 1440p screen, 3 screen pixels is 1.5 units), which stretch_shrink, being
## whole-number only, can't do; so the container is scaled instead.
func _apply_resolution() -> void:
	var view_size := get_viewport().get_visible_rect().size
	var screen_per_unit := float(get_window().size.y) / view_size.y
	var pixel := maxf(1.0, roundf(get_window().size.y / float(target_lines))) if _ps1_enabled else 1.0
	var scale_units := maxf(pixel / screen_per_unit, 1.0)
	container.stretch_shrink = 1
	container.set_anchors_preset(Control.PRESET_TOP_LEFT)
	container.scale = Vector2.ONE * scale_units
	container.size = (view_size / scale_units).ceil()
	container.material = _post if _ps1_enabled else null


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_S \
			and event.is_command_or_control_pressed():
		# Cmd+S (Ctrl+S off macOS): a quick screenshot into Documents.
		get_viewport().set_input_as_handled()
		screenshot(OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS))
	elif event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func is_ps1() -> bool:
	return _ps1_enabled


## Turns the PS1 look (low-res render, dithering and 15-bit color) on or off.
func set_ps1(on: bool) -> void:
	_ps1_enabled = on
	_apply_resolution()


func is_fullscreen() -> bool:
	return DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN


func set_fullscreen(on: bool) -> void:
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if on else DisplayServer.WINDOW_MODE_WINDOWED)


## Hides or shows the map, corner and large alike.
func set_minimap(on: bool) -> void:
	_minimap_shown = on
	minimap.visible = on


func is_minimap() -> bool:
	return _minimap_shown


## Saves what's on screen (HUD included) as a PNG in `dir`, by default the game's folder
## in the user's Pictures, and returns its path ("" if it couldn't).
func screenshot(dir := "") -> String:
	var image := get_viewport().get_texture().get_image()
	if dir == "":
		dir = OS.get_system_dir(OS.SYSTEM_DIR_PICTURES).path_join(ProjectSettings.get_setting("application/config/name"))
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_string_from_system().replace("T", "_").replace(":", "-")
	var path := dir.path_join("screenshot_%s.png" % stamp)
	var n := 2
	while FileAccess.file_exists(path):  # several in the same second
		path = dir.path_join("screenshot_%s_%d.png" % [stamp, n])
		n += 1
	if image.save_png(path) == OK:
		hud.show_message("Screenshot saved: " + path.get_file())
		return path
	hud.show_message("Couldn't save screenshot to " + dir)
	return ""
