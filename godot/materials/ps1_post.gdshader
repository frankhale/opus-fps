// Full-screen PS1 post-process, applied to the low-res SubViewport as it's upscaled.
// Reduces color depth to 15-bit (5 bits per channel) with 4x4 ordered dithering,
// computed per low-res pixel so the dither pattern is chunky like the real thing.
shader_type canvas_item;

uniform float color_levels = 32.0;
uniform float dither_strength : hint_range(0.0, 2.0) = 1.0;

const float BAYER[16] = float[16](
	0.0, 8.0, 2.0, 10.0,
	12.0, 4.0, 14.0, 6.0,
	3.0, 11.0, 1.0, 9.0,
	15.0, 7.0, 13.0, 5.0);

void fragment() {
	vec2 size = vec2(textureSize(TEXTURE, 0));
	ivec2 px = ivec2(floor(UV * size));
	float threshold = BAYER[(px.y % 4) * 4 + (px.x % 4)] / 16.0 - 0.5;
	vec3 c = texture(TEXTURE, UV).rgb;
	c += threshold * dither_strength / color_levels;
	c = floor(c * (color_levels - 1.0) + 0.5) / (color_levels - 1.0);
	COLOR = vec4(clamp(c, 0.0, 1.0), 1.0);
}
