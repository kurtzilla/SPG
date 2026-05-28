extends Node

## Autoload facade: zoom/settings plus centered map-local ↔ canvas transforms.
## Single source of truth for active viewport pixel size and visible tile metrics.
## map_scroll is the camera focus in map-local px (not the WorldCanvas/Tiles node position).
## Note: world_to_screen / screen_to_world use map-local px, not Core world meters.

const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")

## TEMP DEBUG: hard fallback when radius math yields <= 0.
const VISUAL_RADIUS_HARD_FALLBACK: int = 25
## TEMP DEBUG — remove after stall is found.
const DEBUG_FALLBACK_VIEWPORT_SIZE := Vector2(1920.0, 1080.0)
const DEBUG_FALLBACK_SCREEN_CENTER := Vector2(960.0, 540.0)

signal view_changed
signal projection_changed

## Camera focus in map-local px. When zero, world origin is at screen center.
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
var _debug_center_fallback_warned: bool = false
var _debug_viewport_fallback_warned: bool = false
var _debug_map_scroll_fallback_warned: bool = false
var _camera_registered: bool = false
var _camera_source: Node2D = null
var _last_emitted_map_px: Vector2 = Vector2(INF, INF)

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
	_debug_force_initial_projection()


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


func invalidate_screen_center_cache() -> void:
	_screen_center_cached = false
	_cached_screen_center = Vector2.ZERO


func invalidate_viewport_metrics() -> void:
	invalidate_screen_center_cache()
	_viewport_size = Vector2.ZERO
	_cached_visual_radius = -1
	_cached_metrics_zoom = -1.0
	_cached_metrics_buffer = -1


## Call when the window/viewport size changes (e.g. NOTIFICATION_WM_SIZE_CHANGED).
func notify_viewport_resized() -> void:
	invalidate_viewport_metrics()
	_update_projection()
	view_changed.emit()


func _update_projection() -> void:
	var size: Vector2 = Vector2.ZERO
	var vp: Viewport = _resolve_viewport()
	if vp != null:
		size = vp.get_visible_rect().size
	if size.x < 1.0 or size.y < 1.0:
		size = _project_settings_viewport_size()
	_viewport_size = size
	_cached_screen_center = size * 0.5
	_screen_center_cached = true
	_cached_visual_radius = -1
	_cached_metrics_zoom = -1.0
	_cached_metrics_buffer = -1

	var cell_size_px: int = ViewMetricsRes.CELL_SIZE_PX
	print(
		"[ViewProjection] _update_projection: viewport_size=%s cell_size_px=%d"
		% [_viewport_size, cell_size_px]
	)
	if cell_size_px <= 0:
		push_warning(
			"[ViewProjection] cell_size_px <= 0 (%d); radius math will fail until Settings scale is applied"
			% cell_size_px
		)


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
	if not _debug_viewport_fallback_warned:
		_debug_viewport_fallback_warned = true
		push_warning(
			"[ViewProjection:DEBUG] get_viewport_size using hard fallback %s"
			% DEBUG_FALLBACK_VIEWPORT_SIZE
		)
	return DEBUG_FALLBACK_VIEWPORT_SIZE


func are_viewport_metrics_ready() -> bool:
	var center: Vector2 = get_screen_center_offset()
	var size: Vector2 = get_viewport_size()
	return center.x >= 1.0 and center.y >= 1.0 and size.x >= 1.0 and size.y >= 1.0


## Pin viewport size/center when the visible rect is not yet valid at startup.
func try_seed_viewport_metrics(_fallback_viewport: Viewport = null) -> bool:
	_update_projection()
	return _viewport_size.x >= 1.0 and _viewport_size.y >= 1.0


