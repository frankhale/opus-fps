// Open sea around the island scene (scripts/island.gd), in the style of the creek's water
// (materials/water.gdshader) but for still water with waves rolling in to shore.
//  * ripples in two layers drifting across each other in world space, posterized into
//    flat color steps with pale crests
//  * see-through: the sand shows through the shallows, wobbling with the ripples, and
//    the sea darkens from turquoise to deep blue with the water's real (vertical) depth
//  * surf: bands of foam roll in through the shallows toward the shore and break into a
//    white line at the water's edge and around rocks, read from the depth buffer
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 shallow_color : source_color = vec3(0.26, 0.56, 0.54);
uniform vec3 deep_color : source_color = vec3(0.05, 0.16, 0.26);
uniform vec3 crest_color : source_color = vec3(0.6, 0.8, 0.82);
uniform vec3 foam_color : source_color = vec3(0.88, 0.92, 0.92);
// Drift of the two ripple layers, meters per second.
uniform vec2 drift_a = vec2(0.35, 0.18);
uniform vec2 drift_b = vec2(-0.22, 0.4);
// Ripple size: noise cells per meter.
uniform float ripple_scale = 0.45;
// Water depth (m, straight down) at which the sea bed has faded to deep_color.
uniform float murk_depth = 2.4;
// Least opacity, so even the shallowest water reads as water.
uniform float min_opacity : hint_range(0.0, 1.0) = 0.25;
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
uniform float snap_scale : hint_range(0.0, 1.0) = 1.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
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

void fragment() {
	vec2 p = world_pos.xz * ripple_scale;
	float a = noise(p - drift_a * TIME * ripple_scale);
	float b = noise(p * 1.9 + vec2(4.1, 7.3) - drift_b * TIME * ripple_scale * 1.9);
	float ripple = a * 0.6 + b * 0.4;
	if (posterize > 0.0) {
		ripple = floor(ripple * posterize + 0.5) / posterize;
	}

	float surface = -VERTEX.z;
	vec2 offset = (vec2(a, b) - 0.5) * refraction;
	vec2 uv = SCREEN_UV + offset;
	vec4 bv = INV_PROJECTION_MATRIX * vec4(uv * 2.0 - 1.0, texture(depth_tex, uv).r, 1.0);
	if (-bv.z / bv.w < surface) {
		// The offset landed on something in front of the water: don't refract it.
		uv = SCREEN_UV;
	}
	vec3 bed = scene_pos(uv, INV_PROJECTION_MATRIX, INV_VIEW_MATRIX);
	float depth = max(world_pos.y - bed.y, 0.0);  // straight down to the bed
	// Looking in at a low angle you see through more water than its depth.
	float through = max(distance(bed, world_pos), depth);

	float murk = clamp(max(depth / murk_depth, through / (murk_depth * 6.0)), 0.0, 1.0);
	vec3 water = mix(shallow_color, deep_color, sqrt(murk));
	water = mix(water, crest_color, smoothstep(0.62, 0.8, ripple) * 0.6);
	float opacity = mix(min_opacity, 0.94, murk);
	vec3 col = mix(texture(screen_tex, uv).rgb, water, opacity);

	// Surf rolling in: bands that move from surf_reach deep toward the edge, thickest
	// near the shore, broken up by the ripples.
	float shallow = 1.0 - clamp(depth / surf_reach, 0.0, 1.0);
	float band = fract(depth / surf_spacing + TIME * surf_speed);
	float surf = step(band, surf_thickness * shallow * (0.4 + ripple)) * step(0.001, shallow);
	// The line where it breaks on the sand and around rocks.
	float edge = 1.0 - smoothstep(0.0, foam_width * (0.6 + ripple), depth);
	col = mix(col, foam_color, max(surf * 0.75, step(0.5, edge)));
	ALBEDO = col;
}
