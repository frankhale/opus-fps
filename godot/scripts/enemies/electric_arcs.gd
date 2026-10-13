@tool
class_name ElectricArcs
extends Node3D
## Crackling electric arcs from points on a body down to the ground below it, as on the
## golem, which floats on its charge where its legs would be. Each arc is a jagged bolt
## (with the odd fork) redrawn many times a second, so they jump about and flicker,
## wrapped in a soft glow. A glow on the ground where they land, sparks spitting up
## from it, wisps of ozone smoke curling off and a flickering blue-white light go with
## them. `intensity` 1 is the steady hover; above 1 the arcs
## thicken and multiply and start crawling over the body too (from `climb_sources`),
## as when the golem gathers its charge. (@tool so the arcs also crackle in the editor.)

## Where the arcs start, in this node's space (the undersides of the golem's hips).
@export var sources := PackedVector3Array()
## Extra starting points that only arc once intensity rises above 1 (the body).
@export var climb_sources := PackedVector3Array()
## Distance from this node's origin down to the ground, where the arcs land.
@export var drop := 0.8
## How far out from straight below its source an arc can land, in meters. Arcs fan
## outward, away from the middle.
@export var spread := 0.45
@export var color := Color(0.5, 0.85, 1.0)
@export_range(0.0, 3.0) var intensity := 1.0
## Times a second the arcs are redrawn in new shapes.
@export var rate := 16.0
@export var light_energy := 2.2

var _mesh: ImmediateMesh
var _glow_mat: StandardMaterial3D
var _ground: MeshInstance3D
var _sparks: GPUParticles3D
var _smoke: GPUParticles3D
var _light: OmniLight3D
var _timer := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_mesh = ImmediateMesh.new()
	var arcs := MeshInstance3D.new()
	arcs.mesh = _mesh
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	arcs.material_override = mat
	arcs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(arcs)

	# A soft disc of light on the ground where the arcs strike.
	var tex := GradientTexture2D.new()
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(1.0, 0.5)
	tex.gradient = Gradient.new()
	tex.gradient.set_color(0, Color(1, 1, 1, 1))
	tex.gradient.set_color(1, Color(1, 1, 1, 0))
	tex.width = 32
	tex.height = 32
	var quad := QuadMesh.new()
	quad.orientation = PlaneMesh.FACE_Y
	_glow_mat = StandardMaterial3D.new()
	_glow_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glow_mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_glow_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glow_mat.albedo_texture = tex
	_glow_mat.albedo_color = color
	quad.material = _glow_mat
	_ground = MeshInstance3D.new()
	_ground.mesh = quad
	_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_ground)

	var spark := ParticleProcessMaterial.new()
	spark.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	spark.direction = Vector3.UP
	spark.spread = 60.0
	spark.initial_velocity_min = 1.0
	spark.initial_velocity_max = 3.0
	spark.gravity = Vector3(0, -9.8, 0)
	spark.scale_min = 0.03
	spark.scale_max = 0.06
	spark.color_ramp = FX.ramp([Color(1, 1, 1), color, Color(color.r, color.g, color.b, 0)], [0.0, 0.4, 1.0])
	_sparks = FX.emitter(24, 0.45, spark, FX.quad(true, 3.0), false)
	_sparks.emitting = true
	add_child(_sparks)

	# Thin pale smoke drifting up off the scorched ground.
	var smoke := ParticleProcessMaterial.new()
	smoke.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	smoke.direction = Vector3.UP
	smoke.spread = 25.0
	smoke.initial_velocity_min = 0.2
	smoke.initial_velocity_max = 0.6
	smoke.gravity = Vector3(0.1, 0.5, 0.05)
	smoke.damping_min = 0.2
	smoke.damping_max = 0.4
	smoke.angle_min = -180.0
	smoke.angle_max = 180.0
	smoke.angular_velocity_min = -30.0
	smoke.angular_velocity_max = 30.0
	smoke.scale_min = 0.45
	smoke.scale_max = 0.8
	smoke.scale_curve = FX.curve([Vector2(0, 0.5), Vector2(1, 2.2)])
	smoke.color_ramp = FX.ramp([Color(0.62, 0.68, 0.76, 0), Color(0.62, 0.68, 0.76, 0.5), Color(0.52, 0.54, 0.58, 0)],
		[0.0, 0.2, 1.0])
	_smoke = FX.emitter(26, 2.6, smoke, FX.quad(false), false)
	_smoke.emitting = true
	add_child(_smoke)

	_light = OmniLight3D.new()
	_light.light_color = color
	_light.omni_range = 5.0
	add_child(_light)
	_place_ground_parts()
	_redraw()


func _process(delta: float) -> void:
	_place_ground_parts()
	_timer -= delta
	if _timer <= 0.0:
		_timer = 1.0 / rate * _rng.randf_range(0.6, 1.4)
		_redraw()
	var flicker := _rng.randf_range(0.55, 1.0)
	_light.light_energy = light_energy * intensity * flicker
	_glow_mat.albedo_color = Color(color.r, color.g, color.b, clampf(0.55 + 0.35 * intensity, 0.0, 1.0) * flicker)


