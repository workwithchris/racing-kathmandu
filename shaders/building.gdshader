shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

// window_tex: RGB = wall/frame/glass colour, A = 1.0 on glass pixels only
// (used as a mask for per-window specular/emission variation).
uniform sampler2D window_tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec3 uv_scale = vec3(0.125, 0.125, 0.125);

uniform float grime_strength : hint_range(0.0, 1.0) = 0.55;
uniform vec3 grime_color : source_color = vec3(0.07, 0.07, 0.08);

uniform float lit_window_chance : hint_range(0.0, 1.0) = 0.12;
uniform vec3 lit_window_color : source_color = vec3(1.0, 0.72, 0.35);
uniform float lit_window_energy = 2.2;

varying vec3 v_world_pos;
varying vec3 v_world_normal;
varying float v_height_frac;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
	// Encoded per-vertex in kathmandu_map.gd: 0.0 at the building base, 1.0 at the roofline.
	v_height_frac = COLOR.a;
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
	// Triplanar sample: walls come from arbitrary building footprints, so this
	// picks the dominant world axis per-fragment instead of relying on UVs.
	vec3 n = abs(v_world_normal);
	vec3 blend = n / (n.x + n.y + n.z + 0.0001);

	vec2 uv_x = v_world_pos.zy * uv_scale.x;
	vec2 uv_y = v_world_pos.xz * uv_scale.y;
	vec2 uv_z = v_world_pos.xy * uv_scale.z;

	vec4 tex_x = texture(window_tex, uv_x);
	vec4 tex_y = texture(window_tex, uv_y);
	vec4 tex_z = texture(window_tex, uv_z);
	vec4 tex = tex_x * blend.x + tex_y * blend.y + tex_z * blend.z;
	vec2 dom_uv = uv_x * blend.x + uv_y * blend.y + uv_z * blend.z;

	float glass_mask = tex.a;
	vec3 base = tex.rgb * COLOR.rgb * 1.15;

	// Coarse per-window id so nearby windows don't all look identical.
	vec2 cell = floor(dom_uv * 8.0);
	float w_id = hash21(cell);

	// Dirt/grime streaks that concentrate toward the base of each building.
	float dirt = value_noise(v_world_pos.xz * 0.08 + v_world_pos.y * 0.02) * 0.5
			+ value_noise(v_world_pos.xz * 0.35) * 0.5;
	float base_ao = clamp(1.0 - v_height_frac, 0.0, 1.0);
	float grime = grime_strength * base_ao * base_ao * mix(0.5, 1.0, dirt);

	vec3 wall_albedo = mix(base, grime_color * base, grime);

	// --- Glass ---------------------------------------------------------------
	// Real glass is a dark, cool-tinted dielectric that mirrors the sky more and
	// more as the view angle approaches grazing (Fresnel). Per-window variation
	// keeps a facade from looking like one flat mirror.
	vec3 glass_tint = vec3(0.06, 0.10, 0.13) * mix(0.7, 1.3, w_id);
	float fresnel = pow(clamp(1.0 - dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0), 4.0);
	// Reflect the sky/environment: strong at grazing, subtle head-on.
	float glass_reflect = mix(0.08, 0.9, fresnel);

	vec3 albedo = mix(wall_albedo, glass_tint, glass_mask);

	// A minority of windows glow warm at dusk/night for the cinematic lit-window look.
	float lit = step(1.0 - lit_window_chance, w_id) * glass_mask;

	ALBEDO = albedo;
	// Wall stays rough; glass is smooth (sharp reflections) with slight per-pane jitter.
	ROUGHNESS = mix(clamp(mix(0.75, 0.95, dirt), 0.05, 1.0), mix(0.04, 0.12, w_id), glass_mask);
	METALLIC = glass_mask * glass_reflect;
	SPECULAR = mix(mix(0.35, 0.6, w_id), 1.0, glass_mask);
	EMISSION = lit_window_color * lit_window_energy * lit;
	AO = clamp(0.55 + 0.45 * v_height_frac, 0.0, 1.0);
	AO_LIGHT_AFFECT = 0.6;
}
