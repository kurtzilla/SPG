extends ColorRect

## GPU grid overlay (shader). Lives on a CanvasLayer so line width stays 1 screen px.

const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const GRID_SHADER: Shader = preload("res://src/Godot/Shaders/GridOverlay.gdshader")

var _enabled: bool = true
var _map_scroll: Node2D
var _center_x: int = 0
var _center_y: int = 0
var _visual_radius: int = 0
var _shader_mat: ShaderMaterial

var _cached_enabled_param: bool = false
var _cached_viewport_center: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_camera_focus: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_zoom: float = -1.0
var _cached_grid_center: Vector2 = Vector2.ZERO
var _cached_grid_radius: float = -1.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchors_preset = Control.PRESET_FULL_RECT
	anchor_right = 1.0
	anchor_bottom = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	color = Color(0.0, 0.0, 0.0, 0.0)

	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = GRID_SHADER
	material = _shader_mat
	_apply_static_uniforms()
	sync_uniforms()


func configure(enabled: bool) -> void:
	_enabled = enabled
	sync_uniforms()


func set_map_scroll(map_scroll: Node2D) -> void:
	_map_scroll = map_scroll
	_invalidate_projection_cache()


func update_region(center_x: int, center_y: int, visual_radius: int) -> void:
	_center_x = center_x
	_center_y = center_y
	_visual_radius = visual_radius
	sync_uniforms()


func on_view_changed() -> void:
	sync_uniforms()


## Authoritative path: explicit ViewProjection inverse uniforms (matches FogOverlay).
func sync_canvas_transform(_map_scroll_node: Node2D = null) -> void:
	if _shader_mat == null:
		return
	var center: Vector2 = ViewProjection.get_screen_center_offset()
	var focus: Vector2 = ViewProjection.map_scroll
	var safe_zoom: float = ViewProjection.zoom
	if is_zero_approx(safe_zoom):
		safe_zoom = 1.0
	_push_projection_uniforms(center, focus, safe_zoom)


## Legacy entry point (used by unit tests).
func sync_scroll(_scroll_pos: Vector2, _zoom: float) -> void:
	sync_canvas_transform()


func sync_uniforms(_viewport: Viewport = null) -> void:
	if _shader_mat == null:
		return

	var enabled_param: bool = _enabled and _visual_radius > 0
	if enabled_param != _cached_enabled_param:
		_shader_mat.set_shader_parameter("enabled", enabled_param)
		_cached_enabled_param = enabled_param

	sync_canvas_transform()

	var grid_center: Vector2 = Vector2(float(_center_x), float(_center_y))
	if grid_center != _cached_grid_center:
		_shader_mat.set_shader_parameter("grid_center", grid_center)
		_cached_grid_center = grid_center

	var grid_radius: float = float(_visual_radius)
	if grid_radius != _cached_grid_radius:
		_shader_mat.set_shader_parameter("grid_radius", grid_radius)
		_cached_grid_radius = grid_radius


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


func _apply_static_uniforms() -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter("cell_size_px", float(ViewMetricsRes.CELL_SIZE_PX))
	_shader_mat.set_shader_parameter("line_width_px", Settings.get_float("grid.line_width_px"))
	_shader_mat.set_shader_parameter("line_color", Settings.get_color("grid.line_color"))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		ViewProjection.invalidate_screen_center_cache()
		_invalidate_projection_cache()
		sync_uniforms()
