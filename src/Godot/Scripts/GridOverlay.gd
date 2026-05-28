class_name GridOverlay
extends ColorRect

## GPU grid overlay derived from world/map-local coordinates.

const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const GRID_SHADER: Shader = preload("res://src/Godot/Shaders/GridOverlay.gdshader")

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
	if not ViewProjection.view_changed.is_connected(_on_view_projection_changed):
		ViewProjection.view_changed.connect(_on_view_projection_changed)
	_read_grid_settings()
	_apply_static_uniforms()
	_invalidate_projection_cache()
	sync_uniforms(null, true)
	_debug_force_initial_sync()


func configure(enabled: bool) -> void:
	_enabled = enabled
	sync_uniforms(null, false)


func set_map_scroll(_map_scroll: Node2D) -> void:
	_invalidate_projection_cache()


func sync_canvas_transform(_map_scroll_node: Node2D = null) -> void:
	if _shader_mat == null:
		return
	var center: Vector2 = _resolve_projection_center()
	var focus: Vector2 = _resolve_camera_focus()
	var safe_zoom: float = ViewProjection.zoom
	if is_zero_approx(safe_zoom):
		safe_zoom = 1.0
	_push_projection_uniforms(center, focus, safe_zoom)


## Headless/test shim; delegates to sync_canvas_transform().
func sync_scroll(_scroll_pos: Vector2, _zoom: float) -> void:
	sync_canvas_transform()


func sync_uniforms(_viewport: Viewport = null, refresh_projection: bool = true) -> void:
	if _shader_mat == null:
		return

	if refresh_projection:
		sync_canvas_transform()

	var visible_state: bool = _resolve_visible_state()
	if visible_state != _cached_visible_state:
		visible = visible_state
		_cached_visible_state = visible_state
	if visible_state != _cached_enabled_param:
		_shader_mat.set_shader_parameter("enabled", visible_state)
		_cached_enabled_param = visible_state


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


func _invalidate_projection_cache() -> void:
	_cached_viewport_center = Vector2(-99999.0, -99999.0)
	_cached_camera_focus = Vector2(-99999.0, -99999.0)
	_cached_zoom = -1.0


func _resolve_projection_center() -> Vector2:
	return ViewProjection.get_screen_center_offset()


func _resolve_camera_focus() -> Vector2:
	return ViewProjection.resolve_camera_focus_map_px(_find_player_node())


func _find_player_node() -> Node2D:
	var tree: SceneTree = get_tree()
	if tree == null:
		return null
	var players: Array[Node] = tree.get_nodes_in_group("player")
	if players.is_empty():
		return null
	return players[0] as Node2D


func _on_view_projection_changed() -> void:
	_invalidate_projection_cache()
	sync_canvas_transform()


func _debug_force_initial_sync() -> void:
	if _shader_mat == null:
		return
	_invalidate_projection_cache()
	var center: Vector2 = _resolve_projection_center()
	var focus: Vector2 = _resolve_camera_focus()
	var safe_zoom: float = ViewProjection.zoom
	if is_zero_approx(safe_zoom):
		safe_zoom = 1.0
	_push_projection_uniforms(center, focus, safe_zoom)
	sync_uniforms(null, true)
	print(
		"[GridOverlay:DEBUG] forced sync center=%s focus=%s zoom=%s visible=%s"
		% [center, focus, safe_zoom, visible]
	)


func _read_grid_settings() -> void:
	_debug_grid_lines = Settings.get_bool("grid.debug_grid_lines")
	_line_width_px = Settings.get_float("grid.line_width_px")
	_line_color = Settings.get_color("grid.line_color")


func _on_setting_changed(path: String) -> void:
	if not path.begins_with("grid."):
		return
	_read_grid_settings()
	_apply_static_uniforms()
	sync_uniforms(null, false)


func _resolve_visible_state() -> bool:
	return _enabled and _debug_grid_lines


func _apply_static_uniforms() -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter("cell_size_px", float(ViewMetricsRes.CELL_SIZE_PX))
	_shader_mat.set_shader_parameter("line_width_px", _line_width_px)
	_shader_mat.set_shader_parameter("line_color", _line_color)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		ViewProjection.notify_viewport_resized()
		_invalidate_projection_cache()
		sync_uniforms()
