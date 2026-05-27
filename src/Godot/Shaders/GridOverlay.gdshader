// Screen-space debug grid aligned to the scrolling tile map.
// Canvas pixels -> map-local via ViewProjection inverse (viewport_center, zoom, camera_focus).
shader_type canvas_item;
render_mode blend_mix;

uniform bool enabled = true;
uniform vec2 viewport_center_px;
uniform vec2 camera_focus_map_px;
uniform float zoom = 1.0;
uniform float cell_size_px = 64.0;
uniform vec2 grid_center = vec2(0.0);
uniform float grid_radius = 32.0;
uniform float line_width_px = 1.0;
uniform vec4 line_color : source_color = vec4(0.2, 0.22, 0.18, 0.6);

vec2 fragcoord_to_map_local(vec2 fragcoord) {
	float safe_zoom = max(zoom, 0.0001);
	return (fragcoord - viewport_center_px) / safe_zoom + camera_focus_map_px;
}

void fragment() {
	COLOR = vec4(0.0);
	if (enabled) {
		vec2 map_local = fragcoord_to_map_local(FRAGCOORD.xy);
		vec2 grid_f = map_local / cell_size_px;

		float min_gx = grid_center.x - grid_radius;
		float max_gx = grid_center.x + grid_radius + 1.0;
		float min_gy = grid_center.y - grid_radius;
		float max_gy = grid_center.y + grid_radius + 1.0;

		bool in_bounds = grid_f.x >= min_gx - 0.001 && grid_f.x <= max_gx + 0.001
				&& grid_f.y >= min_gy - 0.001 && grid_f.y <= max_gy + 0.001;

		if (in_bounds) {
			float safe_zoom = max(zoom, 0.0001);
			float half_w = line_width_px * 0.5 / (safe_zoom * cell_size_px);
			float fx = fract(grid_f.x);
			float fy = fract(grid_f.y);
			float on_line = 0.0;
			if (fx < half_w || fx > 1.0 - half_w) {
				on_line = 1.0;
			}
			if (fy < half_w || fy > 1.0 - half_w) {
				on_line = 1.0;
			}
			COLOR = vec4(line_color.rgb, line_color.a * on_line);
		}
	}
}
