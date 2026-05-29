extends Node

## Autoload: zoom/settings plus map-local ↔ canvas transforms.
## map_scroll is camera focus in map-local px (not the Tiles node position).

const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")

signal view_changed

## Camera focus in map-local px.
var map_scroll: Vector2 = Vector2.ZERO
var _camera_position: Vector2 = Vector2.ZERO

var _cached_screen_center: Vector2 = Vector2.ZERO
var _screen_center_cached: bool = false
var _viewport_provider: Node = null

var _viewport_size: Vector2 = Vector2.ZERO
var _cached_visual_radius: int = -1
var _cached_metrics_zoom: float = -1.0
var _cached_metrics_buffer: int = -1

var _zoom_wheel_step: float = 0.1
var _zoom_min: float = 0.0
var _zoom_max: float = 10.0
var _zoom_has_limits: bool = false
var _map_scroll_fallback_warned: bool = false
var _camera_registered: bool = false
var _camera_source: Node2D = null

const FRAME_ZERO_FAILSAFE_MAX_FRAMES: int = 3


func register_viewport_provider(node: Node) -> void:
	_viewport_provider = node
	_update_projection()
	_ensure_map_scroll_fallback()


func _ready() -> void:
	_cache_view_settings()
	if not Settings.view_changed.is_connected(_cache_view_settings):
		Settings.view_changed.connect(_cache_view_settings)
	if not Settings.view_changed.is_connected(_on_settings_view_changed):
		Settings.view_changed.connect(_on_settings_view_changed)
	var vp: Viewport = _resolve_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_root_viewport_size_changed):
		vp.size_changed.connect(_on_root_viewport_size_changed)
	else:
		call_deferred("_connect_viewport_size_signal")
	_update_projection()
	_ensure_map_scroll_fallback()


func _connect_viewport_size_signal() -> void:
	var vp: Viewport = _resolve_viewport()
	if vp != null and not vp.size_changed.is_connected(_on_root_viewport_size_changed):
		vp.size_changed.connect(_on_root_viewport_size_changed)


func _on_root_viewport_size_changed() -> void:
	_update_projection()
	view_changed.emit()


var zoom: float:
	get:
		return Settings.zoom
	set(value):
		Settings.zoom = value


func invalidate_viewport_metrics() -> void:
	_screen_center_cached = false
	_viewport_size = Vector2.ZERO
	_cached_visual_radius = -1
	_cached_metrics_zoom = -1.0
	_cached_metrics_buffer = -1


func notify_viewport_resized() -> void:
	invalidate_viewport_metrics()
	_update_projection()
	view_changed.emit()


func _update_projection() -> void:
	var size: Vector2 = Vector2.ZERO
	var vp: Viewport = _resolve_viewport()
	if vp != null:
		var visible_rect: Rect2 = vp.get_visible_rect()
		size = visible_rect.size
		_cached_screen_center = visible_rect.get_center()
	else:
		_cached_screen_center = Vector2.ZERO
	if size.x < 1.0 or size.y < 1.0:
		size = _project_settings_viewport_size()
		if _cached_screen_center.x < 1.0 or _cached_screen_center.y < 1.0:
			_cached_screen_center = size * 0.5
	_viewport_size = size
	_screen_center_cached = true
	_cached_visual_radius = -1
	_cached_metrics_zoom = -1.0
	_cached_metrics_buffer = -1


func _project_settings_viewport_size() -> Vector2:
	return Vector2(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 1920)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 1080))
	)


func get_viewport_size() -> Vector2:
	if _viewport_size.x >= 1.0 and _viewport_size.y >= 1.0:
		return _viewport_size
	_update_projection()
	if _viewport_size.x >= 1.0 and _viewport_size.y >= 1.0:
		return _viewport_size
	return _project_settings_viewport_size()


func are_viewport_metrics_ready() -> bool:
	var center: Vector2 = get_screen_center_offset()
	var size: Vector2 = get_viewport_size()
	return center.x >= 1.0 and center.y >= 1.0 and size.x >= 1.0 and size.y >= 1.0


func try_seed_viewport_metrics(_fallback_viewport: Viewport = null) -> bool:
	_update_projection()
	return _viewport_size.x >= 1.0 and _viewport_size.y >= 1.0


