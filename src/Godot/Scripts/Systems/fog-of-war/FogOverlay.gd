extends ColorRect

## GPU fog overlay. Lives on a CanvasLayer; scroll/zoom synced from MainSandbox.

const FOG_SHADER: Shader = preload("res://src/Godot/Shaders/FogOverlay.gdshader")
const ViewMetricsScript = preload("res://src/Godot/Scripts/ViewMetrics.gd")

@export var debug_coords: bool = false
@export var debug_startup_coords: bool = false

var _map_scroll: Node2D
var _player: Node2D
var _shader_mat: ShaderMaterial
var _cached_viewport_center: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_camera_focus: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_zoom: float = -1.0
var _cached_player_sim_position: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_reveal_radius_map_px: float = -1.0
var _cached_reveal_feather_map_px: float = -1.0
var _cached_fog_enabled: bool = false
var _cached_debug_coords: bool = false
var _cached_world_origin: Vector2 = Vector2.ZERO
var _cached_world_extent: Vector2 = Vector2.ONE
var _has_pushed_projection: bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	anchors_preset = Control.PRESET_FULL_RECT
	anchor_right = 1.0
	anchor_bottom = 1.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	color = Color(0.0, 0.0, 0.0, 0.0)

	_shader_mat = ShaderMaterial.new()
	_shader_mat.shader = FOG_SHADER
	material = _shader_mat
	_shader_mat.set_shader_parameter(&"fog_enabled", false)
	_cached_fog_enabled = false
	_shader_mat.set_shader_parameter(&"world_origin_map_px", Vector2.ZERO)
	_shader_mat.set_shader_parameter(&"world_extent_map_px", Vector2.ONE)
	_cached_world_origin = Vector2.ZERO
	_cached_world_extent = Vector2.ONE
	_push_debug_coords()
	_log_startup_coords("ready")


func get_shader_material() -> ShaderMaterial:
	return _shader_mat


func set_map_scroll(map_scroll: Node2D) -> void:
	_map_scroll = map_scroll
	_invalidate_projection_cache()
	force_resync_scroll()
	call_deferred("force_resync_scroll")


func set_player(player: Node2D) -> void:
	_player = player
	_cached_player_sim_position = Vector2(-99999.0, -99999.0)
	_sync_player_map_px()
	force_resync_scroll()


func update_fog_vision_metrics(radius_cells: float, feather_cells: float) -> void:
	if _shader_mat == null:
		return
	var radius_map_px: float = radius_cells * float(ViewMetricsScript.CELL_SIZE_PX)
	var feather_map_px: float = feather_cells * float(ViewMetricsScript.CELL_SIZE_PX)
	if not is_equal_approx(radius_map_px, _cached_reveal_radius_map_px):
		_shader_mat.set_shader_parameter(&"reveal_radius_map_px", radius_map_px)
		_cached_reveal_radius_map_px = radius_map_px
	if not is_equal_approx(feather_map_px, _cached_reveal_feather_map_px):
		_shader_mat.set_shader_parameter(&"reveal_feather_map_px", feather_map_px)
		_cached_reveal_feather_map_px = feather_map_px


func configure(fog_enabled: bool, fog_color: Color) -> void:
	if _shader_mat == null:
		return
	_shader_mat.set_shader_parameter(&"fog_enabled", fog_enabled)
	_shader_mat.set_shader_parameter(&"fog_color", fog_color)
	_cached_fog_enabled = fog_enabled
	_push_debug_coords()


func apply_static_uniforms(
	world_origin: Vector2,
	world_extent: Vector2,
	explored_mask: Texture2D
) -> void:
	if _shader_mat == null:
		return
	_cached_world_origin = world_origin
	_cached_world_extent = world_extent
	_shader_mat.set_shader_parameter(&"world_origin_map_px", world_origin)
	_shader_mat.set_shader_parameter(&"world_extent_map_px", world_extent)
	if explored_mask != null:
		_shader_mat.set_shader_parameter(&"explored_mask", explored_mask)

	_invalidate_projection_cache()
	sync_canvas_transform()
	_log_startup_coords("apply_static_uniforms")


## Authoritative path: same inverse as ViewProjection.screen_to_world (explicit shader uniforms).
func sync_canvas_transform(_map_scroll_node: Node2D = null) -> void:
	if _shader_mat == null:
		return
	var center: Vector2 = ViewProjection.get_screen_center_offset()
	var focus: Vector2 = ViewProjection.map_scroll
	var safe_zoom: float = ViewProjection.zoom
	if is_zero_approx(safe_zoom):
		safe_zoom = 1.0
	_push_projection_uniforms(center, focus, safe_zoom)
	_log_startup_coords("sync_canvas_transform")


## Legacy entry point (used by unit tests); pushes ViewProjection-equivalent uniforms.
func sync_scroll(_scroll_pos: Vector2, _zoom: float) -> void:
	if _shader_mat == null:
		return
	sync_canvas_transform()


