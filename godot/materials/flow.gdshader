// Poured water for PS1_Flow faces (the rain fountain's pool, spouts and spill).
//  * the model's flow UVs are meters with u running the way the water goes and v across
//    it, so ripples scroll along the flow: outward across a pool, down a falling stream
//  * streaky ripples in two layers moving at different speeds, posterized into a few
//    flat steps of turquoise with pale streaks and white crests, so it sits with the
//    PS1 look
//  * unshaded and bright, like the glowing palette it replaces, and seen from both sides
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled;

uniform vec3 deep_color : source_color = vec3(0.09, 0.47, 0.6);
uniform vec3 water_color : source_color = vec3(0.2, 0.68, 0.79);
uniform vec3 streak_color : source_color = vec3(0.52, 0.84, 0.9);
uniform vec3 crest_color : source_color = vec3(0.88, 0.95, 0.96);
// Speed of the ripples along the flow, meters per second.
uniform float flow_speed = 0.7;
// Ripples per meter along the flow.
uniform float ripple_scale = 3.0;
// Brightness steps for the ripples; 0 = smooth.
uniform float posterize = 5.0;
uniform float snap_scale : hint_range(0.0, 1.0) = 1.0;

varying vec2 flow;

void vertex() {
	flow = vec2(UV.x, -UV.y);  // glTF flipped v; undo it so v is the model's cross-flow axis
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

void fragment() {
	float t = TIME * flow_speed;
	// Ripples stretched across the flow; the second layer is finer and faster.
	float a = noise(vec2((flow.x - t) * ripple_scale, flow.y * 5.0));
	float b = noise(vec2((flow.x - t * 1.7) * ripple_scale * 2.2, flow.y * 11.0 + 7.3));
	float ripple = a * 0.6 + b * 0.4;
	if (posterize > 0.0) {
		ripple = floor(ripple * posterize + 0.5) / posterize;
	}
	vec3 col = mix(deep_color, water_color, smoothstep(0.2, 0.45, ripple));
	col = mix(col, streak_color, step(0.6, ripple));
	col = mix(col, crest_color, step(0.78, ripple));
	ALBEDO = col;
}
