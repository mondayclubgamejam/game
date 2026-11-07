// Full-screen comic post-process: ink outlines from depth/normal edges,
// halftone dots in the shadows, and a light posterize.
// Drawn by a single quad (see main.gd) with the lowest render priority, so
// transparent effects (bullet, laser) draw on top of it without outlines.
//
// Time FX (driven by fx.gd):
//   rewind       0..1  inverted-time look: cold duotone, white ink, halftone in highlights
//   misregister  px    two-colour print offset (orange plate vs blue plate)
//   speed_lines  0..1  radial streaks; speed_dir +1 streams outward, -1 sucks inward
//   impact       0..1  high-contrast splash-panel flash on hits
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform sampler2D normal_tex : hint_normal_roughness_texture, filter_nearest;

uniform vec4 ink_color : source_color = vec4(0.10, 0.06, 0.15, 1.0);
uniform vec4 paper_color : source_color = vec4(0.97, 0.93, 0.84, 1.0);
uniform vec4 rewind_dark : source_color = vec4(0.04, 0.09, 0.25, 1.0);
uniform vec4 rewind_light : source_color = vec4(0.62, 0.90, 1.0, 1.0);
uniform vec4 impact_accent : source_color = vec4(1.0, 0.18, 0.53, 1.0);
uniform float line_px = 1.6;
uniform float depth_threshold = 0.07;
uniform float normal_threshold = 0.35;
uniform float halftone_px = 7.0;
uniform float halftone_strength = 0.55;
uniform float halftone_start = 0.62;  // tones darker than this get dots
uniform float posterize_levels = 6.0;

uniform float rewind = 0.0;
uniform float misregister = 0.0;
uniform float speed_lines = 0.0;
uniform float speed_dir = 1.0;
uniform float impact = 0.0;
uniform float grain = 0.05;
uniform float vignette = 0.45;

void vertex() {
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float linear_depth(vec2 uv, mat4 inv_proj) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_proj * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -v.z / v.w;
}

vec3 view_normal(vec2 uv) {
	return texture(normal_tex, uv).xyz * 2.0 - 1.0;
}

void edge_sample(vec2 uv, float d0, vec3 n0, mat4 inv_proj, inout float de, inout float ne) {
	float d = linear_depth(uv, inv_proj);
	de = max(de, abs(d - d0) / max(min(d, d0), 0.001));
	ne = max(ne, 1.0 - dot(view_normal(uv), n0));
}

void fragment() {
	vec2 px = line_px / VIEWPORT_SIZE;
	vec2 uv = SCREEN_UV;

	// --- Two-colour print misregistration ---
	vec2 off = vec2(misregister, misregister * 0.5) / VIEWPORT_SIZE;
	vec3 col = texture(screen_tex, uv).rgb;
	col.r = texture(screen_tex, uv + off).r;
	col.b = texture(screen_tex, uv - off).b;

	// --- Ink outlines ---
	float d0 = linear_depth(uv, INV_PROJECTION_MATRIX);
	vec3 n0 = view_normal(uv);
	float de = 0.0;
	float ne = 0.0;
	edge_sample(uv + vec2(px.x, 0.0), d0, n0, INV_PROJECTION_MATRIX, de, ne);
	edge_sample(uv - vec2(px.x, 0.0), d0, n0, INV_PROJECTION_MATRIX, de, ne);
	edge_sample(uv + vec2(0.0, px.y), d0, n0, INV_PROJECTION_MATRIX, de, ne);
	edge_sample(uv - vec2(0.0, px.y), d0, n0, INV_PROJECTION_MATRIX, de, ne);
	float far_fade = clamp(d0 / 60.0, 0.0, 1.0);
	float edge = max(step(depth_threshold + far_fade * 0.1, de), step(normal_threshold, ne));

	// --- Posterize (in roughly sRGB space so steps look even) ---
	vec3 srgb = pow(max(col, vec3(0.0)), vec3(1.0 / 2.2));
	srgb = floor(srgb * posterize_levels + 0.5) / posterize_levels;
	float lum = dot(srgb, vec3(0.299, 0.587, 0.114));

	// --- Rewind: cold duotone of the same page ---
	vec3 duo = mix(pow(rewind_dark.rgb, vec3(1.0 / 2.2)), pow(rewind_light.rgb, vec3(1.0 / 2.2)),
		smoothstep(0.1, 0.85, lum));
	srgb = mix(srgb, duo, rewind * 0.85);

	// --- Halftone: in shadows going forward, in highlights while rewinding ---
	float shadow = smoothstep(halftone_start, 0.2 * halftone_start / 0.62, lum);
	float highlight = smoothstep(0.45, 0.9, lum);
	float tone = mix(shadow, highlight * 0.8, rewind);
	vec2 p = FRAGCOORD.xy / halftone_px;
	p = mat2(vec2(0.7071, 0.7071), vec2(-0.7071, 0.7071)) * p;
	p.x -= TIME * 1.5 * rewind;  // dots drift backwards while inverted
	vec2 cell = fract(p) - 0.5;
	float radius = sqrt(tone) * 0.5;
	float dotmask = 1.0 - smoothstep(radius - 0.06, radius + 0.06, length(cell));
	vec3 dot_col = mix(srgb * 0.35 + ink_color.rgb * 0.3, vec3(1.0), rewind);
	srgb = mix(srgb, dot_col, dotmask * halftone_strength * step(0.01, tone));

	// --- Ink: dark going forward, white while rewinding ---
	vec3 ink = mix(pow(ink_color.rgb, vec3(1.0 / 2.2)), vec3(0.95, 1.0, 1.0), rewind);
	srgb = mix(srgb, ink, edge);

	// --- Impact: splash-panel flash (paper / accent / ink) ---
	vec3 splash = lum > 0.55 ? pow(paper_color.rgb, vec3(1.0 / 2.2))
		: (lum > 0.3 ? pow(impact_accent.rgb, vec3(1.0 / 2.2)) : pow(ink_color.rgb, vec3(1.0 / 2.2)));
	splash = mix(splash, pow(ink_color.rgb, vec3(1.0 / 2.2)), edge);
	srgb = mix(srgb, splash, impact);

	// --- Speed lines from the crosshair ---
	vec2 c = (uv - 0.5) * vec2(VIEWPORT_SIZE.x / VIEWPORT_SIZE.y, 1.0);
	float r = length(c);
	float a = atan(c.y, c.x);
	float lane = floor(a / 6.2832 * 90.0);
	float pick = hash(vec2(lane, 3.0));
	float streak = fract(r * 1.6 - TIME * 3.0 * speed_dir + pick * 7.0);
	float line_on = step(0.72, pick) * smoothstep(0.0, 0.15, streak) * smoothstep(0.7, 0.4, streak);
	line_on *= smoothstep(0.22, 0.6, r) * speed_lines;
	vec3 line_col = rewind > 0.5 ? vec3(1.0) : vec3(1.0, 0.97, 0.88);
	srgb = mix(srgb, line_col, line_on);

	// --- Paper grain + vignette ---
	float g = hash(floor(FRAGCOORD.xy) + floor(TIME * 12.0)) - 0.5;
	srgb += g * grain;
	float vig = smoothstep(0.45, 1.0, r * 1.1);
	srgb = mix(srgb, mix(ink_color.rgb, rewind_dark.rgb, rewind), vig * vignette);

	ALBEDO = pow(max(srgb, vec3(0.0)), vec3(2.2));
	ALPHA = 1.0;
}
