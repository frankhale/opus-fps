extends CanvasLayer
## Pop-up developer console. ~ (the key left of 1) opens and closes it; Esc closes it.
## It slides up over the bottom quarter of the screen on a see-through backdrop, with a scrolling
## log above a command line. While it is open the game is paused and the mouse is free,
## so typing never moves the player or fires.
##
## Commands are registered in _ready() with register(); each takes the words typed after
## its name. Up/Down step through earlier commands.

## Share of the screen height the console covers.
@export var height_ratio := 0.25
## Seconds to slide open or shut.
@export var slide_time := 0.12

var _panel: ColorRect
var _log: RichTextLabel
var _field: LineEdit
var _commands := {}  # name -> {"run": Callable, "help": String}
var _history: PackedStringArray = []
var _history_pos := 0
var _open := false
var _tween: Tween
var _was_captured := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS  # keeps working while the game is paused
	_build()
	_panel.visible = false
	register("help", _cmd_help, "List commands")
	register("clear", func(_args): _log.clear(), "Clear the console")
	register("god", _cmd_god, "Toggle god mode: no damage, every weapon, unlimited ammo. god 1 / god 0 to set it")
	_print("[color=#8f8]Opus FPS console[/color] - type [b]help[/b] for commands")


## Adds a command. `run` gets the words after the command name as a PackedStringArray.
func register(command: String, run: Callable, help := "") -> void:
	_commands[command] = {"run": run, "help": help}


func _build() -> void:
	_panel = ColorRect.new()
	_panel.color = Color(0.02, 0.03, 0.05, 0.6)
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_panel.anchor_top = 1.0 - height_ratio
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_panel)

	var edge := ColorRect.new()  # thin rule along the top
	edge.color = Color(0.55, 0.8, 0.55, 0.5)
	edge.set_anchors_preset(Control.PRESET_TOP_WIDE)
	edge.offset_bottom = 1.0
	edge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(edge)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 10.0
	box.offset_top = 6.0
	box.offset_right = -10.0
	box.offset_bottom = -6.0
	_panel.add_child(box)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 14)
	_log.add_theme_font_size_override("bold_font_size", 14)
	_log.add_theme_color_override("default_color", Color(0.85, 0.88, 0.85))
	box.add_child(_log)

	_field = LineEdit.new()
	_field.placeholder_text = "command"
	_field.keep_editing_on_text_submit = true
	_field.context_menu_enabled = false
	_field.add_theme_font_size_override("font_size", 14)
	_field.add_theme_color_override("font_color", Color(0.75, 1.0, 0.75))
	var field := StyleBoxFlat.new()
	field.bg_color = Color(0.0, 0.0, 0.0, 0.35)
	field.content_margin_left = 6.0
	field.content_margin_right = 6.0
	field.content_margin_top = 2.0
	field.content_margin_bottom = 2.0
	_field.add_theme_stylebox_override("normal", field)
	_field.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_field.text_submitted.connect(_submit)
	box.add_child(_field)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed):
		return
	if event.physical_keycode == KEY_QUOTELEFT:
		# Handled here, before the text field sees it, so no ` or ~ ends up typed.
		get_viewport().set_input_as_handled()
		if not event.echo:
			toggle()
	elif _open:
		match event.keycode:
			KEY_ESCAPE:
				get_viewport().set_input_as_handled()
				toggle()
			KEY_UP:
				get_viewport().set_input_as_handled()
				_step_history(-1)
			KEY_DOWN:
				get_viewport().set_input_as_handled()
				_step_history(1)


func toggle() -> void:
	_open = not _open
	get_tree().paused = _open
	if _tween:
		_tween.kill()
	_tween = create_tween()
	if _open:
		_was_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_panel.visible = true
		_panel.position.y = _shown_y() + _panel.size.y
		_tween.tween_property(_panel, "position:y", _shown_y(), slide_time)
		_field.clear()
		_field.grab_focus()
		_field.edit()
	else:
		_field.unedit()
		_field.release_focus()
		if _was_captured:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		_tween.tween_property(_panel, "position:y", _shown_y() + _panel.size.y, slide_time)
		_tween.tween_callback(_panel.hide)


## Top of the panel when fully open (anchored to the bottom quarter of the screen).
func _shown_y() -> float:
	return _panel.get_parent_area_size().y * (1.0 - height_ratio)


func _submit(text: String) -> void:
	_field.clear()
	text = text.strip_edges()
	if text.is_empty():
		return
	if _history.is_empty() or _history[-1] != text:
		_history.append(text)
	_history_pos = _history.size()
	_print("[color=#9a9]> %s[/color]" % _escape(text))
	var words := text.split(" ", false)
	var command := words[0].to_lower()
	if not _commands.has(command):
		_print("[color=#f88]Unknown command: %s[/color]" % _escape(command))
		return
	_commands[command].run.call(words.slice(1))


func _step_history(step: int) -> void:
	if _history.is_empty():
		return
	_history_pos = clampi(_history_pos + step, 0, _history.size())
	_field.text = _history[_history_pos] if _history_pos < _history.size() else ""
	_field.caret_column = _field.text.length()


func _print(bbcode: String) -> void:
	_log.append_text(bbcode + "\n")


func _escape(text: String) -> String:
	return text.replace("[", "[lb]")


func _player() -> Node:
	return get_tree().get_first_node_in_group("player")


# Commands

func _cmd_help(_args: PackedStringArray) -> void:
	var names := _commands.keys()
	names.sort()
	for command in names:
		_print("  [b]%s[/b]  %s" % [command, _commands[command].help])


func _cmd_god(args: PackedStringArray) -> void:
	var player := _player()
	if player == null:
		_print("[color=#f88]No player[/color]")
		return
	if args.is_empty():
		player.god_mode = not player.god_mode
	else:
		player.god_mode = args[0] in ["1", "on", "true"]
	var state := "ON" if player.god_mode else "OFF"
	_print("God mode [b]%s[/b]" % state)
	player.message.emit("God mode " + state)
