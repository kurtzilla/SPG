class_name GridOverlay
extends ColorRect

## Debug grid overlay; projection uniforms come from ViewFrame only.

const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const GRID_SHADER: Shader = preload("res://src/Godot/Shaders/GridOverlay.gdshader")
const ViewFrameScript = preload("res://src/Godot/Scripts/ViewFrame.gd")

var _enabled: bool = false
var _shader_mat: ShaderMaterial

var _debug_grid_lines: bool = false
var _line_width_px: float = 1.0
var _line_color: Color = Color.WHITE

var _cached_enabled_param: bool = false
var _cached_visible_state: bool = false
var _cached_viewport_center: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_camera_focus: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_zoom: float = -1.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchors_preset = Control.PRESET_FULL_RECT
	anchor_right = 1.0
	anchor_bottom = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	color = Color(0.0, 0.0, 0.0, 0.0)
	visible = false

	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = GRID_SHADER
	material = _shader_mat

	if not Settings.setting_changed.is_connected(_on_setting_changed):
		Settings.setting_changed.connect(_on_setting_changed)
	_read_grid_settings()
	_apply_static_uniforms()


func configure(enabled: bool) -> void:
	_enabled = enabled
	_update_visibility_from_enabled()


func apply_view_frame(frame: ViewFrameScript) -> void:
	if _shader_mat == null or frame == null:
		return
	_push_projection_uniforms(frame.viewport_center, frame.camera_focus_map_px, frame.zoom)
	_update_visibility_from_enabled()


func _push_projection_uniforms(center: Vector2, focus: Vector2, safe_zoom: float) -> void:
	if center != _cached_viewport_center:
		_shader_mat.set_shader_parameter("viewport_center_px", center)
		_cached_viewport_center = center
	if focus != _cached_camera_focus:
		_shader_mat.set_shader_parameter("camera_focus_map_px", focus)
		_cached_camera_focus = focus
	if not is_equal_approx(safe_zoom, _cached_zoom):
		_shader_mat.set_shader_parameter("zoom", safe_zoom)
		_cached_zoom = safe_zoom


func _update_visibility_from_enabled() -> void:
	var visible_state: bool = _enabled and _debug_grid_lines
	if visible_state != _cached_visible_state:
		visible = visible_state
		_cached_visible_state = visible_state
	if visible_state != _cached_enabled_param:
		_shader_mat.set_shader_parameter("enabled", visible_state)
		_cached_enabled_param = visible_state


func _read_grid_settings() -> void:
	_debug_grid_lines = Settings.get_bool("grid.debug_grid_lines")
	_line_width_px = Settings.get_float("grid.line_width_px")
	_line_color = Settings.get_color("grid.line_color")


func _on_setting_changed(path: String) -> void:
	if not path.begins_with("grid."):
		return
	_read_grid_settings()
	_apply_static_uniforms()
	_update_visibility_from_enabled()


func _apply_static_uniforms() -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter("cell_size_px", float(ViewMetricsRes.CELL_SIZE_PX))
	_shader_mat.set_shader_parameter("line_width_px", _line_width_px)
	_shader_mat.set_shader_parameter("line_color", _line_color)
