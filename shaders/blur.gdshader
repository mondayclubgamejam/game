// The pause menu's backdrop: the game behind, blurred and tinted ink.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform vec4 tint : source_color = vec4(0.102, 0.063, 0.149, 0.55);
uniform float amount = 3.0;   // mip level: higher = blurrier

void fragment() {
	vec3 c = textureLod(screen_tex, SCREEN_UV, amount).rgb;
	vec2 px = SCREEN_PIXEL_SIZE * 6.0;
	c += textureLod(screen_tex, SCREEN_UV + vec2(px.x, 0.0), amount).rgb;
	c += textureLod(screen_tex, SCREEN_UV - vec2(px.x, 0.0), amount).rgb;
	c += textureLod(screen_tex, SCREEN_UV + vec2(0.0, px.y), amount).rgb;
	c += textureLod(screen_tex, SCREEN_UV - vec2(0.0, px.y), amount).rgb;
	c /= 5.0;
	COLOR = vec4(mix(c, tint.rgb, tint.a), 1.0);
}
