class_name GridOverlay
extends CanvasLayer

## Debug grid overlay; uses canvas_to_map via ViewProjection uniforms.
##
## WIRING INVARIANT — script on CanvasLayer root; GridDrawRect/GridDisplay are display only.

const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const GRID_SHADER: Shader = preload("res://src/Godot/Shaders/GridOverlay.gdshader")
const ViewFrameScript = preload("res://src/Godot/Scripts/ViewFrame.gd")
const GridPerfProfileRes = preload("res://src/Godot/Scripts/GridPerfProfile.gd")

@onready var _grid_viewport: SubViewport = $GridViewport
@onready var _grid_draw_rect: ColorRect = $GridViewport/GridDrawRect
@onready var _grid_display: TextureRect = $GridDisplay

var _enabled: bool = false
var _shader_mat: ShaderMaterial

var _debug_grid_lines: bool = false
var _line_width_px: float = 1.0
var _line_color: Color = Color.WHITE

var _cached_enabled_param: bool = false
var _cached_visible_state: bool = false
var _cached_canvas_to_map: Transform2D = Transform2D.IDENTITY
var _canvas_to_map_cached: bool = false
var _cached_viewport_size: Vector2i = Vector2i.ZERO


static func validate_host_node(node: Node) -> bool:
	if node == null:
		return false
	if not node is GridOverlay:
		return false
	return node.has_method("configure") and node.has_method("apply_view_frame")


static func collect_scene_wiring_failures(grid_root: Node) -> PackedStringArray:
	var failures: PackedStringArray = PackedStringArray()
	if not validate_host_node(grid_root):
		failures.append("GridOverlay host must be CanvasLayer + GridOverlay.gd with configure/apply_view_frame")
		return failures
	var grid: GridOverlay = grid_root as GridOverlay
	var viewport_node: Node = grid.get_node_or_null("GridViewport")
	if viewport_node == null:
		failures.append("GridOverlay missing child GridViewport")
	elif not viewport_node is SubViewport:
		failures.append("GridOverlay/GridViewport must be SubViewport")
	var draw_rect: Node = grid.get_node_or_null("GridViewport/GridDrawRect")
	if draw_rect == null:
		failures.append("GridOverlay missing GridViewport/GridDrawRect")
	elif not draw_rect is ColorRect:
		failures.append("GridViewport/GridDrawRect must be ColorRect")
	elif draw_rect.get_script() != null:
		failures.append("GridOverlay.gd must not be on GridDrawRect — move script to CanvasLayer root")
	var display: Node = grid.get_node_or_null("GridDisplay")
	if display == null:
		failures.append("GridOverlay missing child GridDisplay")
	elif not display is TextureRect:
		failures.append("GridOverlay/GridDisplay must be TextureRect")
	elif display.get_script() != null:
		failures.append("GridOverlay.gd must not be on GridDisplay")
	return failures


static func collect_shader_failures() -> PackedStringArray:
	var failures: PackedStringArray = PackedStringArray()
	var shader: Shader = load("res://src/Godot/Shaders/GridOverlay.gdshader") as Shader
	if shader == null:
		failures.append("GridOverlay.gdshader failed to load (compile error — check Godot output)")
		return failures
	var mat := ShaderMaterial.new()
	mat.shader = shader
	if mat.shader == null:
		failures.append("GridOverlay.gdshader did not bind to ShaderMaterial")
	return failures


static func collect_bootstrap_failures(grid: GridOverlay) -> PackedStringArray:
	var failures: PackedStringArray = PackedStringArray()
	if not grid.is_shader_ready():
		failures.append("GridOverlay.configure(true) did not initialize shader material")
		return failures
	var mat: Material = grid._grid_draw_rect.material
	if mat == null or not mat is ShaderMaterial:
		failures.append("GridDrawRect has no ShaderMaterial after bootstrap")
	elif (mat as ShaderMaterial).shader == null:
		failures.append("GridDrawRect ShaderMaterial.shader is null after bootstrap")
	return failures


func _ready() -> void:
	if not Settings.setting_changed.is_connected(_on_setting_changed):
		Settings.setting_changed.connect(_on_setting_changed)
	_read_grid_settings()
	_setup_display_nodes()
	_update_presentation_from_state()


func configure(enabled: bool) -> void:
	_enabled = enabled
	if _enabled:
		_ensure_shader_resources()
	_update_presentation_from_state()


func is_shader_ready() -> bool:
	return _shader_mat != null


func tick_presentation(delta: float) -> void:
	if not _is_presentation_active():
		return
	GridPerfProfileRes.maybe_report(delta)


func apply_view_frame(frame: ViewFrameScript) -> void:
	if not _is_presentation_active() or frame == null:
		return
	var t0: int = GridPerfProfileRes.begin(&"apply_view_frame")
	if not _ensure_shader_resources():
		GridPerfProfileRes.end(&"apply_view_frame", t0)
		return
	var viewport_resized: bool = _sync_subviewport_size()
	if not viewport_resized and _canvas_to_map_cached and frame.canvas_to_map_local.is_equal_approx(_cached_canvas_to_map):
		GridPerfProfileRes.end(&"apply_view_frame", t0)
		return
	_push_canvas_to_map_uniforms(frame.canvas_to_map_local)
	_invalidate_gpu_cache()
	GridPerfProfileRes.end(&"apply_view_frame", t0)