func force_resync_scroll() -> void:
	_invalidate_projection_cache()
	sync_canvas_transform()
	_log_startup_coords("force_resync")


func on_view_changed() -> void:
	_cached_player_sim_position = Vector2(-99999.0, -99999.0)
	_invalidate_projection_cache()
	force_resync_scroll()
	_sync_player_map_px()


func _process(_delta: float) -> void:
	_sync_player_map_px()
	var extent_invalid: bool = _cached_world_extent.length_squared() < 1.0
	if not _has_pushed_projection or extent_invalid:
		sync_canvas_transform()


func sync_runtime(fog_map) -> void:
	if _shader_mat == null or fog_map == null:
		return
	if not fog_map.has_method(&"push_runtime_uniforms"):
		return
	if fog_map.enabled != _cached_fog_enabled:
		_shader_mat.set_shader_parameter(&"fog_enabled", fog_map.enabled)
		_cached_fog_enabled = fog_map.enabled
	fog_map.push_runtime_uniforms(_shader_mat)
	_push_debug_coords()


func _sync_player_map_px() -> void:
	if _shader_mat == null or _player == null:
		return
	var sim_pos: Vector2 = _player.position
	if sim_pos == _cached_player_sim_position:
		return
	_shader_mat.set_shader_parameter(&"player_sim_position", sim_pos)
	_cached_player_sim_position = sim_pos


func _push_projection_uniforms(center: Vector2, focus: Vector2, safe_zoom: float) -> void:
	if center != _cached_viewport_center:
		_shader_mat.set_shader_parameter(&"viewport_center_px", center)
		_cached_viewport_center = center
	if focus != _cached_camera_focus:
		_shader_mat.set_shader_parameter(&"camera_focus_map_px", focus)
		_cached_camera_focus = focus
	if not is_equal_approx(safe_zoom, _cached_zoom):
		_shader_mat.set_shader_parameter(&"zoom", safe_zoom)
		_cached_zoom = safe_zoom
	_has_pushed_projection = center.x > 0.0 and center.y > 0.0


func _invalidate_projection_cache() -> void:
	_cached_viewport_center = Vector2(-99999.0, -99999.0)
	_cached_camera_focus = Vector2(-99999.0, -99999.0)
	_cached_zoom = -1.0
	_has_pushed_projection = false


func _push_debug_coords() -> void:
	if _shader_mat == null or debug_coords == _cached_debug_coords:
		return
	_shader_mat.set_shader_parameter(&"debug_coords", debug_coords)
	_cached_debug_coords = debug_coords


func _map_local_from_canvas(canvas_px: Vector2) -> Vector2:
	var safe_zoom: float = _cached_zoom if _cached_zoom > 0.0 else 1.0
	return (canvas_px - _cached_viewport_center) / safe_zoom + _cached_camera_focus


func _log_startup_coords(tag: String) -> void:
	if not debug_startup_coords or not OS.is_debug_build():
		return
	if _shader_mat == null:
		return

	var frame: int = Engine.get_physics_frames()
	var player_pos: Vector2 = _player.position if _player != null else Vector2.ZERO
	var zoom_val: float = _cached_zoom if _cached_zoom > 0.0 else 1.0

	var map_scroll_fwd: Transform2D = Transform2D.IDENTITY
	if _map_scroll != null:
		map_scroll_fwd = _map_scroll.get_global_transform_with_canvas()

	var canvas_center: Vector2 = _cached_viewport_center
	var map_at_center: Vector2 = _map_local_from_canvas(canvas_center)
	var center_delta: Vector2 = map_at_center - player_pos
	var projection_xf: Transform2D = ViewProjection.canvas_to_map_local_transform()

	print(
		(
			"[FogOverlay:%s] frame=%d player=%s world_origin=%s world_extent=%s "
			+ "viewport_center=%s camera_focus=%s zoom=%s "
			+ "map_scroll_canvas_fwd=[x=%s y=%s o=%s] "
			+ "map_at_center=%s center_delta=%s "
			+ "projection_canvas_to_map=[x=%s y=%s o=%s] has_pushed=%s"
		)
		% [
			tag,
			frame,
			player_pos,
			_cached_world_origin,
			_cached_world_extent,
			canvas_center,
			_cached_camera_focus,
			zoom_val,
			map_scroll_fwd.x,
			map_scroll_fwd.y,
			map_scroll_fwd.origin,
			map_at_center,
			center_delta,
			projection_xf.x,
			projection_xf.y,
			projection_xf.origin,
			_has_pushed_projection,
		]
	)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		ViewProjection.invalidate_screen_center_cache()
		_cached_player_sim_position = Vector2(-99999.0, -99999.0)
		_invalidate_projection_cache()
		force_resync_scroll()
		_sync_player_map_px()