func get_visual_radius(buffer_cells: int = 0) -> int:
	var vp_size: Vector2 = get_viewport_size()
	var z: float = zoom if not is_zero_approx(zoom) else 1.0
	var safe_buffer: int = maxi(buffer_cells, 0)

	if vp_size.x < 1.0 or vp_size.y < 1.0:
		push_warning("[ViewProjection] viewport metrics not ready for radius")
		return safe_buffer + 1

	if (
		_cached_visual_radius >= 0
		and is_equal_approx(z, _cached_metrics_zoom)
		and vp_size == _viewport_size
		and safe_buffer == _cached_metrics_buffer
	):
		return _cached_visual_radius

	_cached_metrics_zoom = z
	_cached_metrics_buffer = safe_buffer
	_cached_visual_radius = ViewTransformsScript.visible_grid_radius_from_viewport(
		vp_size, z, safe_buffer
	)
	if _cached_visual_radius <= 0:
		push_warning("[ViewProjection] visual_radius <= 0 (vp=%s zoom=%s)" % [vp_size, z])
		_cached_visual_radius = 1
	return _cached_visual_radius


func get_visible_tile_bounds(center_gx: int, center_gy: int, buffer_cells: int = 0) -> Rect2i:
	var radius: int = get_visual_radius(buffer_cells)
	return Rect2i(
		center_gx - radius,
		center_gy - radius,
		radius * 2 + 1,
		radius * 2 + 1
	)


func get_screen_center_offset() -> Vector2:
	if _screen_center_cached:
		return _cached_screen_center
	_update_projection()
	return _cached_screen_center


func _resolve_viewport() -> Viewport:
	if _viewport_provider != null and _viewport_provider.is_inside_tree():
		return _viewport_provider.get_viewport()
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree and main_loop.root != null:
		return main_loop.root.get_viewport()
	return null


func world_to_screen(world_pos: Vector2) -> Vector2:
	var z: float = zoom if not is_zero_approx(zoom) else 1.0
	return (world_pos - map_scroll) * z + get_screen_center_offset()


func screen_to_world(screen_pos: Vector2) -> Vector2:
	var z: float = zoom if not is_zero_approx(zoom) else 1.0
	return ((screen_pos - get_screen_center_offset()) / z) + map_scroll


func scroll_node_canvas_position() -> Vector2:
	return world_to_screen(Vector2.ZERO)


func register_camera(camera_node: Node2D) -> void:
	_camera_source = camera_node
	if _camera_source != null and is_instance_valid(_camera_source):
		set_camera_focus(_camera_source.position)


func set_camera_focus(map_px: Vector2) -> void:
	if map_px.is_equal_approx(_camera_position):
		return
	_camera_position = map_px
	map_scroll = map_px
	_camera_registered = true
	_cached_visual_radius = -1


func resolve_camera_focus_map_px(fallback_player: Node2D = null) -> Vector2:
	var player: Node2D = fallback_player
	if player == null and _camera_source != null and is_instance_valid(_camera_source):
		player = _camera_source
	if _needs_frame_zero_player_failsafe():
		var failsafe_player: Node2D = player if player != null else _find_player_in_tree()
		if failsafe_player != null and is_instance_valid(failsafe_player):
			return failsafe_player.position
	if _camera_source != null and is_instance_valid(_camera_source):
		return _camera_source.position
	if _camera_registered:
		return map_scroll
	if player != null and is_instance_valid(player):
		return player.position
	return _spawn_fallback_map_px()


func _needs_frame_zero_player_failsafe() -> bool:
	return Engine.get_process_frames() < FRAME_ZERO_FAILSAFE_MAX_FRAMES and not _camera_registered


func _find_player_in_tree() -> Node2D:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		var players: Array[Node] = main_loop.get_nodes_in_group("player")
		if not players.is_empty():
			return players[0] as Node2D
	return null


func is_camera_registered() -> bool:
	return _camera_registered


func get_camera_center_map() -> Vector2i:
	if not _camera_registered:
		return Vector2i.ZERO
	return map_local_px_to_grid_cell(_camera_position)


func resolve_map_center_from_player(player: Node2D) -> Vector2i:
	if player == null or not is_instance_valid(player):
		return Vector2i.ZERO
	return map_local_px_to_grid_cell(player.position)


func canvas_to_map(canvas_px: Vector2) -> Vector2i:
	return map_local_px_to_grid_cell(screen_to_world(canvas_px))


