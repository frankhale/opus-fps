shader_type spatial;
// The glow over a weapon pickup, so it can be spotted from afar. As a beam (on a
// CylinderMesh): an additive column, brightest at the bottom and along its middle,
// fading to nothing at the top, with bands drifting up it. As a halo (halo on, on a
// QuadMesh): a soft round glow facing the camera. Both widen with distance (past
// grow_from meters) so they keep about the same width on screen, ignore fog so they
// read through the haze, and fade out by themselves past fade_distance instead.

render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 color : source_color = vec3(1.0, 0.8, 0.35);
uniform float strength = 1.0;
uniform bool halo = false;
// The beam's height, centered on its origin.
uniform float height = 9.0;
// Set by the pickup each frame: its slow pulse, 0..1.
uniform float pulse = 1.0;
uniform float grow_from = 12.0;
uniform float max_grow = 4.0;
uniform float fade_distance = 110.0;

varying float dist;
// 0 at the top of the beam, 1 at the bottom.
varying float rise;

void vertex() {
	vec3 origin = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	dist = length(origin);
	float grow = clamp(dist / grow_from, 1.0, max_grow);
	if (halo) {
		// Billboard: lay the quad out in view space around the node's origin.
		vec3 v = origin + vec3(VERTEX.xy * grow, 0.0);
		POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
	} else {
		rise = clamp(0.5 - VERTEX.y / height, 0.0, 1.0);
		VERTEX.xz *= grow;
		// Writing POSITION in one branch makes Godot use it for every vertex.
		POSITION = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	}
}

void fragment() {
	float a;
	if (halo) {
		float r = length(UV - 0.5) * 2.0;
		a = pow(max(1.0 - r, 0.0), 2.0);
	} else {
		float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
		a = rise * rise * facing * facing;
		a *= 0.7 + 0.3 * sin(rise * 18.0 + TIME * 3.0);
	}
	a *= strength * pulse;
	a *= 1.0 - smoothstep(fade_distance * 0.6, fade_distance, dist);
	ALBEDO = color * a;
}
