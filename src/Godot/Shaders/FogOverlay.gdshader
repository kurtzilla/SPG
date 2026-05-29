shader_type canvas_item;
render_mode blend_mix;

uniform vec2 canvas_to_map_x;
uniform vec2 canvas_to_map_y;
uniform vec2 canvas_to_map_origin;
uniform vec2 world_buffer_origin_px;
uniform vec2 buffer_size_cells;
uniform float cell_size_px;
uniform float fog_opacity : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D fog_texture : filter_nearest;

void fragment() {
	vec2 fragment_world_pos = FRAGCOORD.x * canvas_to_map_x + FRAGCOORD.y * canvas_to_map_y + canvas_to_map_origin;
	vec2 local_offset_px = fragment_world_pos - world_buffer_origin_px;

	float alpha_mask = 1.0;
	ivec2 cell = ivec2(floor(local_offset_px / cell_size_px));
	if (
		cell.x >= 0
		&& cell.y >= 0
		&& cell.x < int(buffer_size_cells.x)
		&& cell.y < int(buffer_size_cells.y)
	) {
		vec2 tap_uv = (vec2(cell) + 0.5) / buffer_size_cells;
		alpha_mask = 1.0 - texture(fog_texture, tap_uv).r;
	}

	COLOR = vec4(0.0, 0.0, 0.0, alpha_mask * fog_opacity);
}
