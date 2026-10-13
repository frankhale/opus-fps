// Daytime sky with drifting clouds.
//  * the gradient, sun disc and ground below the horizon are the same as Godot's
//    ProceduralSkyMaterial (same parameters), so the sky looks as it did before
//  * clouds are fractal noise on a flat layer overhead, drifting with the wind; their
//    density is posterized into a few flat steps so they sit with the PS1 look
//  * the side toward the sun is lit and the far side shaded grey, read by sampling the
//    noise a little toward the sun; clouds thin out toward the horizon and pass in
//    front of the sun
shader_type sky;

uniform vec3 sky_top_color : source_color = vec3(0.26, 0.5, 0.82);
uniform vec3 sky_horizon_color : source_color = vec3(0.68, 0.8, 0.9);
uniform float sky_curve : hint_range(0.0, 1.0) = 0.18;
uniform vec3 ground_bottom_color : source_color = vec3(0.22, 0.21, 0.19);
uniform vec3 ground_horizon_color : source_color = vec3(0.58, 0.64, 0.68);
uniform float ground_curve : hint_range(0.0, 1.0) = 0.02;
// Glow around the sun, in degrees out from its disc.
uniform float sun_angle_max = 18.0;
uniform float sun_curve : hint_range(0.0, 1.0) = 0.08;

uniform vec3 cloud_color : source_color = vec3(0.97, 0.97, 0.95);
uniform vec3 cloud_shade_color : source_color = vec3(0.6, 0.65, 0.72);
// Share of the sky covered (0 = clear, 1 = overcast).
uniform float coverage : hint_range(0.0, 1.0) = 0.5;
// How soft the cloud edges are.
uniform float softness : hint_range(0.01, 1.0) = 0.25;
// Size of the cloud pattern; bigger = smaller clouds.
uniform float cloud_scale = 1.6;
// Drift across the sky (layer units per second, x and z).
uniform vec2 wind = vec2(0.012, 0.005);
uniform float opacity : hint_range(0.0, 1.0) = 0.95;
// Flat density steps; 0 = smooth.
uniform float posterize = 4.0;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x),
		mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int k = 0; k < 5; k++) {
		v += a * noise(p);
		p = p * 2.03 + vec2(17.1, 9.2);
		a *= 0.5;
	}
	return v;
}

float density(vec2 p) {
	return smoothstep(1.0 - coverage, 1.0 - coverage + softness, fbm(p));
}

void sky() {
	float v_angle = acos(clamp(EYEDIR.y, -1.0, 1.0));
	vec3 col;
	if (EYEDIR.y >= 0.0) {
		float c = 1.0 - v_angle / (PI * 0.5);
		col = mix(sky_horizon_color, sky_top_color, clamp(1.0 - pow(1.0 - c, 1.0 / sky_curve), 0.0, 1.0));
		if (LIGHT0_ENABLED) {
			float sun_angle = acos(clamp(dot(LIGHT0_DIRECTION, EYEDIR), -1.0, 1.0));
			vec3 sun = LIGHT0_COLOR * LIGHT0_ENERGY;
			float glow = radians(sun_angle_max);
			if (sun_angle < LIGHT0_SIZE) {
				col = sun;
			} else if (sun_angle < glow) {
				float c2 = (sun_angle - LIGHT0_SIZE) / (glow - LIGHT0_SIZE);
				col = mix(sun, col, clamp(1.0 - pow(1.0 - c2, 1.0 / sun_curve), 0.0, 1.0));
			}
		}

		// Project onto a flat layer overhead: far-off clouds bunch up toward the horizon.
		vec2 p = EYEDIR.xz / (EYEDIR.y + 0.1) * cloud_scale + wind * TIME * cloud_scale;
		float d = density(p);
		if (posterize > 0.0) {
			d = floor(d * posterize + 0.5) / posterize;
		}
		d *= smoothstep(0.0, 0.3, EYEDIR.y) * opacity;
		if (d > 0.0) {
			// Thicker toward the sun = shaded; thinning toward it = lit.
			vec2 to_sun = LIGHT0_ENABLED ? normalize(LIGHT0_DIRECTION.xz + vec2(1e-4)) : vec2(0.0);
			float ahead = density(p + to_sun * 0.08);
			float lit = clamp(1.0 - (ahead - density(p)) * 2.5 - d * 0.35, 0.0, 1.0);
			lit = posterize > 0.0 ? floor(lit * 3.0 + 0.5) / 3.0 : lit;
			col = mix(col, mix(cloud_shade_color, cloud_color, lit), d);
		}
	} else {
		float c = (v_angle - PI * 0.5) / (PI * 0.5);
		col = mix(ground_horizon_color, ground_bottom_color, clamp(1.0 - pow(1.0 - c, 1.0 / ground_curve), 0.0, 1.0));
	}
	COLOR = col;
}
