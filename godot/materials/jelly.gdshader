// Jellyfish bell: soft, glowing jelly, pink in the middle of whatever side faces you,
// shading through lavender to periwinkle and a deep blue round its edges, with a pink
// fringe right at the silhouette and a few faint streaks of light across one side.
//  * the gradient follows the view (how squarely each point faces the camera), so the
//    bell keeps its pink heart from any angle, as the real thing does
//  * smooth, not paletted: jelly reads soft against the hard PS1 surfaces around it
//  * the same pixel-grid vertex snapping as ps1.gdshader, so it wobbles with them
shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx, cull_back;

uniform vec3 core_color : source_color = vec3(0.88, 0.5, 0.84);
uniform vec3 mid_color : source_color = vec3(0.56, 0.56, 0.96);
uniform vec3 edge_color : source_color = vec3(0.12, 0.24, 0.68);
uniform vec3 fringe_color : source_color = vec3(0.78, 0.42, 0.76);
// How far out (in facing, 0 = square on, 1 = edge-on) the pink core reaches, and where
// the deep blue edge sets in.
uniform float core_reach : hint_range(0.0, 1.0) = 0.45;
uniform float edge_start : hint_range(0.0, 1.0) = 0.75;
// Self-glow, so the bell stays bright in shade.
uniform float glow : hint_range(0.0, 2.0) = 0.3;
// Faint streaks of light fanning across the bell.
uniform float streaks : hint_range(0.0, 1.0) = 0.25;
uniform float snap_scale : hint_range(0.0, 1.0) = 1.0;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
	vec4 clip = PROJECTION_MATRIX * (MODELVIEW_MATRIX * vec4(VERTEX, 1.0));
	if (snap_scale > 0.0 && PROJECTION_MATRIX[3][3] < 0.5) {
		vec2 grid = VIEWPORT_SIZE * 0.5 * snap_scale;
		clip.xy = round(clip.xy / clip.w * grid) / grid * clip.w;
	}
	POSITION = clip;
}

void fragment() {
	float facing = 1.0 - clamp(abs(dot(normalize(NORMAL), normalize(VIEW))), 0.0, 1.0);
	vec3 c = mix(core_color, mid_color, smoothstep(core_reach * 0.4, core_reach + 0.2, facing));
	c = mix(c, edge_color, smoothstep(edge_start - 0.2, edge_start + 0.15, facing));
	c = mix(c, fringe_color, smoothstep(0.93, 1.0, facing) * 0.6);
	// Streaks: thin rays round the bell's axis, strongest toward its side and edges.
	float a = atan(local_pos.z, local_pos.x);
	float ray = pow(max(sin(a * 9.0 + 1.3), 0.0), 24.0) + 0.6 * pow(max(sin(a * 5.0 - 0.7), 0.0), 40.0);
	c += vec3(0.75, 0.8, 1.0) * ray * streaks * smoothstep(0.35, 0.8, facing) * smoothstep(0.0, 0.5, cos(a - 0.4));
	ALBEDO = c;
	EMISSION = c * glow;
	ROUGHNESS = 0.45;
	SPECULAR = 0.15;
	METALLIC = 0.0;
}
