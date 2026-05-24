// Fog cover = explored mask only. Sprite is positioned/scaled to the mask canvas bounds,
// so UV (0→1) maps directly to explored mask (0→1). No world-coordinate math needed.
shader_type canvas_item;
render_mode blend_mix;

uniform vec4 fog_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform sampler2D explored_mask : filter_linear, repeat_disable;

void fragment() {
	float hidden = texture(explored_mask, UV).r;
	COLOR = vec4(fog_color.rgb, hidden);
}
