// The cheap screen effects used when the comic pass is off: a vignette that
// deepens and cools in slow motion, and the brief kill flash. Drawn as a
// 2D overlay; it never reads the screen, so it costs almost nothing.
shader_type canvas_item;

uniform vec4 ink : source_color = vec4(0.102, 0.063, 0.149, 1.0);
uniform vec4 cold : source_color = vec4(0.05, 0.10, 0.26, 1.0);
uniform float slowmo = 0.0;
uniform float punch = 0.0;

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	vec2 q = (UV - 0.5) * vec2(res.x / res.y, 1.0);
	float vig = smoothstep(0.5 - slowmo * 0.15, 1.05, length(q)) * (0.2 + slowmo * 0.35);
	vec4 c = vec4(mix(ink.rgb, cold.rgb, slowmo), vig);
	// Kill punch: a quick pale flash.
	c = mix(c, vec4(0.98, 0.95, 0.88, 0.35), punch * 0.6);
	COLOR = c;
}
