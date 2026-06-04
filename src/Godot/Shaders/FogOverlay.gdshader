shader_type canvas_item;

// Enforce linear filtering so the edges of our 50x50 tile block interpolate smoothly
uniform sampler2D history_texture : hint_default_black, filter_linear;
uniform vec2 player_pixel_pos;
uniform float sight_radius;
uniform float shroud_opacity = 0.85;
uniform vec2 map_texture_origin_tiles;
uniform vec2 map_texture_size_tiles;
uniform float cell_size = 32.0;

varying vec2 world_coord;

void vertex() {
	world_coord = VERTEX;
}

void fragment() {
	// 1. Force base canvas color to pure black shroud
	COLOR.rgb = vec3(0.0);

	// 2. Real-time movement circle evaluation in pixel-space
	float dist = length(world_coord - player_pixel_pos);
	float visual_softness = 8.0;
	float in_smooth_circle = smoothstep(sight_radius, max(0.0, sight_radius - visual_softness), dist);

	// 3. Sample history texture using established tile-space UV mapping
	vec2 history_uv = (world_coord / cell_size - map_texture_origin_tiles) / map_texture_size_tiles;
	vec4 historical_sample = texture(history_texture, history_uv);

	// Read the tracking data channel (matching FogManager's CPU format)
	float raw_history = historical_sample.r;
	float smoothed_history = smoothstep(0.1, 0.8, raw_history);

	// 4. INVERT VISIBILITY MASK:
	// Maps stamped CPU values to a cleared window (0.0 fog)
	// and unvisited coordinates to solid shroud (1.0 fog)
	float fog_history = 1.0 - smoothed_history;

	// 5. Combine real-time active vision disk with the tracking trail
	float final_mask = min(fog_history, 1.0 - in_smooth_circle);

	// 6. Write out final visibility to the fog layer's opacity channel
	COLOR.a = final_mask * shroud_opacity;
}