func apply_canvas_transform(canvas_to_map: Transform2D) -> void:
	if not _is_presentation_active():
		return
	var t0: int = GridPerfProfileRes.begin(&"apply_view_frame")
	if not _ensure_shader_resources():
		GridPerfProfileRes.end(&"apply_view_frame", t0)
		return
	var viewport_resized: bool = _sync_subviewport_size()
	if not viewport_resized and _canvas_to_map_cached and canvas_to_map.is_equal_approx(_cached_canvas_to_map):
		GridPerfProfileRes.end(&"apply_view_frame", t0)
		return
	_push_canvas_to_map_uniforms(canvas_to_map)
	_invalidate_gpu_cache()
	GridPerfProfileRes.end(&"apply_view_frame", t0)


func _setup_display_nodes() -> void:
	_grid_display.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid_display.visible = false
	_grid_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_grid_viewport.transparent_bg = true
	_grid_draw_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_grid_draw_rect.color = Color(0.0, 0.0, 0.0, 0.0)


func _ensure_shader_resources() -> bool:
	if _shader_mat != null:
		return true
	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = GRID_SHADER
	if _shader_mat.shader == null:
		_shader_mat = null
		return false
	_grid_draw_rect.material = _shader_mat
	_grid_display.texture = _grid_viewport.get_texture()
	_apply_static_uniforms()
	_cached_enabled_param = false
	return true


func _push_canvas_to_map_uniforms(canvas_to_map: Transform2D) -> void:
	var t0: int = GridPerfProfileRes.begin(&"push_canvas_uniforms")
	_shader_mat.set_shader_parameter("canvas_to_map_x", canvas_to_map.x)
	_shader_mat.set_shader_parameter("canvas_to_map_y", canvas_to_map.y)
	_shader_mat.set_shader_parameter("canvas_to_map_origin", canvas_to_map.origin)
	_cached_canvas_to_map = canvas_to_map
	_canvas_to_map_cached = true
	GridPerfProfileRes.end(&"push_canvas_uniforms", t0)


func _invalidate_projection_cache() -> void:
	_cached_canvas_to_map = Transform2D.IDENTITY
	_canvas_to_map_cached = false


func _invalidate_gpu_cache() -> void:
	var t0: int = GridPerfProfileRes.begin(&"grid_gpu_invalidate")
	_grid_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	GridPerfProfileRes.record_gpu_refresh()
	GridPerfProfileRes.end(&"grid_gpu_invalidate", t0)


func _sync_subviewport_size() -> bool:
	var size: Vector2 = _resolve_viewport_size()
	var size_i: Vector2i = Vector2i(maxi(int(size.x), 1), maxi(int(size.y), 1))
	if size_i == _cached_viewport_size:
		return false
	_cached_viewport_size = size_i
	_grid_viewport.size = size_i
	_invalidate_projection_cache()
	return true


func _resolve_viewport_size() -> Vector2:
	var vp: Viewport = get_viewport()
	if vp != null:
		return vp.get_visible_rect().size
	var main_loop: MainLoop = Engine.get_main_loop()
	if main_loop is SceneTree:
		var tree: SceneTree = main_loop as SceneTree
		if tree.root != null:
			return tree.root.get_viewport().get_visible_rect().size
	return Vector2(1920.0, 1080.0)


func _is_presentation_active() -> bool:
	return _enabled and _debug_grid_lines


func _update_presentation_from_state() -> void:
	var visible_state: bool = _is_presentation_active()
	if visible_state != _cached_visible_state:
		_grid_display.visible = visible_state
		_cached_visible_state = visible_state
		if visible_state:
			_invalidate_projection_cache()
	if visible_state:
		if not _ensure_shader_resources():
			return
		if not _cached_enabled_param:
			_shader_mat.set_shader_parameter("enabled", true)
			_cached_enabled_param = true
		_sync_subviewport_size()
		_invalidate_gpu_cache()
	else:
		_grid_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		if _shader_mat != null and _cached_enabled_param:
			_shader_mat.set_shader_parameter("enabled", false)
			_cached_enabled_param = false


func _read_grid_settings() -> void:
	_debug_grid_lines = Settings.get_bool("grid.debug_grid_lines")
	_line_width_px = Settings.get_float("grid.line_width_px")
	_line_color = Settings.get_color("grid.line_color")


func _on_setting_changed(path: String) -> void:
	if not path.begins_with("grid."):
		return
	var was_visible: bool = _cached_visible_state
	_read_grid_settings()
	if _shader_mat != null:
		_apply_static_uniforms()
	_update_presentation_from_state()
	if _cached_visible_state and not was_visible:
		apply_canvas_transform(ViewProjection.canvas_to_map_local_transform())


func _apply_static_uniforms() -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter("cell_size_px", float(ViewMetricsRes.CELL_SIZE_PX))
	_shader_mat.set_shader_parameter("line_width_px", _line_width_px)
	_shader_mat.set_shader_parameter("line_color", _line_color)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		if not _is_presentation_active():
			return
		if _sync_subviewport_size() and _shader_mat != null:
			_invalidate_gpu_cache()
