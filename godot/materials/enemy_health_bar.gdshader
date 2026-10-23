// The health bar over an enemy (scripts/enemies/enemy_health_bar.gd), drawn like the
// HUD's (scripts/health_bar.gd): a pale frame round a dark backdrop, the fill with a
// lighter band along its top, and a pale chunk where the last hits took health away.
// One quad, turned to face the camera and kept level, growing with distance so it stays
// readable far off. Fog doesn't dim it.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

// How full the bar is, and how far the damage chunk behind the fill reaches (0 to 1).
uniform float fill = 1.0;
uniform float trail = 1.0;
uniform vec4 fill_color : source_color = vec4(0.3, 0.85, 0.25, 1.0);
uniform float opacity : hint_range(0.0, 1.0) = 1.0;
uniform vec4 frame_color : source_color = vec4(0.91, 0.85, 0.7, 1.0);
uniform vec4 backdrop_color : source_color = vec4(0.08, 0.09, 0.1, 0.75);
uniform vec4 trail_color : source_color = vec4(1.0, 0.95, 0.85, 0.7);
// The bar's size and its frame's width, in meters (up close).
uniform vec2 size = vec2(1.0, 0.12);
uniform float border = 0.03;
// Past this distance (m) it grows in step with it, so it keeps its size on screen.
uniform float grow_from = 10.0;

void vertex() {
	vec3 center = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float grow = max(1.0, length(center - CAMERA_POSITION_WORLD) / grow_from);
	vec3 right = normalize(vec3(INV_VIEW_MATRIX[0].x, 0.0, INV_VIEW_MATRIX[0].z));
	vec3 up = vec3(0.0, 1.0, 0.0);
	vec3 world = center + (right * VERTEX.x * size.x + up * VERTEX.y * size.y) * grow;
	POSITION = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(world, 1.0));
}

void fragment() {
	vec2 b = border / size;
	vec2 uv = UV;
	vec4 c = frame_color;
	if (all(greaterThan(uv, b)) && all(lessThan(uv, 1.0 - b))) {
		vec2 inner = (uv - b) / (1.0 - 2.0 * b);
		c = backdrop_color;
		if (inner.x < fill) {
			c = vec4(inner.y < 0.3 ? mix(fill_color.rgb, vec3(1.0), 0.25) : fill_color.rgb, 1.0);
		} else if (inner.x < trail) {
			c = trail_color;
		}
	}
	ALBEDO = c.rgb;
	ALPHA = c.a * opacity;
}
