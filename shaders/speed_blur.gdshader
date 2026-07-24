shader_type canvas_item;

// Cheap arcade-style speed blur: a weighted radial resample of the frame just
// rendered (SCREEN_TEXTURE), pulling samples toward/away from `center` along
// each pixel's direction from it. This is a full-screen ColorRect overlay, not
// a true per-object motion-vector blur, so it stays a single cheap pass
// regardless of scene complexity (46k buildings included).
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float amount : hint_range(0.0, 1.0) = 0.0;
uniform vec2 center = vec2(0.5, 0.5);

const int SAMPLES = 10;

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 dir = uv - center;
	vec3 col = vec3(0.0);
	float total = 0.0;
	for (int i = 0; i < SAMPLES; i++) {
		float t = float(i) / float(SAMPLES - 1) - 0.5;
		float w = 1.0 - abs(t) * 2.0;
		vec2 sample_uv = uv - dir * t * amount * 0.12;
		col += textureLod(screen_tex, sample_uv, 0.0).rgb * w;
		total += w;
	}
	col /= max(total, 0.0001);
	COLOR = vec4(col, 1.0);
}
