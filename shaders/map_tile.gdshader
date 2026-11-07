// A map picture inside a slanted lobby tile. It is cut to the tile's
// parallelogram (the same skew as its StyleBoxFlat) and fades into the tile
// colour at the top, where the map's name sits.
shader_type canvas_item;

uniform float slant = 0.0;              // skew * height / width
uniform vec4 fill : source_color = vec4(1.0);
uniform float band = 0.5;               // how far down the colour reaches
uniform float dim = 0.0;                // 0 = full picture, 1 = mostly tile colour
uniform float light = 0.0;              // hover brighten

void fragment() {
	float x = UV.x - slant * (0.5 - UV.y);
	if (x < 0.0 || x > 1.0) {
		discard;
	}
	vec3 img = texture(TEXTURE, UV).rgb;
	vec3 c = mix(img, img * fill.rgb * 1.15, 0.25);       // tint toward the tile colour
	c = mix(c, fill.rgb * 0.45, dim);
	c += light * 0.12;
	float top = 1.0 - smoothstep(band * 0.55, band, UV.y);
	c = mix(c, fill.rgb, top);
	COLOR = vec4(c, 1.0);
}
