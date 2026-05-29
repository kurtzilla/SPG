shader_type canvas_item;
render_mode blend_mix;

uniform vec2 viewport_center_px;
uniform vec2 camera_focus_map_px;
uniform float zoom = 1.0;
uniform vec2 player_world_pos;
uniform vec2 world_buffer_origin_px;
uniform vec2 buffer_size_cells;
uniform float cell_size_px;
uniform float fog_opacity : hint_range(0.0, 1.0) = 1.0;
uniform sampler2D fog_texture : filter_nearest;

void fragment() {
	float safe_zoom = max(zoom, 0.0001);
	vec2 screen_offset = FRAGCOORD.xy - viewport_center_px;
	vec2 fragment_world_pos = camera_focus_map_px + (screen_offset / safe_zoom);
	vec2 local_offset_px = fragment_world_pos - world_buffer_origin_px;
	vec2 total_buffer_size_px = buffer_size_cells * cell_size_px;
	vec2 tex_uv = local_offset_px / total_buffer_size_px;
	vec2 cell_uv_size = vec2(1.0 / buffer_size_cells);

	float alpha_mask = 0.0;
	for (float y = -1.0; y <= 1.0; y += 1.0) {
		for (float x = -1.0; x <= 1.0; x += 1.0) {
			vec2 tap_uv = tex_uv + vec2(x, y) * cell_uv_size;
			if (
				tap_uv.x >= 0.0 && tap_uv.x <= 1.0
				&& tap_uv.y >= 0.0 && tap_uv.y <= 1.0
			) {
				alpha_mask += 1.0 - texture(fog_texture, tap_uv).r;
			} else {
				alpha_mask += 1.0;
			}
		}
	}
	alpha_mask /= 9.0;

	float smooth_edge = smoothstep(0.2, 0.8, alpha_mask);
	COLOR = vec4(0.0, 0.0, 0.0, smooth_edge * fog_opacity);
}
