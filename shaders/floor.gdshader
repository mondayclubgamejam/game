// World-space checker floor: one plane, one draw call.
shader_type spatial;
render_mode specular_disabled;

uniform vec3 color_a : source_color = vec3(0.953, 0.914, 0.824);
uniform vec3 color_b : source_color = vec3(0.890, 0.827, 0.690);
uniform float tile = 2.0;

varying vec2 world_xz;

void vertex() {
	world_xz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec2 cell = floor(world_xz / tile);
	ALBEDO = mix(color_a, color_b, mod(cell.x + cell.y, 2.0));
	ROUGHNESS = 0.9;
}
