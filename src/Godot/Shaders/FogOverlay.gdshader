shader_type canvas_item;

uniform bool fog_enabled = true;
uniform bool debug_coords = false;
uniform sampler2D explored_mask : filter_nearest, repeat_disable;
uniform vec2 viewport_center_px;
uniform vec2 camera_focus_map_px;
uniform float zoom = 1.0;
uniform vec2 player_sim_position;

uniform float reveal_radius_map_px;
uniform float reveal_feather_map_px;

uniform vec2 mask_sub_texel_offset;
uniform vec2 world_origin_map_px;
uniform vec2 world_extent_map_px;
uniform vec4 fog_color : source_color = vec4(0.0, 0.0, 0.0, 0.85);

vec2 fragcoord_to_map_local(vec2 fragcoord) {
	float safe_zoom = max(zoom, 0.0001);
	return (fragcoord - viewport_center_px) / safe_zoom + camera_focus_map_px;
}

void fragment() {
	COLOR = vec4(0.0);

	if (fog_enabled) {
		vec2 map_local = fragcoord_to_map_local(FRAGCOORD.xy);

		if (debug_coords) {
			COLOR = vec4(UV, 0.0, 1.0);
		} else {
			vec2 uv_raw = (map_local - world_origin_map_px) / world_extent_map_px;
			vec2 uv_wrapped = fract(uv_raw - mask_sub_texel_offset);
			float explored = texture(explored_mask, uv_wrapped).r;

			float dist = distance(map_local, player_sim_position);
			float effective_radius = reveal_radius_map_px;
			float effective_feather = reveal_feather_map_px;

			float live_circle = 1.0 - smoothstep(effective_radius - effective_feather, effective_radius, dist);
			float visibility = max(live_circle, explored);

			COLOR = vec4(fog_color.rgb, fog_color.a * (1.0 - visibility));
		}
	}
}
