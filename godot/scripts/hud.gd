extends CanvasLayer
## Weapon HUD: current weapon and ammo in the bottom-right corner (red when low),
## plus short pickup messages that fade out.

@export var weapons_path: NodePath

@onready var weapon_label: Label = $WeaponName
@onready var ammo_label: Label = $AmmoCount
@onready var message_label: Label = $Message

var _weapons: WeaponManager
var _message_tween: Tween


func _ready() -> void:
	_weapons = get_node(weapons_path)
	_weapons.weapon_changed.connect(func(_w): _refresh())
	_weapons.ammo_changed.connect(func(_t, _a): _refresh())
	_weapons.message.connect(show_message)
	_refresh()
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


func show_message(text: String) -> void:
	message_label.text = text
	message_label.modulate.a = 1.0
	if _message_tween:
		_message_tween.kill()
	_message_tween = create_tween()
	_message_tween.tween_interval(1.6)
	_message_tween.tween_property(message_label, "modulate:a", 0.0, 0.6)
