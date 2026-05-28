shader_type canvas_item;
render_mode blend_mix;

uniform sampler2D fog_data_texture : filter_nearest, repeat_disable;
uniform vec2 viewport_center_px;
uniform vec2 camera_focus_map_px;
uniform float zoom = 1.0;
uniform vec2 world_buffer_center_px;
uniform float buffer_size_cells;
uniform float cell_size_px = 64.0;
uniform vec4 fog_color : source_color = vec4(0.0, 0.0, 0.0, 0.85);

vec2 fragcoord_to_map_local(vec2 fragcoord) {
	float safe_zoom = max(zoom, 0.0001);
	return (fragcoord - viewport_center_px) / safe_zoom + camera_focus_map_px;
}

void fragment() {
	vec2 world_px = fragcoord_to_map_local(FRAGCOORD.xy);
	vec2 offset_from_center_px = world_px - world_buffer_center_px;
	float data_window_size_px = buffer_size_cells * cell_size_px;
	vec2 texture_sample_uv = (offset_from_center_px / data_window_size_px) + vec2(0.5);

	float alpha_mask = 1.0;
	if (
		texture_sample_uv.x >= 0.0 && texture_sample_uv.x <= 1.0
		&& texture_sample_uv.y >= 0.0 && texture_sample_uv.y <= 1.0
	) {
		alpha_mask = 1.0 - texture(fog_data_texture, texture_sample_uv).r;
	}

	float smooth_edge = smoothstep(0.0, 1.0, alpha_mask);
	COLOR = vec4(fog_color.rgb, smooth_edge * fog_color.a);
}
