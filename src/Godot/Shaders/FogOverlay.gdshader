shader_type canvas_item;

// Explored mask + live vignette: FRAGCOORD -> map_local via canvas_to_map_local (simulated world px).
// Live reveal: distance in map-local space; radius/feather scaled by sandbox_scale.

uniform bool fog_enabled = true;
uniform bool debug_coords = false;
uniform sampler2D explored_mask : filter_nearest, repeat_disable;
uniform mat3 canvas_to_map_local;
uniform vec2 player_sim_position;
uniform float sandbox_scale = 1.0;
uniform float zoom = 1.0;
uniform float reveal_radius_screen_px;
uniform float reveal_feather_screen_px;
uniform vec2 mask_sub_texel_offset;
uniform vec2 world_origin_map_px;
uniform vec2 world_extent_map_px;
uniform vec4 fog_color : source_color = vec4(0.0, 0.0, 0.0, 0.85);

void fragment() {
	COLOR = vec4(0.0);

	if (fog_enabled) {
		vec2 map_local = (canvas_to_map_local * vec3(FRAGCOORD.xy, 1.0)).xy;

		if (debug_coords) {
			COLOR = vec4(UV, 0.0, 1.0);
		} else {
			vec2 uv_raw = (map_local - world_origin_map_px) / world_extent_map_px;
			vec2 uv = fract(uv_raw - mask_sub_texel_offset);
			float explored = texture(explored_mask, uv).r;

			float dist = distance(map_local, player_sim_position);
			float effective_radius = reveal_radius_screen_px * sandbox_scale;
			float effective_feather = reveal_feather_screen_px * sandbox_scale;
			float live_circle = 1.0 - smoothstep(effective_radius - effective_feather, effective_radius, dist);

			float visibility = live_circle;
			if (dist > effective_radius) {
				visibility = max(live_circle, explored);
			}

			COLOR = vec4(fog_color.rgb, fog_color.a * (1.0 - visibility));
		}
	}
}
