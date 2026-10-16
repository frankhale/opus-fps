extends CanvasLayer
## Player HUD: a health bar (bottom-left, see HealthBar) with the gem count above it
## (see GemCounter), the current weapon and its ammo as rows of rounds (bottom-right,
## see AmmoDisplay), pickup messages that fade
## out, a red flash when hurt, milky droplets running down the screen when sprayed with a
## spider's toxin (splash(), called through the "hud" group), a death screen and, while a
## powerup lasts, its name and the seconds left (top middle, blinking over the last 3).

@export var weapons_path: NodePath

@onready var weapon_label: Label = $WeaponName
@onready var ammo_display: AmmoDisplay = $AmmoDisplay
@onready var health_bar: HealthBar = $HealthBar
@onready var gem_counter: GemCounter = $GemCounter
@onready var message_label: Label = $Message
@onready var damage_flash: ColorRect = $DamageFlash
@onready var death_screen: Control = $DeathScreen

var _weapons: WeaponManager
var _player: Node
var _message_tween: Tween
var _flash_tween: Tween
var _powerup_label: Label
var _splash: TextureRect
var _splash_tween: Tween


func _ready() -> void:
	add_to_group("hud")
	_weapons = get_node(weapons_path)
	_player = _weapons.get_parent()
	_weapons.weapon_changed.connect(func(_w): _refresh())
	_weapons.ammo_changed.connect(func(_t, _a): _refresh())
	_weapons.message.connect(show_message)
	_player.message.connect(show_message)
	_player.health_changed.connect(_on_health)
	_player.damaged.connect(_on_damaged)
	_player.gems_changed.connect(gem_counter.set_count)
	_player.died.connect(func(): death_screen.visible = true)
	_player.respawned.connect(func(): death_screen.visible = false)
	death_screen.visible = false
	_powerup_label = Label.new()
	var settings := LabelSettings.new()
	settings.font_size = 22
	settings.font_color = Pickup.POWERUP_COLOR
	settings.outline_size = 6
	settings.outline_color = Color(0, 0, 0, 0.85)
	_powerup_label.label_settings = settings
	_powerup_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_powerup_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_powerup_label.offset_left = -200.0
	_powerup_label.offset_right = 200.0
	_powerup_label.offset_top = 24.0
	_powerup_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_powerup_label.visible = false
	add_child(_powerup_label)
	damage_flash.modulate.a = 0.0
	_splash = TextureRect.new()
	_splash.texture = _make_splash_texture()
	_splash.stretch_mode = TextureRect.STRETCH_SCALE
	_splash.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_splash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_splash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_splash.modulate.a = 0.0
	add_child(_splash)
	move_child(_splash, damage_flash.get_index())
	_refresh()
	_on_health(_player.health, _player.max_health)
	show_message("Find a weapon")


func _process(_delta: float) -> void:
	var left: float = _player.invulnerable_time
	_powerup_label.visible = left > 0.0 and (left > 3.0 or fmod(left, 0.5) > 0.2)
	if _powerup_label.visible:
		_powerup_label.text = "INVULNERABLE  %d" % ceili(left)


func _refresh() -> void:
	var w := _weapons.current
	weapon_label.visible = w != null
	if w == null:
		ammo_display.show_ammo("", 0)
		return
	weapon_label.text = "%d  %s" % [w.slot, w.display_name.to_upper()]
	ammo_display.show_ammo(w.ammo_type, _weapons.ammo[w.ammo_type])


func _on_health(health: float, max_health: float) -> void:
	health_bar.set_health(health, max_health)


func _on_damaged(amount: float, _from: Vector3) -> void:
	if _flash_tween:
		_flash_tween.kill()
	damage_flash.modulate.a = clampf(0.25 + amount / 40.0, 0.3, 0.7)
	_flash_tween = create_tween()
	_flash_tween.tween_property(damage_flash, "modulate:a", 0.0, 0.45)


## Splattered by a spider's toxin: droplets cover the screen and slide down as they fade.
func splash(strength: float) -> void:
	if _splash_tween:
		_splash_tween.kill()
	_splash.modulate.a = maxf(_splash.modulate.a, clampf(strength, 0.0, 1.0) * 0.85)
	_splash.position.y = 0.0
	var size_y := _splash.size.y
	_splash_tween = create_tween().set_parallel()
	_splash_tween.tween_property(_splash, "modulate:a", 0.0, 1.6).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	_splash_tween.tween_property(_splash, "position:y", size_y * 0.06, 1.6)


## Scattered milky drops, mostly toward the edges so the middle of the view stays
## clear, each with a thin, tapering trail where it has run down. Chunky, like the rest
## of the PS1 look.
static func _make_splash_texture() -> Texture2D:
	const W := 480
	const H := 270
	var img := Image.create(W, H, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var placed := 0
	while placed < 60:
		var c := Vector2(rng.randf() * W, rng.randf() * H)
		var from_mid := ((c - Vector2(W, H) / 2.0) / (Vector2(W, H) / 2.0)).length()
		if rng.randf() > smoothstep(0.35, 0.9, from_mid):
			continue
		placed += 1
		var r := rng.randf_range(1.5, 4.5)
		var trail := rng.randf_range(0.0, 22.0) if rng.randf() < 0.6 else 0.0
		_paint_drop(img, c, r, trail)
	return ImageTexture.create_from_image(img)


static func _paint_drop(img: Image, c: Vector2, r: float, trail: float) -> void:
	var w := img.get_width()
	var h := img.get_height()
	for y in range(int(c.y - r - trail) - 1, int(c.y + r) + 2):
		for x in range(int(c.x - r) - 1, int(c.x + r) + 2):
			if x < 0 or y < 0 or x >= w or y >= h:
				continue
			var a := 0.0
			var d := Vector2(x + 0.5 - c.x, y + 0.5 - c.y).length() / r
			if d <= 1.0:
				# A clear-ish milky body with a brighter rim and a glint up and to the left.
				a = 0.4 + 0.4 * smoothstep(0.55, 1.0, d)
				if Vector2(x + 0.5 - c.x + r * 0.35, y + 0.5 - c.y + r * 0.35).length() < r * 0.3:
					a = 0.95
			elif trail > 0.0 and y < c.y:
				# The streak it left above it as it ran down: thin, fading upward.
				var up := (c.y - y) / trail
				var half := r * 0.35 * (1.0 - up)
				if up < 1.0 and absf(x + 0.5 - c.x) < maxf(half, 0.5):
					a = 0.35 * (1.0 - up)
			if a > img.get_pixel(x, y).a:
				img.set_pixel(x, y, Color(0.96, 0.98, 1.0, a))


func show_message(text: String) -> void:
	message_label.text = text
	message_label.modulate.a = 1.0
	if _message_tween:
		_message_tween.kill()
	_message_tween = create_tween()
	_message_tween.tween_interval(1.6)
	_message_tween.tween_property(message_label, "modulate:a", 0.0, 0.6)
