shader_type canvas_item;

uniform sampler2D fog_data_texture;
uniform vec2 world_buffer_center_px;
uniform vec2 world_camera_center_px;
uniform vec2 rect_size;
uniform float zoom = 1.0;
uniform float buffer_size_cells = 128.0;
uniform float cell_size_px = 64.0;
uniform vec4 fog_color : source_color = vec4(0.0, 0.0, 0.0, 0.85);

void fragment() {
	vec2 screen_offset_px = (UV - vec2(0.5)) * rect_size / max(zoom, 0.0001);
	vec2 absolute_world_px = world_camera_center_px + screen_offset_px;
	vec2 texture_sample_uv = (absolute_world_px - world_buffer_center_px)
		/ (buffer_size_cells * cell_size_px) + vec2(0.5);

	float alpha_mask = 0.0;
	if (
		texture_sample_uv.x >= 0.0
		&& texture_sample_uv.x <= 1.0
		&& texture_sample_uv.y >= 0.0
		&& texture_sample_uv.y <= 1.0
	) {
		alpha_mask = texture(fog_data_texture, texture_sample_uv).r;
	} else {
		alpha_mask = 0.0;
	}

	float smooth_edge = smoothstep(0.0, 1.0, alpha_mask);
	COLOR = vec4(fog_color.rgb, (1.0 - smooth_edge) * fog_color.a);
}
