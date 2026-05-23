// Fog cover: screen-space FRAGCOORD -> world_pos -> reveal. CPU twin: FogCoverEval.gd
shader_type canvas_item;render_mode blend_mix;

uniform vec4 fog_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform vec2 player_world = vec2(0.0, 0.0);
uniform float sight_radius_m = 10.0;
uniform float feather_m = 2.0;
uniform sampler2D explored_mask : filter_linear, repeat_disable;
uniform vec2 mask_origin_world = vec2(0.0, 0.0);
uniform vec2 mask_world_size = vec2(100.0, 100.0);
uniform vec2 map_scroll_pos = vec2(0.0, 0.0);
uniform float pixels_per_meter = 32.0;

void fragment() {
	// Canvas (FRAGCOORD) -> WorldM: mirrors ViewTransforms.canvas_to_world_m in GDScript.
	vec2 world_pos = (FRAGCOORD.xy - map_scroll_pos) / pixels_per_meter;

	// Sample explored mask using world-space UV (independent of sprite size).
	vec2 explored_uv = (world_pos - mask_origin_world) / mask_world_size;
	float hidden = 1.0;
	if (explored_uv.x >= 0.0 && explored_uv.x <= 1.0 && explored_uv.y >= 0.0 && explored_uv.y <= 1.0) {
		hidden = texture(explored_mask, explored_uv).r;
	}

	float dist_m = distance(world_pos, player_world);
	float live = smoothstep(sight_radius_m, sight_radius_m - feather_m, dist_m);
	float reveal = max(live, 1.0 - hidden);

	COLOR = vec4(fog_color.rgb, clamp(1.0 - reveal, 0.0, 1.0));
}
