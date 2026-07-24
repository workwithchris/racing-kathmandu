shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform sampler2D asphalt_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec2 uv_scale = vec2(0.3, 0.3);

// Global "just rained" wetness control (0 = bone dry, 1 = soaked). Drive this
// from a weather system later via ShaderMaterial.set_shader_parameter("wetness", x).
uniform float wetness : hint_range(0.0, 1.0) = 0.12;
uniform vec3 wet_tint : source_color = vec3(0.04, 0.04, 0.05);
uniform float tire_wear_strength : hint_range(0.0, 1.0) = 0.4;
uniform float bump_depth : hint_range(0.0, 2.0) = 0.6;

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
	vec2 uv = v_world_pos.xz * uv_scale;
	vec3 tex = texture(asphalt_tex, uv).rgb;

	// Low-frequency blobs read as puddles; only shiny/dark where wetness is high.
	float puddle = smoothstep(0.55, 0.78, value_noise(v_world_pos.xz * 0.05)) * wetness;

	// Elongated streaks along a road-ish axis read as tire/rubber wear.
	float streak = value_noise(vec2(v_world_pos.x * 0.6, v_world_pos.z * 0.05));
	float wear = smoothstep(0.5, 0.85, streak) * tire_wear_strength;

	vec3 albedo = tex * COLOR.rgb;
	albedo = mix(albedo, albedo * 0.45, wear);
	albedo = mix(albedo, wet_tint, puddle * 0.7);

	// Cheap fake bump: perturb the normal from a noise-height gradient instead
	// of sampling a real normal map (no extra texture, still breaks up flatness).
	vec2 nuv = uv * 8.0;
	float e = 0.05;
	float h_c = value_noise(nuv);
	float h_x = value_noise(nuv + vec2(e, 0.0));
	float h_z = value_noise(nuv + vec2(0.0, e));
	vec3 bump = normalize(vec3((h_c - h_x) * bump_depth, 1.0, (h_c - h_z) * bump_depth));
	NORMAL_MAP = bump * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;

	ALBEDO = albedo;
	ROUGHNESS = clamp(mix(0.92, 0.12, puddle) - wear * 0.1, 0.05, 1.0);
	METALLIC = puddle * 0.15;
	SPECULAR = mix(0.3, 0.9, puddle);
}