func map_local_px_to_grid_cell(map_px: Vector2) -> Vector2i:
	var cell_px: float = float(ViewMetricsRes.CELL_SIZE_PX)
	if cell_px <= 0.0:
		return Vector2i.ZERO
	return Vector2i(floori(map_px.x / cell_px), floori(map_px.y / cell_px))


func forward_canvas_transform() -> Transform2D:
	var z: float = zoom if not is_zero_approx(zoom) else 1.0
	var scroll_pos: Vector2 = scroll_node_canvas_position()
	return Transform2D(Vector2(z, 0.0), Vector2(0.0, z), scroll_pos)


func canvas_to_map_local_transform() -> Transform2D:
	return forward_canvas_transform().affine_inverse()


func safe_zoom(zoom_override: float = -1.0) -> float:
	var z: float = zoom_override if zoom_override > 0.0 and not is_zero_approx(zoom_override) else zoom
	return z if not is_zero_approx(z) else 1.0


func verify_fog_projection_parity(
	viewport_center_px: Vector2,
	camera_focus_map_px: Vector2,
	zoom_override: float = -1.0,
	margin_px: float = 1.0
) -> bool:
	var vp_size: Vector2 = get_viewport_size()
	if vp_size.x < 1.0 or vp_size.y < 1.0:
		return true
	var z: float = safe_zoom(zoom_override)
	var sample_points: Array[Vector2] = [
		Vector2.ZERO,
		Vector2(vp_size.x, 0.0),
		vp_size,
		Vector2(0.0, vp_size.y),
		viewport_center_px,
	]
	for fragcoord: Vector2 in sample_points:
		var from_screen: Vector2 = screen_to_world(fragcoord)
		var from_fragcoord: Vector2 = camera_focus_map_px + ((fragcoord - viewport_center_px) / z)
		if (
			not from_screen.is_equal_approx(from_fragcoord)
			and from_screen.distance_to(from_fragcoord) > margin_px
		):
			push_warning(
				"[ViewProjection] fog projection parity mismatch fragcoord=%s screen=%s frag_path=%s zoom=%s"
				% [fragcoord, from_screen, from_fragcoord, z]
			)
			return false
	return true


func pin_screen_center_for_tests(center: Vector2) -> void:
	_cached_screen_center = center
	_screen_center_cached = center.x > 0.0 and center.y > 0.0


func adjust_zoom(delta_steps: int) -> bool:
	var new_zoom: float = Settings.zoom + float(delta_steps) * _zoom_wheel_step
	if _zoom_has_limits:
		new_zoom = clampf(new_zoom, _zoom_min, _zoom_max)
	if is_equal_approx(new_zoom, Settings.zoom):
		return false
	invalidate_viewport_metrics()
	Settings.zoom = new_zoom
	view_changed.emit()
	return true


func _cache_view_settings() -> void:
	_zoom_wheel_step = Settings.get_float("view.zoom_wheel_step")
	var min_zoom: Variant = Settings.get_min("view.zoom")
	var max_zoom: Variant = Settings.get_max("view.zoom")
	_zoom_has_limits = min_zoom != null and max_zoom != null
	if _zoom_has_limits:
		_zoom_min = float(min_zoom)
		_zoom_max = float(max_zoom)


func get_settings_panel_visible() -> bool:
	return Settings.settings_panel_visible


func set_settings_panel_visible(visible: bool) -> void:
	Settings.set_settings_panel_visible(visible)


func load_settings() -> void:
	Settings.load_user_settings()


func save_settings() -> void:
	Settings.save_user_settings()


func _on_settings_view_changed() -> void:
	invalidate_viewport_metrics()
	view_changed.emit()


func _spawn_fallback_map_px() -> Vector2:
	var gx: float = float(Settings.get_int("world.spawn_safe_zone_x"))
	var gy: float = float(Settings.get_int("world.spawn_safe_zone_y"))
	return ViewTransformsScript.grid_to_map_local_px(gx, gy)


func _ensure_map_scroll_fallback() -> void:
	if map_scroll != Vector2.ZERO:
		return
	if _viewport_provider == null:
		return
	map_scroll = _spawn_fallback_map_px()
	if not _map_scroll_fallback_warned:
		_map_scroll_fallback_warned = true
		push_warning(
			"[ViewProjection] map_scroll was ZERO after provider registered; using spawn fallback %s"
			% map_scroll
		)
