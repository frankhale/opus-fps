// PS1-style surface shader for the palette-textured asset pack.
//  * vertex snapping: clip-space positions snap to the render's pixel grid (the "wobble")
//  * per-pixel depth from each face's true plane, so snapping can't make nearby
//    surfaces (windows on walls, trim, decals) z-fight and flicker
//  * affine texture mapping: UVs interpolate in screen space, like the PS1's GTE
//  * nearest-neighbour palette sampling, Gouraud (per-vertex) lighting, no specular
shader_type spatial;
render_mode vertex_lighting, diffuse_lambert, specular_disabled, cull_back;

uniform sampler2D palette : source_color, filter_nearest, repeat_disable;
// Snapping grid relative to the render resolution: 1 = whole pixels (PS1-accurate),
// below 1 = coarser grid and more wobble, 0 = snapping off.
uniform float snap_scale : hint_range(0.0, 1.0) = 1.0;
uniform float affine_strength : hint_range(0.0, 1.0) = 1.0;
// Furthest the affine warp may move a UV, in texels. Real affine error grows with a
// face's size on screen; capping it keeps the PS1 texture swim without huge nearby
// faces collapsing into a flat, sliding smear.
uniform float affine_max_texels = 2.0;
uniform float emission_strength = 0.0;
// Multiplies the palette color; below 1 darkens a surface (e.g. the ground).
uniform float albedo_scale = 1.0;
// Most the per-pixel depth correction may move a pixel, as a fraction of its distance
// (plus 3 cm). Enough to settle coplanar decals; small enough that it can't open cracks.
uniform float depth_fix_slack = 0.01;
// Palette layout (8 x 4 swatches); used to keep affine UVs inside their swatch.
uniform vec2 swatch_grid = vec2(8.0, 4.0);

varying vec3 affine_uv;
// View-space plane of the face (normal, distance). Flat: identical for the whole triangle.
varying flat vec4 face_plane;

void vertex() {
	vec3 view_pos = (MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 view_n = normalize(mat3(VIEW_MATRIX) * (MODEL_NORMAL_MATRIX * NORMAL));
	face_plane = vec4(view_n, dot(view_n, view_pos));
	vec4 clip = PROJECTION_MATRIX * vec4(view_pos, 1.0);
	// Orthographic cameras (e.g. the minimap) get no wobble.
	bool ortho = PROJECTION_MATRIX[3][3] > 0.5;
	if (snap_scale > 0.0 && !ortho) {
		vec2 grid = VIEWPORT_SIZE * 0.5 * snap_scale;
		clip.xy = round(clip.xy / clip.w * grid) / grid * clip.w;
	}
	POSITION = clip;
	// Interpolating (uv * w, w) perspective-correctly and dividing per pixel cancels
	// the perspective correction, leaving the PS1's affine (screen-linear) mapping.
	affine_uv = vec3(UV * clip.w, clip.w);
}

void fragment() {
	vec2 uv = UV;
	if (affine_strength > 0.0) {
		vec2 limit = affine_max_texels / vec2(textureSize(palette, 0));
		vec2 offset = clamp(affine_uv.xy / affine_uv.z - UV, -limit, limit);
		// Keep the result inside the face's own swatch so colors never bleed.
		vec2 cell = floor(UV * swatch_grid);
		uv = clamp(UV + offset * affine_strength, (cell + 0.1) / swatch_grid, (cell + 0.9) / swatch_grid);
	}
	vec3 c = texture(palette, uv).rgb * albedo_scale;
	ALBEDO = c;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
	EMISSION = c * emission_strength;

	// Snapping moves vertices sideways but keeps their depth, which skews each face's
	// depth slightly differently, so nearly coplanar surfaces (windows on walls, trim)
	// z-fight. Re-derive depth by casting this pixel's view ray onto the face's real
	// plane, but only let it move the rasterized depth a little: near silhouettes and on
	// faces seen edge-on the ray can meet the plane far from the actual triangle, and an
	// unbounded correction there punches see-through cracks along the edges.
	// Works in view distance (d > 0 in front of the camera); for a perspective projection
	// NDC depth = B / d - A with A = P[2][2] and B = P[3][2].
	if (snap_scale > 0.0 && PROJECTION_MATRIX[3][3] < 0.5) {  // orthographic (minimap): no snapping, depth already exact
		float A = PROJECTION_MATRIX[2][2];
		float B = PROJECTION_MATRIX[3][2];
		float raster = B / (FRAGCOORD.z + A);
		vec4 far_point = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, 0.5, 1.0);
		vec3 ray = far_point.xyz / far_point.w;
		ray /= -ray.z;  // unit view depth, so the plane hit's distance is the depth itself
		float denom = dot(face_plane.xyz, ray);
		float d = abs(denom) > 1e-5 ? face_plane.w / denom : raster;
		float slack = raster * depth_fix_slack + 0.03;
		DEPTH = B / clamp(d, raster - slack, raster + slack) - A;
	} else {
		DEPTH = FRAGCOORD.z;
	}
}
