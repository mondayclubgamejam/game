// Title screen background: forward time (orange) and reverse time (blue)
// split by a slanted ink band. Stripes in each half drift in opposite
// directions, under a halftone screen. One ColorRect, no textures.
shader_type canvas_item;

uniform vec4 forward_col : source_color = vec4(1.0, 0.478, 0.102, 1.0);
uniform vec4 reverse_col : source_color = vec4(0.184, 0.659, 1.0, 1.0);
uniform vec4 ink : source_color = vec4(0.102, 0.063, 0.149, 1.0);
uniform vec4 deep : source_color = vec4(0.165, 0.078, 0.275, 1.0);
uniform float split = 0.47;      // where the band crosses the middle, 0..1 of width
uniform float slant = 0.32;      // band tilt
uniform float speed = 0.05;

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 uv = UV;
	float aspect = res.x / res.y;
	vec2 p = vec2(uv.x * aspect, uv.y);

	// Signed distance to the slanted divider (positive = reverse side).
	float line_x = split * aspect + (uv.y - 0.5) * slant;
	float side = p.x - line_x;

	// Diagonal stripes, drifting forward on the left and backward on the right.
	float dir = side < 0.0 ? 1.0 : -1.0;
	float stripes = fract((p.x * 0.8 + p.y * 1.4) * 7.0 - TIME * speed * 7.0 * dir);
	float band = smoothstep(0.0, 0.02, stripes) * smoothstep(0.5, 0.48, stripes);

	vec3 base = side < 0.0 ? forward_col.rgb : reverse_col.rgb;
	vec3 col = mix(base * 0.78, base, band);

	// Darken toward the outer edges so the title and menu read.
	float edge = side < 0.0 ? smoothstep(0.0, -line_x, side) : smoothstep(0.0, aspect - line_x, side);
	col = mix(col, deep.rgb, edge * 0.55);

	// Halftone dots, bigger toward the bottom.
	vec2 g = FRAGCOORD.xy / (res.y * 0.012);
	g = vec2(g.x + g.y, g.y - g.x) * 0.7071;
	float r = mix(0.12, 0.42, uv.y);
	float dots = 1.0 - smoothstep(r - 0.05, r + 0.05, length(fract(g) - 0.5));
	col = mix(col, ink.rgb, dots * 0.22);

	// The ink band itself, with a thin white cut through it.
	float w = abs(side);
	col = mix(col, ink.rgb, 1.0 - smoothstep(0.035, 0.04, w));
	col = mix(col, vec3(1.0), (1.0 - smoothstep(0.004, 0.007, w)) * 0.9);

	COLOR = vec4(col, 1.0);
}
