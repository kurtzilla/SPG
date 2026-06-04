shader_type canvas_item;

uniform vec2 player_pixel_pos;
uniform float sight_radius;
uniform float feather_width;
uniform float realtime_radius;
uniform float realtime_feather_px = 16.0;
uniform float shroud_opacity = 0.85;

uniform sampler2D history_texture: filter_linear, repeat_disable;
uniform vec2 map_texture_origin_tiles;
uniform vec2 map_texture_size_tiles;
uniform float cell_size = 32.0;

varying vec2 world_position_coordinate;

void vertex() {
	world_position_coordinate = VERTEX;
}

float sample_history_blurred(vec2 history_uv) {
	vec2 texel = 0.5 / map_texture_size_tiles;
	float s00 = texture(history_texture, history_uv - vec2(texel.x, texel.y)).r;
	float s10 = texture(history_texture, history_uv + vec2(texel.x, -texel.y)).r;
	float s01 = texture(history_texture, history_uv + vec2(-texel.x, texel.y)).r;
	float s11 = texture(history_texture, history_uv + texel).r;
	return (s00 + s10 + s01 + s11) * 0.25;
}

void fragment() {
	vec2 world_pos = world_position_coordinate;
	vec2 tile_coord_f = world_pos / cell_size;
	vec2 history_uv = (tile_coord_f - map_texture_origin_tiles) / map_texture_size_tiles;

	float history_sample = 0.0;
	if (history_uv.x >= 0.0 && history_uv.x <= 1.0 && history_uv.y >= 0.0 && history_uv.y <= 1.0) {
		float blurred = sample_history_blurred(history_uv);
		history_sample = smoothstep(0.15, 0.85, blurred);
	}

	vec2 diff = world_pos - player_pixel_pos;
	float current_alpha = shroud_opacity;

	float dist = length(diff);
	float min_visible = sight_radius - feather_width;
	if (dist < min_visible) {
		current_alpha = 0.0;
	} else if (dist < sight_radius) {
		float weight = (dist - min_visible) / feather_width;
		current_alpha = mix(0.0, shroud_opacity, weight);
	}

	float realtime_reveal = 1.0 - smoothstep(
		realtime_radius - realtime_feather_px,
		realtime_radius,
		dist
	);
	float combined_reveal = max(history_sample, realtime_reveal);
	current_alpha = min(current_alpha, shroud_opacity * (1.0 - combined_reveal));

	COLOR = vec4(0.0, 0.0, 0.0, current_alpha);
}
