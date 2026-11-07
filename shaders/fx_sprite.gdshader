// Small procedural FX sprites so the game needs no texture assets.
//   mode 0: impact crack (ink starburst + hot centre + dark hole), sized by `grow`
//   mode 1: pulse rings (lodged bullet "ticking"), billboarded
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, fog_disabled;

uniform int mode = 0;
uniform vec4 color : source_color = vec4(1.0, 0.48, 0.1, 1.0);
uniform vec4 ink : source_color = vec4(0.10, 0.06, 0.15, 1.0);
uniform float grow = 1.0;
uniform float seed = 0.0;
uniform float speed = 1.0;
uniform bool billboard = false;

void vertex() {
	if (billboard) {
		MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			INV_VIEW_MATRIX[0] * length(MODEL_MATRIX[0].xyz),
			INV_VIEW_MATRIX[1] * length(MODEL_MATRIX[1].xyz),
			INV_VIEW_MATRIX[2] * length(MODEL_MATRIX[2].xyz),
			MODEL_MATRIX[3]);
	}
}

float star(vec2 p, float spikes, float inner, float outer, float rot) {
	float a = atan(p.y, p.x) + rot;
	float k = pow(abs(cos(a * spikes * 0.5)), 6.0);
	return step(length(p), mix(inner, outer, k));
}

void fragment() {
	vec2 p = UV * 2.0 - 1.0;
	if (mode == 0) {
		vec2 q = p / max(grow, 0.001);
		float outer = star(q, 7.0, 0.3, 0.95, seed);
		float hot = star(q, 7.0, 0.18, 0.6, seed + 0.2);
		float hole = step(length(q), 0.13);
		vec3 c = mix(ink.rgb, color.rgb, hot);
		c = mix(c, ink.rgb, hole);
		ALBEDO = c;
		ALPHA = outer;
	} else {
		float r = length(p);
		float a = 0.0;
		for (int i = 0; i < 3; i++) {
			float t = fract(TIME * speed + float(i) / 3.0);
			float ring = smoothstep(0.06, 0.0, abs(r - t * 0.95));
			a = max(a, ring * (1.0 - t));
		}
		ALBEDO = color.rgb;
		ALPHA = a * color.a;
	}
}
