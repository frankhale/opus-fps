// Grass (assets/scenery/grass_patch.glb, scattered over the island by scripts/island.gd):
// a soft take on the pack's PS1 shader (materials/ps1.gdshader), since thousands of
// sharp, flickering blades are distracting.
//  * no vertex snapping, so the blades hold still instead of shimmering as you move
//  * each blade fades up from the ground's own green at its root to its palette color,
//    so clumps sink into the ground instead of standing on it, and its colors are
//    softened toward that green so bright tips don't speckle
//  * lit as if it faced straight up, like the ground under it, so a blade's two sides
//    don't flip between light and dark
//  * the tips thin out in a fine dither instead of ending in a hard point
//  * past fade_start meters it sinks into the ground, gone by fade_end, so the meadow
//    calms down in the distance and its far edge never pops
shader_type spatial;
render_mode diffuse_lambert, specular_disabled, cull_back;

uniform sampler2D palette : source_color, filter_nearest, repeat_disable;
// The ground's green, linear: the palette's grass swatch dimmed as the island's ground
// is (scripts/island.gd's GROUND_BRIGHTNESS).
uniform vec3 ground_color = vec3(0.027, 0.048, 0.022);
// Height of the tallest blade in the model (m): what counts as a blade's tip.
uniform float blade_height = 0.36;
// How far a blade's color is pulled toward the ground's green (0 = its own color).
uniform float soften : hint_range(0.0, 1.0) = 0.35;
// The share of a blade's height, from the top, that thins out to its tip.
uniform float tip_fade : hint_range(0.0, 1.0) = 0.3;
uniform float fade_start = 25.0;
uniform float fade_end = 42.0;

varying float rise;

void vertex() {
	rise = clamp(VERTEX.y / blade_height, 0.0, 1.0);
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float far = smoothstep(fade_start, fade_end, distance(world, CAMERA_POSITION_WORLD));
	VERTEX.y *= 1.0 - far;
	NORMAL = vec3(0.0, 1.0, 0.0);
}

void fragment() {
	vec3 blade = texture(palette, UV).rgb;
	vec3 c = mix(blade, ground_color, soften);
	ALBEDO = mix(ground_color, c, smoothstep(0.0, 0.6, rise));
	ROUGHNESS = 1.0;
	ALPHA = 1.0 - smoothstep(1.0 - tip_fade, 1.0, rise) * 0.85;
	ALPHA_HASH_SCALE = 1.0;
}
