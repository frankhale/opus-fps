extends Node
## Player sound effects: footsteps (synced to the camera bob), jump, landing and
## a slide loop. Footsteps pick a random variant with slight pitch/volume variation.

@export var footsteps: Array[AudioStream] = []
@export var jump_sound: AudioStream
@export var land_soft: AudioStream
@export var land_hard: AudioStream
@export var slide_loop: AudioStream
## Mix levels: footsteps sit well under everything else, as in most shooters.
@export var footstep_db := -14.0
@export var jump_db := -10.0
@export var land_db := -6.0
@export var slide_db := -10.0

@onready var player: CharacterBody3D = get_parent()
@onready var camera: Camera3D = player.get_node("Head/Camera3D")

var _steps: AudioStreamPlayer
var _oneshots: AudioStreamPlayer
var _slide: AudioStreamPlayer
var _slide_tween: Tween


func _ready() -> void:
	var randomizer := AudioStreamRandomizer.new()
	for s in footsteps:
		randomizer.add_stream(-1, s)
	randomizer.random_pitch = 1.12
	randomizer.random_volume_offset_db = 2.0
	_steps = _make_player(randomizer, footstep_db)
	_oneshots = _make_player(null, jump_db)
	_oneshots.max_polyphony = 3
	_slide = _make_player(slide_loop, slide_db)
	camera.footstep.connect(_on_footstep)
	player.jumped.connect(func(): _play(jump_sound, jump_db))
	player.landed.connect(_on_landed)
	player.slide_started.connect(_on_slide_started)
	player.slide_ended.connect(_on_slide_ended)


func _make_player(stream: AudioStream, db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = db
	add_child(p)
	return p


func _play(stream: AudioStream, db: float, pitch := 1.0) -> void:
	_oneshots.stream = stream
	_oneshots.volume_db = db
	_oneshots.pitch_scale = pitch * randf_range(0.95, 1.05)
	_oneshots.play()


func _on_footstep(intensity: float) -> void:
	_steps.volume_db = footstep_db + linear_to_db(intensity)
	_steps.play()


func _on_landed(impact: float) -> void:
	if impact > 9.0:
		_play(land_hard, land_db + 2.0)
	elif impact > 2.0:
		_play(land_soft, land_db + linear_to_db(clampf(impact / 7.0, 0.4, 1.0)))


func _on_slide_started() -> void:
	if _slide_tween:
		_slide_tween.kill()
	_slide.volume_db = slide_db
	_slide.play()


func _on_slide_ended() -> void:
	if _slide_tween:
		_slide_tween.kill()
	_slide_tween = create_tween()
	_slide_tween.tween_property(_slide, "volume_db", -40.0, 0.25)
	_slide_tween.tween_callback(_slide.stop)
