extends Control
## Hosts the game world in a low-resolution SubViewport that is upscaled with
## nearest-neighbour filtering and run through the PS1 dither/color-depth shader.
## Also owns mouse capture (click to capture, Esc to release), F1 toggles the PS1 filter,
## F2 shows or hides the controls help (hidden at start),
## F11, Cmd+Ctrl+F or Alt+Enter toggles fullscreen (the game starts fullscreen) and Cmd+Q
## quits. macOS takes F11 for Show Desktop by default, so Cmd+Ctrl+F (its own full-screen
## shortcut) is the one that works there out of the box. Cmd+1 switches between the game
## and the model gallery. F12 saves a screenshot to ~/Pictures/<project name>/. Cmd+M
## hides or shows the minimap.

## Approximate vertical resolution to render at, in lines (each pixel a whole number of
## screen pixels). The PS1 mostly ran at 240 lines; 480 (its high-res mode) keeps the
## chunky look but with finer pixels.
@export var target_lines := 480
## Replaces the world's level when set (the model gallery runs the game this way).
@export var level_scene: PackedScene

const GAME_SCENE := "res://scenes/main.tscn"
const GALLERY_SCENE := "res://scenes/gallery.tscn"

@onready var container: SubViewportContainer = $SubViewportContainer
@onready var hint: Label = $HUD/Hint
@onready var hud: CanvasLayer = $HUD
@onready var minimap: Control = $HUD/Minimap

var _post: Material
var _ps1_enabled := true


func _ready() -> void:
	if level_scene:
		var old := $SubViewportContainer/SubViewport/World/Level
		var level := level_scene.instantiate()
		old.add_sibling(level)
		old.get_parent().remove_child(old)
		old.free()
		level.name = "Level"
	_post = container.material
	get_viewport().size_changed.connect(_apply_resolution)
	_apply_resolution()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


## Renders the world at about target_lines and blows it up to fill the screen. The
## pixel size is a whole number of physical screen pixels, so every pixel comes out the
## same size, but the stretch in canvas units can be fractional (with the 720-unit
## canvas on a 1440p screen, 3 screen pixels is 1.5 units), which stretch_shrink, being
## whole-number only, can't do; so the container is scaled instead.
func _apply_resolution() -> void:
	var visible := get_viewport().get_visible_rect().size
	var screen_per_unit := float(get_window().size.y) / visible.y
	var pixel := maxf(1.0, roundf(get_window().size.y / float(target_lines))) if _ps1_enabled else 1.0
	var scale_units := maxf(pixel / screen_per_unit, 1.0)
	container.stretch_shrink = 1
	container.set_anchors_preset(Control.PRESET_TOP_LEFT)
	container.scale = Vector2.ONE * scale_units
	container.size = (visible / scale_units).ceil()
	container.material = _post if _ps1_enabled else null


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_F1:
				_ps1_enabled = not _ps1_enabled
				_apply_resolution()
			KEY_F2:
				hint.visible = not hint.visible
			KEY_F11:
				_toggle_fullscreen()
			KEY_ENTER:
				if event.alt_pressed:
					_toggle_fullscreen()
			KEY_F:
				if event.meta_pressed and event.ctrl_pressed:
					_toggle_fullscreen()
			KEY_Q:
				if event.meta_pressed:
					get_tree().quit()
			KEY_F12:
				_screenshot()
			KEY_M:
				if event.meta_pressed:
					minimap.visible = not minimap.visible
					get_viewport().set_input_as_handled()  # not also M's map toggle
			KEY_1:
				if event.meta_pressed:
					get_viewport().set_input_as_handled()
					get_tree().change_scene_to_file(GAME_SCENE if level_scene else GALLERY_SCENE)


func _toggle_fullscreen() -> void:
	var fullscreen := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if fullscreen else DisplayServer.WINDOW_MODE_FULLSCREEN)


## Saves what's on screen (HUD included) as a PNG in the user's Pictures folder.
func _screenshot() -> void:
	var image := get_viewport().get_texture().get_image()
	var dir := OS.get_system_dir(OS.SYSTEM_DIR_PICTURES).path_join(ProjectSettings.get_setting("application/config/name"))
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp := Time.get_datetime_string_from_system().replace("T", "_").replace(":", "-")
	var path := dir.path_join("screenshot_%s.png" % stamp)
	var n := 2
	while FileAccess.file_exists(path):  # several in the same second
		path = dir.path_join("screenshot_%s_%d.png" % [stamp, n])
		n += 1
	if image.save_png(path) == OK:
		hud.show_message("Screenshot saved: " + path.get_file())
	else:
		hud.show_message("Couldn't save screenshot to " + dir)
