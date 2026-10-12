// Portal membrane: a see-through, shimmering sheet of blue light.
//  * the scene behind is copied from the screen and refracted by a slow swirl
//  * swirling bands, ripples running outward and twinkling sparks drift over it,
//    posterized into a few flat steps so it sits with the PS1 look
//  * the rim burns brightest (and blooms); the middle stays the most transparent
// Works in the membrane's model space: a disc in the XY plane, so it needs to know
// where the disc's center is and its radius.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_nearest, repeat_disable;
uniform vec2 center = vec2(0.0, 0.885);
uniform float radius = 1.45;
uniform vec3 deep_color : source_color = vec3(0.04, 0.22, 0.75);
uniform vec3 bright_color : source_color = vec3(0.45, 0.85, 1.0);
// How much of the scene behind shows through at the center (1 = all of it).
uniform float clarity : hint_range(0.0, 1.0) = 0.75;
// Screen-space refraction strength.
uniform float distortion = 0.006;
uniform float swirl_speed = 0.6;
// Rim glow above 1 so the environment's glow picks it up.
uniform float rim_energy = 1.8;
// Brightness steps for the shimmer bands; 0 = smooth.
uniform float posterize = 5.0;
// Same pixel-grid vertex snapping as ps1.gdshader so the edge stays tight to the frame.
uniform float snap_scale : hint_range(0.0, 1.0) = 1.0;

varying vec2 disc;

void vertex() {
	disc = (VERTEX.xy - center) / radius;
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

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void fragment() {
	float r = length(disc);
	float t = TIME;
	// Swirl: the angle turns faster toward the middle, like water down a drain.
	float a = atan(disc.y, disc.x) + t * swirl_speed + (1.0 - r) * 2.5;
	vec2 sw = vec2(cos(a), sin(a)) * r;
	float n = vnoise(sw * 3.0 + vec2(t * 0.3, -t * 0.2)) * 0.6 + vnoise(sw * 7.0 - vec2(t * 0.5)) * 0.4;
	float bands = 0.5 + 0.5 * sin(a * 3.0 + r * 9.0 - t * 1.7 + n * 4.0);
	float ripple = 0.5 + 0.5 * sin(r * 22.0 - t * 4.0 + n * 3.0);
	float shimmer = clamp(bands * 0.55 + ripple * 0.25 + n * 0.4 - 0.15, 0.0, 1.0);
	if (posterize > 0.0) {
		shimmer = floor(shimmer * posterize + 0.5) / posterize;
	}

	// The world behind, bent by the swirl.
	vec2 bend = vec2(vnoise(sw * 4.0 + t), vnoise(sw * 4.0 - t + 7.3)) - 0.5;
	vec3 behind = texture(screen_tex, SCREEN_UV + bend * distortion).rgb;

	vec3 glow = mix(deep_color, bright_color, shimmer);
	// A thin veil of light over the world behind: thinnest in the middle, solid at the rim.
	float veil = mix(1.0 - clarity, 1.0, smoothstep(0.65, 1.0, r)) * (0.5 + 0.5 * shimmer);
	vec3 c = mix(behind * mix(vec3(1.0), bright_color, 0.3), glow, veil);
	c += bright_color * step(0.75, shimmer) * 0.3;  // highlights on the brightest bands

	// Bright rim, flickering a little.
	float rim = smoothstep(0.78, 1.0, r) * (0.8 + 0.2 * sin(t * 9.0 + a * 5.0));
	c = mix(c, bright_color * rim_energy, rim * 0.8);

	// Sparks: a few cells light up at random and fade.
	vec2 cell = floor(sw * 9.0);
	float spark_t = t * 1.5 + hash(cell) * 10.0;
	float spark = step(0.93, hash(cell + floor(spark_t))) * (1.0 - fract(spark_t));
	c += vec3(0.8, 0.95, 1.0) * spark * 1.2;

	ALBEDO = c;
	ALPHA = 1.0 - smoothstep(0.97, 1.0, r);
}
