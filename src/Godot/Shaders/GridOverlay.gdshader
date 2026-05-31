// Grid overlay in world/map-local space via canvas_to_map (same path as FogOverlay).
shader_type canvas_item;
render_mode unshaded, blend_mix;

uniform bool enabled = true;
uniform vec2 canvas_to_map_x;
uniform vec2 canvas_to_map_y;
uniform vec2 canvas_to_map_origin;
uniform float cell_size_px = 64.0;
uniform float line_width_px = 1.0;
uniform vec4 line_color : source_color = vec4(0.2, 0.22, 0.18, 0.6);

vec2 fragcoord_to_map_local(vec2 fragcoord) {
	return fragcoord.x * canvas_to_map_x + fragcoord.y * canvas_to_map_y + canvas_to_map_origin;
}

void fragment() {
	if (!enabled) {
		discard;
	}
	vec2 map_local = fragcoord_to_map_local(FRAGCOORD.xy);
	float screen_scale = 1.0 / max(length(canvas_to_map_x), 0.0001);
	vec2 grid_stroke = abs(fract(map_local / cell_size_px - 0.5) - 0.5);
	float line_dist_px = min(grid_stroke.x, grid_stroke.y) * cell_size_px * screen_scale;
	float aa = max(fwidth(line_dist_px), 0.75);
	if (line_dist_px > line_width_px + aa) {
		discard;
	}
	float on_line = 1.0 - smoothstep(
			line_width_px - aa * 0.5,
			line_width_px + aa * 0.5,
			line_dist_px
	);
	COLOR = vec4(line_color.rgb, line_color.a * on_line);
}
