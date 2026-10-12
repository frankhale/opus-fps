// Flowing creek water for the PS1_Water sheet in terrain_creek.
//  * the model's water UVs are meters with u running downstream, so ripples scroll along
//    the flow however the tile is turned (and survive the Terrain node merging tiles)
//  * streaky ripples in two layers moving at different speeds, posterized into a few
//    flat color steps with glints on the crests, so it sits with the PS1 look
//  * see-through: the bed and pebbles show through, wobbling with the ripples, and the
//    water gets murkier with depth
//  * white foam where the water meets rocks and banks, read from the depth buffer
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform vec3 shallow_color : source_color = vec3(0.24, 0.42, 0.44);
uniform vec3 deep_color : source_color = vec3(0.08, 0.17, 0.22);
uniform vec3 crest_color : source_color = vec3(0.62, 0.78, 0.8);
uniform vec3 foam_color : source_color = vec3(0.86, 0.9, 0.9);
// Downstream speed of the ripples, meters per second.
uniform float flow_speed = 0.9;
// Water depth (m) at which the bed has faded to deep_color.
uniform float murk_depth = 0.6;
// Least opacity, so even the shallowest water reads as water.
uniform float min_opacity : hint_range(0.0, 1.0) = 0.3;
// Screen-space wobble of the bed seen through the water.
uniform float refraction = 0.012;
// Water within this distance (m) of a rock or bank turns to foam.
uniform float foam_width = 0.12;
// Brightness steps for the ripples; 0 = smooth.
uniform float posterize = 4.0;
uniform float snap_scale : hint_range(0.0, 1.0) = 1.0;

varying vec2 flow;

void vertex() {
	flow = vec2(UV.x, -UV.y);  // glTF flipped v; undo it so v is the model's cross-stream axis
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

// Distance from the camera (view-space depth) of whatever is drawn at `uv` behind the water.
float scene_depth(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -v.z / v.w;
}

void fragment() {
	float t = TIME * flow_speed;
	// Ripples stretched along the flow; the second layer is finer and faster.
	float a = noise(vec2(flow.x * 0.9 - t, flow.y * 2.6));
	float b = noise(vec2(flow.x * 1.8 - t * 1.6, flow.y * 4.5 + 7.3));
	float ripple = a * 0.6 + b * 0.4;
	if (posterize > 0.0) {
		ripple = floor(ripple * posterize + 0.5) / posterize;
	}

	float surface = -VERTEX.z;
	vec2 offset = (vec2(a, b) - 0.5) * refraction;
	vec2 uv = SCREEN_UV + offset;
	float behind = scene_depth(uv, INV_PROJECTION_MATRIX);
	if (behind < surface) {
		// The offset landed on something in front of the water: don't refract it.
		uv = SCREEN_UV;
		behind = scene_depth(uv, INV_PROJECTION_MATRIX);
	}
	float water_depth = max(behind - surface, 0.0);

	float murk = clamp(water_depth / murk_depth, 0.0, 1.0);
	vec3 water = mix(shallow_color, deep_color, murk);
	water = mix(water, crest_color, smoothstep(0.62, 0.8, ripple) * 0.7);
	float opacity = mix(min_opacity, 0.92, murk);
	vec3 col = mix(texture(screen_tex, uv).rgb, water, opacity);

	// Foam hugging rocks and banks, broken up by the ripples so it churns.
	float foam = 1.0 - smoothstep(0.0, foam_width * (0.6 + ripple), water_depth);
	col = mix(col, foam_color, step(0.5, foam));
	ALBEDO = col;
}
