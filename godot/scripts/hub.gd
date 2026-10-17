@tool
class_name Hub
extends Node3D
## The hub: the level the game starts in (scenes/hub.tscn), played with the dev console's
## `scene hub`. A wide, dead flat field of grass, painted like the other levels' grassy
## ground (FlatGround), with invisible walls round its edge so you can't walk off it. In
## it stand portals (scripts/portal.gd), each with the name of a level above it; walking
## through one takes you there. The ground and walls are built here when the node enters
## the tree (also in the editor); the portals and PlayerStart (where the player starts,
## facing the way it faces) are ordinary nodes in the scene, to move or add to in the
## editor.

## Half the width of the square field (m).
const HALF_SIZE := 80.0
## Height of the invisible walls round it.
const WALL_HEIGHT := 8.0


func _ready() -> void:
	build()
	if not Engine.is_editor_hint():
		_place_player.call_deferred()  # once the world around it is ready


## Builds the ground and walls (freeing any built before; the saved nodes stay).
func build() -> void:
	for c in get_children():
		if c.owner == null:  # built here, not saved in the scene
			c.free()
	add_child(FlatGround.build(Rect2(-HALF_SIZE, -HALF_SIZE, HALF_SIZE * 2.0, HALF_SIZE * 2.0)))
	var walls := StaticBody3D.new()
	walls.name = "Walls"
	for side in 4:
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(HALF_SIZE * 2.0 + 2.0, WALL_HEIGHT, 1.0)
		shape.shape = box
		shape.rotation.y = side * PI * 0.5
		shape.position = Basis(Vector3.UP, side * PI * 0.5) * Vector3(0.0, WALL_HEIGHT * 0.5, HALF_SIZE + 0.5)
		walls.add_child(shape)
	add_child(walls)


## Puts the player at PlayerStart, facing the way it faces, and makes that where they
## come back after dying.
func _place_player() -> void:
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var start := get_node_or_null("PlayerStart") as Node3D
	if player == null or start == null:
		return
	var at := start.global_position
	at.y = 0.1
	player.set_spawn(Transform3D(Basis(Vector3.UP, start.global_rotation.y), at))
