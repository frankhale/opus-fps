// Open sea around the island scene (scripts/island.gd), in the style of the creek's water
// (materials/water.gdshader) but for still water with waves rolling in to shore.
//  * ripples in two layers drifting across each other in world space, posterized into
//    flat color steps with pale crests
//  * see-through, like a tropical lagoon: over the sandy shallows the bed shows through
//    pale and bright, tinted aqua; farther out it turns clear turquoise, and past the
//    drop-off a rich sapphire blue, by the water's real (vertical) depth
//  * surf: bands of foam roll in through the shallows toward the shore and break into a
//    white line at the water's edge and around rocks
// Everything is worked out per pixel so the water stays put as you move, where the PS1
// vertex snapping makes the sea's huge faces and the beach under it jump about:
//  * the point on the surface is where the camera's ray through the pixel meets it, not
//    the (snapped) face's
//  * the water's depth comes from bed_map, the sea bed's true height (the level builds
//    it: scripts/island.gd), not the low-res depth buffer
//  * where the water meets the beach comes from bed_map too: the sea draws without a
//    depth test and hides itself only behind things truly in front of it (dry land and
//    whatever stands on it or in the water), so the snapping beach can't push the
//    waterline about. The depth buffer still adds the foam line round rocks.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, shadows_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
// The sea bed's height (m, in red), one texel per bed_step meters with the first texel's
// center at bed_origin (x, z); past its edges the bed is at bed_floor.
uniform sampler2D bed_map : filter_linear, repeat_disable;
uniform vec2 bed_origin = vec2(0.0);
uniform float bed_step = 1.0;
uniform float bed_floor = -9.0;
// The pale aqua over the sand, the turquoise of the deeper shallows, and the open sea.
uniform vec3 lagoon_color : source_color = vec3(0.56, 0.9, 0.84);
uniform vec3 shallow_color : source_color = vec3(0.1, 0.7, 0.76);
uniform vec3 deep_color : source_color = vec3(0.04, 0.33, 0.52);
uniform vec3 crest_color : source_color = vec3(0.78, 0.96, 0.95);
uniform vec3 foam_color : source_color = vec3(0.88, 0.92, 0.92);
// Drift of the two ripple layers, meters per second.
uniform vec2 drift_a = vec2(0.35, 0.18);
uniform vec2 drift_b = vec2(-0.22, 0.4);
// Ripple size: noise cells per meter.
uniform float ripple_scale = 0.45;
// Water depth (m, straight down) by which the pale lagoon has turned turquoise, and the
// depths over which the turquoise deepens to deep_color.
uniform float lagoon_depth = 1.2;
uniform vec2 deep_depths = vec2(3.0, 9.0);
// The sand seen through the shallows is brightened and tinted by this, as sunlit sand
// under clear water looks.
uniform vec3 bed_tint : source_color = vec3(1.1, 1.3, 1.25);
uniform float bed_lift = 0.1;
// Least opacity, so even the shallowest water reads as water.
uniform float min_opacity : hint_range(0.0, 1.0) = 0.3;
// Screen-space wobble of the bed seen through the water.
uniform float refraction = 0.01;
// Water within this depth (m) of the bed or a rock turns to foam: the line at the edge.
uniform float foam_width = 0.07;
// Surf bands: how deep they start (m), their spacing in depth (m), how fast they roll in
// (bands per second) and how much of each band is foam at its deep end.
uniform float surf_reach = 0.5;
uniform float surf_spacing = 0.2;
uniform float surf_speed = 0.16;
uniform float surf_thickness : hint_range(0.0, 1.0) = 0.3;
// Brightness steps for the ripples; 0 = smooth.
uniform float posterize = 4.0;
// Snapping of the sea's own faces. Off: only where it meets the sky would show it.
uniform float snap_scale : hint_range(0.0, 1.0) = 0.0;

void vertex() {
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	if (snap_scale > 0.0 && PROJECTION_MATRIX[3][3] < 0.5) {
		vec2 grid = VIEWPORT_SIZE * 0.5 * snap_scale;
		clip.xy = round(clip.xy / clip.w * grid) / grid * clip.w;
	}
	POSITION = clip;
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

// World position of whatever is drawn at `uv` behind the water.
vec3 scene_pos(vec2 uv, mat4 inv_proj, mat4 inv_view) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return (inv_view * vec4(v.xyz / v.w, 1.0)).xyz;
}

