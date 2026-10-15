class_name Ladder
extends Area3D
## A climbable ladder: tells the player when they're on it (see the climbing in
## player.gd). Its origin is at the foot of the ladder on the face you hold, with +Z
## pointing out toward the climber and +Y up. At the top you climb over onto a landing
## (a tower's deck) whose edge is `landing_gap` behind the ladder. Sizes are in local
## units, so the ladder scales with the model it's put on. tools/build_level.gd adds one
## to every watchtower.

## Width of the ladder.
@export var width := 0.9
## Height of the landing above the foot of the ladder.
@export var height := 4.7
## Distance from the ladder back to the landing's edge.
@export var landing_gap := 0.3
## Height of the lowest rung and the spacing between rungs (the climbing hands hold them).
@export var first_rung := 0.3
@export var rung_spacing := 0.3


func _ready() -> void:
	collision_layer = 0
	collision_mask = 2  # the player
	monitorable = false
	# From the landing's edge out past where a climber hangs, and from the foot to a
	# little above the landing, so climbers carry on up and over.
	var box := BoxShape3D.new()
	box.size = Vector3(width, height + 0.6, landing_gap + 0.9)
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.position = Vector3(0.0, box.size.y / 2.0, 0.9 - box.size.z / 2.0)
	add_child(shape)
	body_entered.connect(func(body: Node3D) -> void:
		if body.has_method("enter_ladder"):
			body.enter_ladder(self))
	body_exited.connect(func(body: Node3D) -> void:
		if body.has_method("exit_ladder"):
			body.exit_ladder(self))


## Direction out from the ladder toward the climber.
func outward() -> Vector3:
	return global_basis.z.normalized()


## World meters per local unit.
func unit() -> float:
	return global_basis.get_scale().y