## Grid-cell radius visible from the viewport center, including buffer_cells padding.
func get_visual_radius(buffer_cells: int = 0) -> int:
	var vp_size: Vector2 = get_viewport_size()
	var z: float = zoom if not is_zero_approx(zoom) else 1.0
	var safe_buffer: int = maxi(buffer_cells, 0)

	if vp_size.x < 1.0 or vp_size.y < 1.0:
		return VISUAL_RADIUS_HARD_FALLBACK

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
		var cell_size_px: int = ViewMetricsRes.CELL_SIZE_PX
		push_warning(
			"[ViewProjection] visual_radius <= 0; using hard fallback %d (vp=%s zoom=%s cell_px=%d)"
			% [VISUAL_RADIUS_HARD_FALLBACK, vp_size, z, cell_size_px]
		)
		_cached_visual_radius = VISUAL_RADIUS_HARD_FALLBACK
	return _cached_visual_radius


func get_visible_tile_bounds(center_gx: int, center_gy: int, buffer_cells: int = 0) -> Rect2i:
	var radius: int = get_visual_radius(buffer_cells)
	return Rect2i(
		center_gx - radius,
		center_gy - radius,
		radius * 2 + 1,
		radius * 2 + 1
	)


func get_view_dimensions() -> Vector2:
	var size: Vector2 = get_viewport_size()
	if size.x >= 1.0 and size.y >= 1.0:
		return size
	return _project_settings_viewport_size()


func get_screen_center_offset() -> Vector2:
	var center: Vector2
	if _screen_center_cached:
		center = _cached_screen_center
	else:
		_update_projection()
		center = _cached_screen_center
	if center.x >= 1.0 and center.y >= 1.0:
		return center
	if not _debug_center_fallback_warned:
		_debug_center_fallback_warned = true
		push_warning(
			"[ViewProjection:DEBUG] get_screen_center_offset using hard fallback %s (was %s)"
			% [DEBUG_FALLBACK_SCREEN_CENTER, center]
		)
	return DEBUG_FALLBACK_SCREEN_CENTER


func _resolve_viewport() -> Viewport:
	if _viewport_provider != null and _viewport_provider.is_inside_tree():
		return _viewport_provider.get_viewport()
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree and main_loop.root != null:
		return main_loop.root.get_viewport()
	return null


func world_to_screen(world_pos: Vector2) -> Vector2:
	## Map-local px -> canvas px (world_pos is map-local, not Core meters).
	var z: float = zoom if not is_zero_approx(zoom) else 1.0
	return (world_pos - map_scroll) * z + get_screen_center_offset()


func screen_to_world(screen_pos: Vector2) -> Vector2:
	## Canvas px -> map-local px.
	var z: float = zoom if not is_zero_approx(zoom) else 1.0
	return ((screen_pos - get_screen_center_offset()) / z) + map_scroll


func scroll_node_canvas_position() -> Vector2:
	return world_to_screen(Vector2.ZERO)


## Binds the live camera/focus node (player or Camera2D) and performs an immediate sync.
func register_camera(camera_node: Node2D) -> void:
	_camera_source = camera_node
	if _camera_source != null and is_instance_valid(_camera_source):
		update_camera_position(_camera_source.position, true)


## Updates map-local camera focus; emits projection_changed / view_changed when focus moves.
func update_camera_position(map_px: Vector2, force_emit: bool = false) -> void:
	if not force_emit and map_px.is_equal_approx(_camera_position):
		return
	_camera_position = map_px
	map_scroll = map_px
	_camera_registered = true
	_last_emitted_map_px = map_px
	_cached_visual_radius = -1
	projection_changed.emit()
	view_changed.emit()


## Map-local px camera focus; registered source and player failsafe on early frames.
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
	return _debug_fallback_spawn_map_px()


func _needs_frame_zero_player_failsafe() -> bool:
	return Engine.get_process_frames() < FRAME_ZERO_FAILSAFE_MAX_FRAMES and not _camera_registered


func _find_player_in_tree() -> Node2D:
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree:
		var players: Array[Node] = main_loop.get_nodes_in_group("player")
		if not players.is_empty():
			return players[0] as Node2D
	return null


func resolve_camera_center_grid(fallback_player: Node2D = null) -> Vector2i:
	var px: Vector2 = resolve_camera_focus_map_px(fallback_player)
	return map_local_px_to_grid_cell(px)


func is_camera_registered() -> bool:
	return _camera_registered


## Records authoritative map-local camera focus (legacy path; prefer update_camera_position).
func register_camera_focus(map_px: Vector2) -> void:
	update_camera_position(map_px, true)


