extends CanvasLayer
## Player HUD: health (bottom-left), current weapon and ammo (bottom-right, red when
## low), pickup messages that fade out, a red flash when hurt and a death screen.

@export var weapons_path: NodePath

@onready var weapon_label: Label = $WeaponName
@onready var ammo_label: Label = $AmmoCount
@onready var health_label: Label = $HealthCount
@onready var message_label: Label = $Message
@onready var damage_flash: ColorRect = $DamageFlash
@onready var death_screen: Control = $DeathScreen

var _weapons: WeaponManager
var _player: Node
var _message_tween: Tween
var _flash_tween: Tween


func _ready() -> void:
	_weapons = get_node(weapons_path)
	_player = _weapons.get_parent()
	_weapons.weapon_changed.connect(func(_w): _refresh())
	_weapons.ammo_changed.connect(func(_t, _a): _refresh())
	_weapons.message.connect(show_message)
	_player.message.connect(show_message)
	_player.health_changed.connect(_on_health)
	_player.damaged.connect(_on_damaged)
	_player.died.connect(func(): death_screen.visible = true)
	_player.respawned.connect(func(): death_screen.visible = false)
	death_screen.visible = false
	damage_flash.modulate.a = 0.0
	_refresh()
	_on_health(_player.health, _player.max_health)
	show_message("Find a weapon")


func _refresh() -> void:
	var w := _weapons.current
	weapon_label.visible = w != null
	ammo_label.visible = w != null
	if w == null:
		return
	var count: int = _weapons.ammo[w.ammo_type]
	weapon_label.text = "%d  %s" % [w.slot, w.display_name.to_upper()]
	ammo_label.text = "%d %s" % [count, w.ammo_type.to_upper()]
	ammo_label.modulate = Color(1.0, 0.35, 0.3) if count <= 5 else Color.WHITE


func _on_health(health: float, max_health: float) -> void:
	health_label.text = "%d HEALTH" % ceili(health)
	health_label.modulate = Color(1.0, 0.3, 0.25) if health <= max_health * 0.25 else Color.WHITE


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
