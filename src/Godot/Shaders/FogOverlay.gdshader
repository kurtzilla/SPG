shader_type canvas_item;

uniform bool fog_enabled = true;
uniform vec2 player_world_pos = vec2(0.0, 0.0);
uniform float reveal_radius = 0.0;
uniform vec4 fog_color : source_color = vec4(0.0, 0.0, 0.0, 0.85);

void fragment() {
	COLOR = vec4(0.0);

	if (!fog_enabled) {
		return;
	}

	float dist = distance(VERTEX, player_world_pos);

	if (dist < reveal_radius) {
		COLOR = vec4(fog_color.rgb, 0.0);
	} else {
		COLOR = vec4(fog_color.rgb, 1.0);
	}
}