## Grid cell under the registered camera focus; Vector2i.ZERO when camera is not registered yet.
func get_camera_center_map() -> Vector2i:
	if not _camera_registered:
		return Vector2i.ZERO
	return map_local_px_to_grid_cell(_camera_position)


## Map-local player position -> grid cell (never uses global_position).
func resolve_map_center_from_player(player: Node2D) -> Vector2i:
	if player == null or not is_instance_valid(player):
		return Vector2i.ZERO
	return map_local_px_to_grid_cell(player.position)


## Canvas px -> grid cell (via map-local px). For screen/canvas inputs only.
func canvas_to_map(canvas_px: Vector2) -> Vector2i:
	return map_local_px_to_grid_cell(screen_to_world(canvas_px))


func map_local_px_to_grid_cell(map_px: Vector2) -> Vector2i:
	var cell_px: float = float(ViewMetricsRes.CELL_SIZE_PX)
	if cell_px <= 0.0:
		return Vector2i.ZERO
	return Vector2i(floori(map_px.x / cell_px), floori(map_px.y / cell_px))


## Map-local px -> canvas px (scale then translate scroll origin).
func forward_canvas_transform() -> Transform2D:
	var z: float = zoom if not is_zero_approx(zoom) else 1.0
	var scroll_pos: Vector2 = scroll_node_canvas_position()
	return Transform2D(Vector2(z, 0.0), Vector2(0.0, z), scroll_pos)


## Canvas px -> map-local px; matches FogOverlay camera uniform inverse.
func canvas_to_map_local_transform() -> Transform2D:
	return forward_canvas_transform().affine_inverse()


## Headless/tests: pin screen center when no viewport provider exists.
func pin_screen_center_for_tests(center: Vector2) -> void:
	_cached_screen_center = center
	_screen_center_cached = center.x > 0.0 and center.y > 0.0


func adjust_zoom(delta_steps: int) -> bool:
	var new_zoom: float = Settings.zoom + float(delta_steps) * _zoom_wheel_step
	if _zoom_has_limits:
		new_zoom = clampf(new_zoom, _zoom_min, _zoom_max)
	if is_equal_approx(new_zoom, Settings.zoom):
		return false
	Settings.zoom = new_zoom
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


func _debug_fallback_spawn_map_px() -> Vector2:
	var gx: float = float(Settings.get_int("world.spawn_safe_zone_x"))
	var gy: float = float(Settings.get_int("world.spawn_safe_zone_y"))
	return ViewTransformsScript.grid_to_map_local_px(gx, gy)


func _ensure_map_scroll_fallback() -> void:
	if map_scroll != Vector2.ZERO:
		return
	if _viewport_provider == null:
		return
	var fallback: Vector2 = _debug_fallback_spawn_map_px()
	map_scroll = fallback
	if not _debug_map_scroll_fallback_warned:
		_debug_map_scroll_fallback_warned = true
		push_warning(
			"[ViewProjection:DEBUG] map_scroll was ZERO after provider registered; using spawn fallback %s"
			% fallback
		)


func _debug_force_initial_projection() -> void:
	_update_projection()
	if _viewport_size.x < 1.0 or _viewport_size.y < 1.0:
		_viewport_size = _project_settings_viewport_size()
		if _viewport_size.x < 1.0 or _viewport_size.y < 1.0:
			_viewport_size = DEBUG_FALLBACK_VIEWPORT_SIZE
		_cached_visual_radius = -1
	if _cached_screen_center.x < 1.0 or _cached_screen_center.y < 1.0:
		_cached_screen_center = _viewport_size * 0.5
		if _cached_screen_center.x < 1.0 or _cached_screen_center.y < 1.0:
			_cached_screen_center = DEBUG_FALLBACK_SCREEN_CENTER
		_screen_center_cached = true
	_ensure_map_scroll_fallback()
	print(
		"[ViewProjection:DEBUG] forced init vp=%s center=%s map_scroll=%s zoom=%s"
		% [_viewport_size, get_screen_center_offset(), map_scroll, zoom]
	)
