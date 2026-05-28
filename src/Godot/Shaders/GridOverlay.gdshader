// Grid overlay in world/map-local space via ViewProjection inverse.
shader_type canvas_item;
render_mode blend_mix;

uniform bool enabled = true;
uniform vec2 viewport_center_px;
uniform vec2 camera_focus_map_px;
uniform float zoom = 1.0;
uniform float cell_size_px = 64.0;
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
		float safe_zoom = max(zoom, 0.0001);
		vec2 grid_stroke = abs(fract(map_local / cell_size_px - 0.5) - 0.5);
		// Screen-pixel distance from cell edge (avoids fwidth blow-up at fractional zoom).
		float line_dist_px = min(grid_stroke.x, grid_stroke.y) * cell_size_px * safe_zoom;
		float on_line = 1.0 - smoothstep(
				line_width_px - 0.5,
				line_width_px + 0.5,
				line_dist_px
		);
		COLOR = vec4(line_color.rgb, line_color.a * on_line);
	}
}
