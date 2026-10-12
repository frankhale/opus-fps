extends Control
## Hosts the game world in a low-resolution SubViewport that is upscaled with
## nearest-neighbour filtering and run through the PS1 dither/color-depth shader.
## Also owns mouse capture (click to capture, Esc to release), F1 toggles the PS1 filter
## F11 / Alt+Enter toggles fullscreen (the game starts fullscreen) and Cmd+Q quits.

## Approximate vertical resolution to render at. The PS1 mostly ran at 240 lines;
## 480 (its high-res mode) keeps the chunky look but with finer pixels.
@export var target_lines := 480

@onready var container: SubViewportContainer = $SubViewportContainer
@onready var hint: Label = $HUD/Hint

var _post: Material
var _ps1_enabled := true


func _ready() -> void:
	_post = container.material
	get_viewport().size_changed.connect(_apply_resolution)
	_apply_resolution()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _apply_resolution() -> void:
	var height := get_viewport().get_visible_rect().size.y
	container.stretch_shrink = maxi(1, roundi(height / target_lines)) if _ps1_enabled else 1
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
			KEY_Q:
				if event.meta_pressed:
					get_tree().quit()


func _toggle_fullscreen() -> void:
	var fullscreen := DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED if fullscreen else DisplayServer.WINDOW_MODE_FULLSCREEN)