// The sea bed's height at (x, z).
float bed_height(vec2 xz) {
	vec2 size = vec2(textureSize(bed_map, 0));
	vec2 t = (xz - bed_origin) / bed_step + 0.5;
	bool inside = all(greaterThanEqual(t, vec2(0.0))) && all(lessThanEqual(t, size));
	return inside ? texture(bed_map, t / size).r : bed_floor;
}

void fragment() {
	// This pixel's point on the surface: where the camera's ray through it meets the sea.
	vec4 ray = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, 0.5, 1.0);
	vec3 dir = normalize(mat3(INV_VIEW_MATRIX) * (ray.xyz / ray.w));
	float level = MODEL_MATRIX[3].y;
	vec3 cam = CAMERA_POSITION_WORLD;
	if ((level - cam.y) * dir.y <= 0.0) {
		discard;  // the ray doesn't reach the surface (the sky past the horizon)
	}
	vec3 wp = cam + dir * ((level - cam.y) / dir.y);
	float surface = -(VIEW_MATRIX * vec4(wp, 1.0)).z;
	float sea_depth = level - bed_height(wp.xz);
	if (sea_depth <= 0.0) {
		discard;  // dry land
	}
	// Hidden behind anything in front of it, except sea bed (sand under the water, which
	// can only seem to be in front where its faces snap).
	vec3 front = scene_pos(SCREEN_UV, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
	if (-(VIEW_MATRIX * vec4(front, 1.0)).z < surface - 0.02) {
		float under = bed_height(front.xz);
		if (!(under < level + 0.05 && abs(front.y - under) < 0.3)) {
			discard;
		}
	}

	vec2 p = wp.xz * ripple_scale;
	float a = noise(p - drift_a * TIME * ripple_scale);
	float b = noise(p * 1.9 + vec2(4.1, 7.3) - drift_b * TIME * ripple_scale * 1.9);
	float ripple = a * 0.6 + b * 0.4;
	if (posterize > 0.0) {
		ripple = floor(ripple * posterize + 0.5) / posterize;
	}

	vec2 offset = (vec2(a, b) - 0.5) * refraction;
	vec2 uv = SCREEN_UV + offset;
	vec4 bv = INV_PROJECTION_MATRIX * vec4(uv * 2.0 - 1.0, texture(depth_tex, uv).r, 1.0);
	if (-bv.z / bv.w < surface) {
		// The offset landed on something in front of the water: don't refract it.
		uv = SCREEN_UV;
	}
	// How far down the bed is, and (looking in at a low angle) how much water you see through.
	float depth = sea_depth;
	float through = depth / max(abs(dir.y), 0.05);
	// Something drawn well above the bed (a rock) gets its foam line from the depth buffer.
	vec3 bed = scene_pos(uv, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
	float drawn_depth = max(wp.y - bed.y, 0.0);
	float edge_depth = drawn_depth < sea_depth - 0.15 ? drawn_depth : sea_depth;

	float seen = max(depth, through / 10.0);
	float lagoon = smoothstep(0.0, lagoon_depth, seen);
	float deep = smoothstep(deep_depths.x, deep_depths.y, seen);
	vec3 water = mix(mix(lagoon_color, shallow_color, lagoon), deep_color, deep);
	water = mix(water, crest_color, smoothstep(0.62, 0.8, ripple) * 0.6);
	float opacity = mix(min_opacity, 0.96, clamp(lagoon * 0.5 + deep * 0.5, 0.0, 1.0));
	vec3 bed_col = texture(screen_tex, uv).rgb * bed_tint + bed_lift;
	vec3 col = mix(bed_col, water, opacity);

	// Surf rolling in: bands that move from surf_reach deep toward the edge, thickest
	// near the shore, broken up by the ripples.
	float shallow = 1.0 - clamp(depth / surf_reach, 0.0, 1.0);
	float band = fract(depth / surf_spacing + TIME * surf_speed);
	float surf = step(band, surf_thickness * shallow * (0.4 + ripple)) * step(0.001, shallow);
	// The line where it breaks on the sand and around rocks.
	float edge = 1.0 - smoothstep(0.0, foam_width * (0.6 + ripple), edge_depth);
	col = mix(col, foam_color, max(surf * 0.75, step(0.5, edge)));
	ALBEDO = col;
}
