// Comic-print post process on one full-screen quad (see world_fx.gd).
// Ink outlines from depth and normal discontinuities, posterized flat colour
// and a 45 degree halftone screen in the shadows.
// The quad sits first in the transparent pass, so glowing effects (bullet,
// aim lines, tracers) are drawn after it and never get inked.
//
//   rewind  0..1  cold duotone with white ink (player B's recall)
//   punch   0..1  short high-contrast flash on kills
//   slowmo  0..1  slow motion: drained, cool, faded print with a heavier vignette
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
// Normal-based edges need Forward+; the OpenGL fallback inks depth edges only.
uniform sampler2D normal_tex : hint_normal_roughness_texture, filter_nearest;
#endif

uniform vec3 ink : source_color = vec3(0.102, 0.063, 0.149);
uniform vec3 cold_dark : source_color = vec3(0.05, 0.10, 0.26);
uniform vec3 cold_light : source_color = vec3(0.64, 0.90, 1.0);
uniform float ink_width = 1.5;
uniform float dot_size = 0.0105;     // halftone cell, as a fraction of screen height
uniform float levels = 6.0;
uniform float rewind = 0.0;
uniform float punch = 0.0;
uniform float slowmo = 0.0;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float view_depth(vec2 uv, mat4 inv_proj) {
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	float z = texture(depth_tex, uv).r * 2.0 - 1.0;  // OpenGL depth is -1..1 in NDC
#else
	float z = texture(depth_tex, uv).r;
#endif
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, z, 1.0);
	return -v.z / v.w;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 texel = ink_width / VIEWPORT_SIZE;

	// Edges: compare the centre against a + shaped neighbourhood.
	float d = view_depth(uv, INV_PROJECTION_MATRIX);
	float depth_edge = 0.0;
	float normal_edge = 0.0;
	vec2 offs[4] = vec2[](vec2(texel.x, 0.0), vec2(-texel.x, 0.0), vec2(0.0, texel.y), vec2(0.0, -texel.y));
#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
	vec3 n = texture(normal_tex, uv).xyz * 2.0 - 1.0;
#endif
	for (int i = 0; i < 4; i++) {
		float dn = view_depth(uv + offs[i], INV_PROJECTION_MATRIX);
		depth_edge = max(depth_edge, abs(dn - d) / max(min(dn, d), 0.01));
#if CURRENT_RENDERER == RENDERER_FORWARD_PLUS
		vec3 nn = texture(normal_tex, uv + offs[i]).xyz * 2.0 - 1.0;
		normal_edge = max(normal_edge, 1.0 - dot(n, nn));
#endif
	}
	float far = clamp(d / 70.0, 0.0, 1.0);
	float edge = max(step(0.08 + far * 0.12, depth_edge), step(0.4, normal_edge));
	edge *= 1.0 - smoothstep(60.0, 120.0, d);   // no ink on the sky

	// Flat colour: posterize in gamma space so the steps look even.
	vec3 c = pow(max(texture(screen_tex, uv).rgb, vec3(0.0)), vec3(0.4545));
	c = floor(c * levels + 0.5) / levels;
	float lum = dot(c, vec3(0.299, 0.587, 0.114));

	// Slow motion: drain most of the colour toward a cool grey.
	vec3 grey = vec3(lum) * vec3(0.92, 0.96, 1.06);
	c = mix(c, grey, slowmo * 0.6);

	// Rewind: same page, printed in two cold inks.
	vec3 duo = mix(pow(cold_dark, vec3(0.4545)), pow(cold_light, vec3(0.4545)), smoothstep(0.12, 0.85, lum));
	c = mix(c, duo, rewind * 0.85);

	// Halftone screen at 45 degrees; dots grow as the tone darkens.
	vec2 g = FRAGCOORD.xy / (VIEWPORT_SIZE.y * dot_size);
	g = vec2(g.x + g.y, g.y - g.x) * 0.7071;
	g.x += TIME * 2.0 * rewind;
	float tone = mix(smoothstep(0.6, 0.18, lum), smoothstep(0.5, 0.92, lum) * 0.7, rewind);
	float r = sqrt(tone) * 0.52;
	float dist = length(fract(g) - 0.5);
	float dots = (1.0 - smoothstep(r - 0.07, r + 0.07, dist)) * step(0.02, tone);
	vec3 dot_col = mix(c * 0.4 + pow(ink, vec3(0.4545)) * 0.25, vec3(1.0), rewind);
	c = mix(c, dot_col, dots * 0.55);

	// Ink lines: dark forward, white while rewinding.
	vec3 ink_g = mix(pow(ink, vec3(0.4545)), vec3(0.94, 0.99, 1.0), rewind);
	c = mix(c, ink_g, edge);

	// Kill punch: crush to paper / ink for a beat.
	vec3 paper = vec3(0.98, 0.95, 0.88);
	c = mix(c, lum > 0.5 ? paper : ink_g, punch * 0.6);

	// Vignette.
	vec2 q = (uv - 0.5) * vec2(VIEWPORT_SIZE.x / VIEWPORT_SIZE.y, 1.0);
	float vig = smoothstep(0.5 - slowmo * 0.15, 1.05, length(q)) * (0.5 + slowmo * 0.3);
	c = mix(c, mix(pow(ink, vec3(0.4545)), pow(cold_dark, vec3(0.4545)), rewind), vig);

	ALBEDO = pow(c, vec3(2.2));
}
