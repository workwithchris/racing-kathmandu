shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec3 water_color : source_color = vec3(0.05, 0.09, 0.11);
uniform vec3 water_color_deep : source_color = vec3(0.02, 0.04, 0.06);
uniform float roughness_val : hint_range(0.0, 1.0) = 0.06;

varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

void fragment() {
	vec2 p = v_world_pos.xz * 0.02 + vec2(TIME * 0.6, TIME * 0.35);
	float n1 = value_noise(p);
	float n2 = value_noise(p * 2.3 + 11.0);
	float waves = n1 * 0.6 + n2 * 0.4;

	ALBEDO = mix(water_color_deep, water_color, waves);
	ROUGHNESS = roughness_val;
	METALLIC = 0.0;
	SPECULAR = 0.9;

	float e = 0.15;
	float h_c = value_noise(p);
	float h_x = value_noise(p + vec2(e, 0.0));
	float h_z = value_noise(p + vec2(0.0, e));
	vec3 bump = normalize(vec3((h_c - h_x) * 1.5, 1.0, (h_c - h_z) * 1.5));
	NORMAL_MAP = bump * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.8;
}
