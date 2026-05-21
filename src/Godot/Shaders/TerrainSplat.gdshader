// Unused — RimWorld-style directional transition overlay sprites used instead.
shader_type canvas_item;

// neighbor_weights: x=north, y=south, z=east, w=west
uniform sampler2D texture_base : source_color, filter_nearest;
uniform sampler2D texture_overlay : source_color, filter_nearest;
uniform sampler2D texture_noise_mask : source_color, filter_nearest;
uniform float overlay_weight : hint_range(0.0, 1.0) = 0.0;
uniform vec4 neighbor_weights = vec4(0.0, 0.0, 0.0, 0.0);
uniform float edge_bleed : hint_range(0.0, 0.5) = 0.35;
uniform float noise_world_scale = 0.015625;

varying vec2 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 0.0, 1.0)).xy;
}

void fragment() {
	vec4 base_col = texture(texture_base, UV);
	vec4 overlay_col = texture(texture_overlay, UV);

	vec2 noise_uv = fract(world_pos * noise_world_scale);
	float mask = texture(texture_noise_mask, noise_uv).r;
	float margin = 0.05;
	float organic_t = smoothstep(overlay_weight - margin, overlay_weight + margin, mask);

	float bleed = edge_bleed;
	float edge_n = neighbor_weights.x * (1.0 - smoothstep(0.0, bleed, UV.y));
	float edge_s = neighbor_weights.y * smoothstep(1.0 - bleed, 1.0, UV.y);
	float edge_e = neighbor_weights.z * (1.0 - smoothstep(0.0, bleed, 1.0 - UV.x));
	float edge_w = neighbor_weights.w * smoothstep(1.0 - bleed, 1.0, UV.x);
	float edge_t = max(max(edge_n, edge_s), max(edge_e, edge_w));

	float blend_t = clamp(max(edge_t, organic_t), 0.0, 1.0);
	COLOR = mix(base_col, overlay_col, blend_t);
}