## The ground glow, sparks and light follow `drop`, which the owner updates as it bobs.
func _place_ground_parts() -> void:
	var size := (spread * 2.0 + 1.2) * (0.8 + 0.2 * intensity)
	_ground.position = Vector3(0.0, -drop + 0.03, 0.0)
	_ground.scale = Vector3(size, 1.0, size)
	_sparks.position = Vector3(0.0, -drop + 0.05, 0.0)
	(_sparks.process_material as ParticleProcessMaterial).emission_box_extents = Vector3(spread, 0.02, spread)
	_sparks.amount_ratio = clampf(0.4 * intensity, 0.0, 1.0)
	_smoke.position = _sparks.position
	(_smoke.process_material as ParticleProcessMaterial).emission_box_extents = Vector3(spread, 0.05, spread)
	_smoke.amount_ratio = clampf(0.5 + 0.25 * intensity, 0.0, 1.0)
	_light.position = Vector3(0.0, -drop * 0.4, 0.0)


func _redraw() -> void:
	var bolts: Array[PackedVector3Array] = []
	var on := clampf(0.5 + 0.25 * intensity, 0.0, 1.0)
	for s in sources:
		if _rng.randf() < on:
			_bolt(bolts, s, _landing(s))
	# Now and then one jumps across between two starting points.
	if sources.size() >= 2 and _rng.randf() < 0.25 * intensity:
		var a := _rng.randi() % sources.size()
		var b := (a + 1 + _rng.randi() % (sources.size() - 1)) % sources.size()
		_bolt(bolts, sources[a], sources[b])
	# Charged up: arcs crawl over the body and down to the ground.
	var climb := intensity - 1.0
	for s in climb_sources:
		if _rng.randf() < climb * 0.6:
			var to := _landing(s) if _rng.randf() < 0.5 or climb_sources.size() < 2 \
				else climb_sources[_rng.randi() % climb_sources.size()]
			_bolt(bolts, s, to)

	_mesh.clear_surfaces()
	if bolts.is_empty() or intensity <= 0.0:
		return
	var view := Vector3.BACK * 100.0  # looked at from +Z when there is no camera (editor)
	var cam := get_viewport().get_camera_3d() if is_inside_tree() else null
	if cam:
		view = to_local(cam.global_position)
	var thick := 0.7 + 0.35 * intensity
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for b in bolts:
		_ribbon(b, view, 0.26 * thick, Color(color.r, color.g, color.b) * 0.16)  # wide soft halo
		_ribbon(b, view, 0.11 * thick, Color(color.r, color.g, color.b) * 0.55)  # glow
		_ribbon(b, view, 0.03 * thick, Color(0.85, 0.95, 1.0))                   # hot core
	_mesh.surface_end()


## A spot on the ground out from below `from`, fanning away from the middle.
func _landing(from: Vector3) -> Vector3:
	var out := Vector2(from.x, from.z)
	var a := _rng.randf() * TAU
	var dir := Vector2(cos(a), sin(a))
	if out.length() > 0.01:
		dir = (dir + out.normalized() * 1.2).normalized()
	var r := spread * _rng.randf_range(0.35, 1.0)
	return Vector3(from.x + dir.x * r, -drop, from.z + dir.y * r)


## A jagged bolt from `a` to `b` (kinks displaced most in the middle), sometimes forking.
func _bolt(bolts: Array[PackedVector3Array], a: Vector3, b: Vector3, depth := 0) -> void:
	var along := b - a
	var length := along.length()
	if length < 0.05:
		return
	var side1 := along.cross(Vector3.UP if absf(along.normalized().y) < 0.9 else Vector3.RIGHT).normalized()
	var side2 := along.cross(side1).normalized()
	var kinks := 7 if depth == 0 else 3
	var points := PackedVector3Array([a])
	for i in range(1, kinks):
		var t := float(i) / kinks
		var jag := sin(PI * t) * length * 0.16
		points.append(a + along * t + side1 * _rng.randf_range(-jag, jag) + side2 * _rng.randf_range(-jag, jag))
	points.append(b)
	bolts.append(points)
	if depth == 0 and _rng.randf() < 0.35:
		var from := points[_rng.randi_range(2, kinks - 2)]
		var out := (Vector3(_rng.randf_range(-1, 1), -0.6, _rng.randf_range(-1, 1))).normalized()
		_bolt(bolts, from, from + out * length * 0.35, depth + 1)


## Flat strip along the bolt, turned to face the camera, `width` across.
func _ribbon(points: PackedVector3Array, view: Vector3, width: float, c: Color) -> void:
	for i in points.size() - 1:
		var p := points[i]
		var q := points[i + 1]
		var side := (q - p).cross(view - p).normalized() * width * 0.5
		_mesh.surface_set_color(c)
		for v in [p - side, p + side, q + side, p - side, q + side, q - side]:
			_mesh.surface_add_vertex(v)
