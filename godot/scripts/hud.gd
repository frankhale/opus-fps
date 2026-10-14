extends CanvasLayer
## Player HUD: a health bar (bottom-left, see HealthBar) with the gem count above it
## (see GemCounter), the current weapon and its ammo as rows of rounds (bottom-right,
## see AmmoDisplay), pickup messages that fade
## out, a red flash when hurt, a death screen and, while a powerup lasts, its name and the
## seconds left (top middle, blinking over the last 3).

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


func _ready() -> void:
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


func show_message(text: String) -> void:
	message_label.text = text
	message_label.modulate.a = 1.0
	if _message_tween:
		_message_tween.kill()
	_message_tween = create_tween()
	_message_tween.tween_interval(1.6)
	_message_tween.tween_property(message_label, "modulate:a", 0.0, 0.6)
