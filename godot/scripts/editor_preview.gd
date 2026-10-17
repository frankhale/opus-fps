@tool
class_name EditorPreview
extends Node3D
## Shows a model in the editor only, so an object that builds its own model when the game
## runs (the enemies and creatures) can be seen, placed and turned in a scene. Set this
## node's transform to where its owner puts the model (its scale and turn). The model
## isn't saved with the scene, and in the game this node removes itself.

@export var model: PackedScene:
	set(v):
		model = v
		if is_inside_tree():
			_show()


func _ready() -> void:
	if not Engine.is_editor_hint():
		queue_free()
		return
	_show()


func _show() -> void:
	for c in get_children():
		if c.owner == null:  # a preview made here, not part of the scene
			c.free()
	if model:
		add_child(model.instantiate())
