// The invulnerability shield as seen from inside: a bubble around the player's head
// (scripts/shield_veil.gd) covered in thin, shimmering interference ripples. It keeps a
// fixed orientation in the world, so the ripples slide across the view as you turn,
// like a real bubble. The middle of the screen stays clear for aiming and the veil
// thickens toward the edges. Brightness is posterized into a few flat steps for the
// PS1 look. A blocked hit flares the side it came from.
shader_type spatial;
render_mode unshaded, blend_add, cull_front, depth_draw_never, depth_test_disabled, fog_disabled;

uniform vec3 color : source_color = vec3(0.3, 0.85, 1.0);
uniform vec3 crest_color : source_color = vec3(0.85, 1.0, 1.0);
// Overall strength: 0 = invisible, 1 = full. Scripts fade and flicker it.
uniform float strength : hint_range(0.0, 2.0) = 1.0;
// Ripple density and speed.
uniform float ripple_scale = 18.0;
uniform float ripple_speed = 1.6;
// How much of the screen's middle stays clear (0..1 of the half-diagonal).
uniform float clear_center = 0.32;
// Flash on a blocked hit (decays in the script) and the world direction it came from.
uniform float hit = 0.0;
uniform vec3 hit_dir = vec3(0.0, 0.0, -1.0);
uniform float steps = 5.0;

varying vec3 dir;

void vertex() {
	dir = normalize(VERTEX);
}

void fragment() {
	vec3 d = normalize(dir);
	float t = TIME * ripple_speed;
	// Three wave fronts crossing at odd angles; where their sum nears zero they draw
	// thin, wandering caustic lines.
	float w = sin(dot(d, vec3(0.80, 0.31, 0.52)) * ripple_scale + t * 1.3)
		+ sin(dot(d, vec3(-0.41, 0.88, 0.23)) * ripple_scale * 0.85 - t * 1.1)
		+ sin(dot(d, vec3(0.27, -0.24, 0.93)) * ripple_scale * 1.25 + t * 0.8);
	float lines = pow(1.0 - clamp(abs(w) / 1.2, 0.0, 1.0), 9.0);
	// A slow sheen that sweeps over the bubble.
	float sheen = 0.5 + 0.5 * sin(dot(d, vec3(0.0, 1.0, 0.3)) * 3.0 - TIME * 2.2);
	// Clear in the middle of the view, thicker toward the edges.
	vec2 c = (SCREEN_UV - 0.5) * vec2(VIEWPORT_SIZE.x / VIEWPORT_SIZE.y, 1.0);
	float edge = smoothstep(clear_center, clear_center + 0.6, length(c));
	float flare = hit * (0.06 + pow(max(dot(d, normalize(hit_dir)), 0.0), 4.0) * 0.5) * (0.3 + edge);
	float v = (lines * (0.6 + 0.4 * sheen) * 0.5 + 0.04 * sheen) * edge * strength + flare;
	v = floor(clamp(v, 0.0, 0.8) * steps + 0.5) / steps;
	ALBEDO = mix(color, crest_color, clamp(lines * 1.2 + flare, 0.0, 1.0)) * v;
}
