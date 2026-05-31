shader_type canvas_item;
render_mode blend_mix;

uniform vec2 canvas_to_map_x = vec2(1.0, 0.0);
uniform vec2 canvas_to_map_y = vec2(0.0, 1.0);
uniform vec2 canvas_to_map_origin = vec2(0.0);
uniform vec2 world_buffer_origin_px = vec2(0.0);
uniform vec2 buffer_size_cells = vec2(128.0);
uniform float cell_size_px = 32.0;
uniform float fog_opacity : hint_range(0.0, 1.0) = 1.0;
uniform float fog_edge_aa_strength : hint_range(0.0, 1.0) = 0.0;
uniform sampler2D fog_texture : filter_nearest, repeat_disable;
uniform vec2 player_map_px = vec2(0.0);
uniform float reveal_radius_cells = 14.0;
uniform float reveal_feather_cells = 0.0;
uniform float live_disc_enabled = 0.0;

float mask_at_map_px(vec2 world_px) {
	vec2 local_offset_px = world_px - world_buffer_origin_px;
	vec2 buffer_px = buffer_size_cells * cell_size_px;
	if (
		local_offset_px.x < 0.0
		|| local_offset_px.y < 0.0
		|| local_offset_px.x >= buffer_px.x
		|| local_offset_px.y >= buffer_px.y
	) {
		return 0.0;
	}
	vec2 uv = local_offset_px / buffer_px;
	vec2 half_texel = vec2(0.5) / buffer_size_cells;
	uv = clamp(uv, half_texel, vec2(1.0) - half_texel);
	return texture(fog_texture, uv).r;
}

// Matches VisibilityModel.ComputeEllipseRevealStrengthAtPx (cell-space ellipse + feather band).
float live_disc_strength_at_px(vec2 world_px) {
	if (live_disc_enabled < 0.5 || reveal_radius_cells <= 0.0) {
		return 0.0;
	}
	vec2 cell_pos = world_px / cell_size_px;
	vec2 center_cell = player_map_px / cell_size_px;
	vec2 d = (cell_pos - center_cell) / reveal_radius_cells;
	float dist = length(d);
	float feather_norm = reveal_feather_cells / reveal_radius_cells;
	if (feather_norm <= 0.0) {
		return dist <= 1.0 ? 1.0 : 0.0;
	}
	float inner = 1.0 - feather_norm;
	float outer = 1.0 + feather_norm;
	if (dist <= inner) {
		return 1.0;
	}
	if (dist >= outer) {
		return 0.0;
	}
	float t = (dist - inner) / (outer - inner);
	return 1.0 - smoothstep(0.0, 1.0, t);
}

void fragment() {
	vec2 world_px = FRAGCOORD.x * canvas_to_map_x + FRAGCOORD.y * canvas_to_map_y + canvas_to_map_origin;
	vec2 local_offset_px = world_px - world_buffer_origin_px;
	vec2 buffer_px = buffer_size_cells * cell_size_px;

	float mask_revealed = 0.0;
	if (
		local_offset_px.x >= 0.0
		&& local_offset_px.y >= 0.0
		&& local_offset_px.x < buffer_px.x
		&& local_offset_px.y < buffer_px.y
	) {
		mask_revealed = mask_at_map_px(world_px);
	}
	float disc_revealed = live_disc_strength_at_px(world_px);
	float revealed = mask_revealed;
	if (live_disc_enabled > 0.5 && mask_revealed <= 0.0) {
		// Gap-fill in fully hidden cells only; baked mask (incl. feather) is authoritative elsewhere.
		revealed = disc_revealed;
	}

	float alpha_mask = 1.0 - revealed;
	if (fog_edge_aa_strength > 0.0) {
		float aa = max(fwidth(revealed), 0.001) * fog_edge_aa_strength;
		alpha_mask = 1.0 - smoothstep(0.0 - aa, aa, revealed);
	}

	COLOR = vec4(0.0, 0.0, 0.0, alpha_mask * fog_opacity);
}
