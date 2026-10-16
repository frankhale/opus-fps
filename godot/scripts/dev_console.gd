extends CanvasLayer
## Pop-up developer console. ~ (the key left of 1) opens and closes it; Esc closes it.
## It slides up over the bottom quarter of the screen on a see-through backdrop, with a scrolling
## log above a command line. While it is open the game is paused and the mouse is free,
## so typing never moves the player or fires.
##
## Commands are registered in _ready() with register(); each takes the words typed after
## its name. Up/Down step through earlier commands. The game has no other shortcut keys:
## switching level, the PS1 filter, fullscreen, the map, screenshots and quitting are all
## commands here. Toggles flip with no argument; 1 / 0 (or on / off) set them.

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
	register("sfx", _cmd_sfx, "Toggle sound effects (all game audio, ambience included). sfx 1 / sfx 0 to set it")
	register("ps1", _cmd_ps1, "Toggle the PS1 look (low-res render, dithering, 15-bit color). ps1 1 / ps1 0 to set it")
	register("fullscreen", _cmd_fullscreen, "Toggle fullscreen. fullscreen 1 / fullscreen 0 to set it")
	register("map", _cmd_map, "Hide or show the map (M still switches corner and large). map 1 / map 0 to set it")
	register("screenshot", _cmd_screenshot, "Close the console and save a screenshot to ~/Pictures/<game name>/")
	register("quit", func(_args): get_tree().quit(), "Quit the game")
	register("cat", _cmd_cat, "Send the shadow cat (on the island) off now: cat walk / cat trot / cat run")
	register("scene", _cmd_scene, "Switch scene: scene world / scene gallery / scene island. No name: show the current one")
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


func _main() -> Main:
	return get_tree().current_scene as Main


## A toggle's new state: flipped from `current` with no argument, else set by it.
func _switch(args: PackedStringArray, current: bool) -> bool:
	return not current if args.is_empty() else args[0].to_lower() in ["1", "on", "true"]


## Reports a toggle in the log and as a HUD message.
func _report(what: String, on: bool) -> void:
	var state := "ON" if on else "OFF"
	_print("%s [b]%s[/b]" % [what, state])
	var player := _player()
	if player:
		player.message.emit("%s %s" % [what, state])


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
	player.god_mode = _switch(args, player.god_mode)
	_report("God mode", player.god_mode)


## Mutes the Master bus, which every sound plays through. AudioServer is global, so the
## setting holds across switching to the gallery and back.
func _cmd_sfx(args: PackedStringArray) -> void:
	var bus := AudioServer.get_bus_index("Master")
	var on := _switch(args, not AudioServer.is_bus_mute(bus))
	AudioServer.set_bus_mute(bus, not on)
	_report("Sound effects", on)


## Switches to another level (see Main.LEVELS). The console is part of the game, which
## reloads, so it closes first; that also unpauses, as pausing belongs to the tree and
## would carry over.
func _cmd_scene(args: PackedStringArray) -> void:
	var names := " / ".join(Main.LEVELS.keys())
	if args.is_empty():
		_print("Current scene: [b]%s[/b]. Switch with: scene %s" % [Main.level, names])
		return
	var target := args[0].to_lower()
	if target in ["main", "game", "valley"]:
		target = "world"
	if not Main.LEVELS.has(target):
		_print("[color=#f88]Unknown scene: %s[/color] (try %s)" % [_escape(target), names])
		return
	if target == Main.level:
		_print("Already in [b]%s[/b]" % target)
		return
	_print("Loading [b]%s[/b]..." % target)
	toggle()
	Main.change_level.call_deferred(get_tree(), target)


func _cmd_ps1(args: PackedStringArray) -> void:
	var on := _switch(args, _main().is_ps1())
	_main().set_ps1(on)
	_report("PS1 filter", on)


func _cmd_fullscreen(args: PackedStringArray) -> void:
	var on := _switch(args, _main().is_fullscreen())
	_main().set_fullscreen(on)
	_report("Fullscreen", on)


func _cmd_map(args: PackedStringArray) -> void:
	var on := _switch(args, _main().is_minimap())
	_main().set_minimap(on)
	_report("Map", on)


## Closes the console first and waits for it to slide away, so it isn't in the picture.
func _cmd_screenshot(_args: PackedStringArray) -> void:
	toggle()
	await get_tree().create_timer(slide_time + 0.1).timeout
	await RenderingServer.frame_post_draw
	var path := _main().screenshot()
	_print("Saved [b]%s[/b]" % _escape(path) if path else "[color=#f88]Couldn't save the screenshot[/color]")


## Makes the shadow cat set off at once at the gait asked for, to see it.
func _cmd_cat(args: PackedStringArray) -> void:
	var gaits := ["walk", "trot", "run"]
	var gait := gaits.find(args[0].to_lower()) if not args.is_empty() else -1
	if gait < 0:
		_print("[color=#f88]Say how: cat walk / cat trot / cat run[/color]")
		return
	var cats := get_tree().get_nodes_in_group("shadow_cats")
	if cats.is_empty():
		_print("[color=#f88]No shadow cat here.[/color] It's on the island: scene island")
		return
	for cat: ShadowCat in cats:
		if not cat.set_out(gait):
			_print("[color=#f88]The cat won't %s now[/color] (it's hunting you, or has nowhere to go)" % gaits[gait])
			return
	_print("The shadow cat sets off at a [b]%s[/b]" % gaits[gait])
