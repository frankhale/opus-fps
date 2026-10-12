class_name FX
extends RefCounted
## Shared builders for glowing particle effects (projectile trails, muzzle flashes,
## explosions, pickup sparkles). Meshes and textures are cached and reused.

static var _dot: Texture2D
static var _star: Texture2D
static var _quads := {}


## Soft round sprite, sampled with nearest filtering so it stays chunky like the PS1.
static func dot_texture() -> Texture2D:
	if _dot == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		var t := GradientTexture2D.new()
		t.gradient = g
		t.fill = GradientTexture2D.FILL_RADIAL
		t.fill_from = Vector2(0.5, 0.5)
		t.fill_to = Vector2(1.0, 0.5)
		t.width = 12
		t.height = 12
		_dot = t
	return _dot


## Four-pointed muzzle-flash star with a hot center, as a small chunky texture.
static func star_texture() -> Texture2D:
	if _star == null:
		var size := 16
		var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
		var c := (size - 1) / 2.0
		for y in size:
			for x in size:
				var dx := absf(x - c) / c
				var dy := absf(y - c) / c
				var core := clampf(1.0 - Vector2(dx, dy).length() * 1.6, 0.0, 1.0)
				var rays := clampf(1.0 - dx * 1.1 - dy * 6.0, 0.0, 1.0) + clampf(1.0 - dy * 1.1 - dx * 6.0, 0.0, 1.0)
				var a := clampf(core + rays * 0.8, 0.0, 1.0)
				img.set_pixel(x, y, Color(1, 1, 1, a))
		_star = ImageTexture.create_from_image(img)
	return _star


## Unit billboard quad for particles. Additive quads with energy above 1 are
## pushed into HDR so the environment's glow (bloom) picks them up.
static func quad(additive: bool, energy := 1.0) -> QuadMesh:
	var key := "%s:%s" % [additive, energy]
	if not _quads.has(key):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD if additive else BaseMaterial3D.BLEND_MODE_MIX
		m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		# Without this, billboarding discards each particle's scale and every
		# particle renders as a full 1 m quad regardless of its size settings.
		m.billboard_keep_scale = true
		m.vertex_color_use_as_albedo = true
		m.albedo_texture = dot_texture()
		m.albedo_color = Color(energy, energy, energy, 1.0)
		m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		m.disable_receive_shadows = true
		var q := QuadMesh.new()
		q.material = m
		_quads[key] = q
	return _quads[key]


static func ramp(colors: Array, offsets: Array) -> GradientTexture1D:
	var g := Gradient.new()
	g.offsets = PackedFloat32Array(offsets)
	g.colors = PackedColorArray(colors)
	var t := GradientTexture1D.new()
	t.gradient = g
	return t


static func curve(points: Array) -> CurveTexture:
	var c := Curve.new()
	for p in points:
		c.add_point(p)
	var t := CurveTexture.new()
	t.curve = c
	return t


## A particle emitter. `one_shot` emitters fire one burst (all particles at once).
static func emitter(amount: int, lifetime: float, process: ParticleProcessMaterial, mesh: Mesh,
		one_shot: bool) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = maxi(amount, 1)
	p.lifetime = lifetime
	p.one_shot = one_shot
	p.explosiveness = 1.0 if one_shot else 0.0
	p.process_material = process
	p.draw_pass_1 = mesh
	p.local_coords = false
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.visibility_aabb = AABB(Vector3(-30, -30, -30), Vector3(60, 60, 60))
	p.emitting = false
	return p


## Burst of glowing sparks flying outward in all directions.
static func burst(color: Color, amount: int, speed: float, size: float, lifetime: float,
		gravity := -9.8, energy := 4.0) -> GPUParticles3D:
	var m := ParticleProcessMaterial.new()
	m.direction = Vector3.UP
	m.spread = 180.0
	m.initial_velocity_min = speed * 0.4
	m.initial_velocity_max = speed
	m.gravity = Vector3(0, gravity, 0)
	m.damping_min = 1.0
	m.damping_max = 3.0
	m.scale_min = size * 0.6
	m.scale_max = size
	m.scale_curve = curve([Vector2(0, 1), Vector2(1, 0)])
	m.color_ramp = ramp([Color(1, 1, 0.85), color, Color(color.r, color.g * 0.5, color.b * 0.3, 0)], [0.0, 0.35, 1.0])
	return emitter(amount, lifetime, m, quad(true, energy), true)
