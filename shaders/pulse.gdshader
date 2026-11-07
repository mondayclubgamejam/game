// Billboarded rings that ripple outward (or inward when speed < 0).
// Marks the stuck bullet and the loose gun so players can find them.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform vec4 color : source_color = vec4(0.18, 0.66, 1.0, 1.0);
uniform float speed = 1.2;

void vertex() {
	// Face the camera, keep the node's scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0].xyz),
		INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1].xyz),
		INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2].xyz),
		MODEL_MATRIX[3]);
}

void fragment() {
	float r = length(UV * 2.0 - 1.0);
	float a = 0.0;
	for (int i = 0; i < 3; i++) {
		float t = fract(TIME * abs(speed) + float(i) / 3.0);
		t = speed < 0.0 ? 1.0 - t : t;
		a = max(a, smoothstep(0.07, 0.0, abs(r - t * 0.95)) * (1.0 - t));
	}
	ALBEDO = color.rgb;
	ALPHA = a * color.a;
}
