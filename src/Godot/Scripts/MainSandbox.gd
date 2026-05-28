extends Node2D

const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const PlayerControllerScript = preload("res://src/Godot/Scripts/PlayerController.gd")
const FogExplorationMapScript = preload("res://src/Godot/Scripts/Systems/fog-of-war/FogExplorationMap.gd")
const FogOverlayScript = preload("res://src/Godot/Scripts/Systems/fog-of-war/FogOverlay.gd")

@onready var _world_canvas: CanvasLayer = $WorldCanvas
@onready var _map_scroll: Node2D = $WorldCanvas/Tiles
@onready var _chunk_manager: Node2D = $WorldCanvas/Tiles/ChunkManager
@onready var _fog: FogExplorationMapScript = $FogExploration
@onready var _fog_overlay: FogOverlayScript = $WorldCanvas/Tiles/FogOverlay
@onready var _grid_overlay: ColorRect = $GridOverlay/GridRect
@onready var _settings_ui: CanvasLayer = $SettingsUi
@onready var _player: PlayerControllerScript = %Player

var _party
var _viewport_center: Vector2 = Vector2.ZERO

var _last_tracked_x: int = 0
var _last_tracked_y: int = 0
var _last_map_canvas_xf: Transform2D = Transform2D.IDENTITY
var _last_overlay_zoom: float = -1.0

var _snap_scroll_to_pixel: bool = false
var _cached_visual_radius: int = 0
var _cached_radius_zoom: float = -1.0
var _cached_radius_vp_size: Vector2 = Vector2.ZERO

const ZOOM_REBUILD_DELAY_SEC: float = 0.05

var _zoom_rebuild_timer: SceneTreeTimer
var _zoom_rebuild_scheduled_zoom: float = -1.0


func _ready() -> void:
	y_sort_enabled = false
	_map_scroll.y_sort_enabled = false
	_snap_scroll_to_pixel = ProjectSettings.get_setting("rendering/2d/snap/snap_2d_transforms_to_pixel")
	_mount_fog_overlay_to_screen_space()

	if not ViewProjection.view_changed.is_connected(_on_view_changed):
		ViewProjection.view_changed.connect(_on_view_changed)

	var core = get_node("/root/CoreBridge")
	_party = core.CreatePartyModel()

	var player = core.CreateCharacter("player", "Player", 0, 0)
	_party.AddCharacter(player)

	_last_tracked_x = player.X
	_last_tracked_y = player.Y
	if _player == null:
		push_error("MainSandbox: Player node missing — check Player.tscn instance in MainSandbox.tscn")
		return

	ViewProjection.register_viewport_provider(self)
	_refresh_viewport_metrics()

	_grid_overlay.configure(Settings.get_bool("grid.debug_grid_lines"))
	_grid_overlay.set_map_scroll(_map_scroll)

	_settings_ui.setup(_party, _map_scroll, _player)
	if not _settings_ui.settings_changed.is_connected(_on_settings_changed):
		_settings_ui.settings_changed.connect(_on_settings_changed)

	if not _player.grid_cell_changed.is_connected(_on_player_grid_cell_changed):
		_player.grid_cell_changed.connect(_on_player_grid_cell_changed)

	_apply_view_zoom()
	_player.position = ViewTransformsScript.grid_to_map_local_px(float(player.X), float(player.Y))
	if not _ensure_viewport_metrics_ready():
		call_deferred("_finish_ready_after_viewport")
		return
	_finish_ready_viewport_dependent()
	call_deferred("_bootstrap_after_frame")


func _finish_ready_after_viewport() -> void:
	if not _ensure_viewport_metrics_ready():
		call_deferred("_finish_ready_after_viewport")
		return
	_finish_ready_viewport_dependent()
	call_deferred("_bootstrap_after_frame")


func _finish_ready_viewport_dependent() -> void:
	_apply_map_scroll_for_player()
	_setup_fog()
	_sync_spawn_tracking_from_player()
	_sync_view_scroll_and_overlays(true)
	_grid_overlay.sync_uniforms()


func _physics_process(_delta: float) -> void:
	if _party == null or _party.GetSelectedCharacter() == null:
		return
	if _player != null:
		_chunk_manager.sync_center_from_player_map_px(_player.position)
	_sync_view_scroll_and_overlays(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		ViewContext.invalidate_cache()
		ViewProjection.invalidate_screen_center_cache()
		_refresh_viewport_metrics()
		_reposition_all()
		_run_deferred_view_rebuild()


func _apply_view_zoom() -> void:
	var z: float = ViewProjection.zoom
	_map_scroll.scale = Vector2(z, z)


## Pixel snap on scroll only when zoom is integral; fractional zoom (e.g. 0.5) causes tile seams.
func _should_snap_scroll_to_pixel() -> bool:
	if not _snap_scroll_to_pixel:
		return false
	var z: float = ViewProjection.zoom
	return absf(z - roundf(z)) < 0.001


func _on_view_changed() -> void:
	_apply_view_zoom()
	_grid_overlay.on_view_changed()
	_sync_view_scroll_and_overlays(true)
	_schedule_zoom_deferred_rebuild()


func _on_player_grid_cell_changed(cell: Vector2i) -> void:
	if cell.x == _last_tracked_x and cell.y == _last_tracked_y:
		return

	var character = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		character.MoveTo(cell.x, cell.y)

	_chunk_manager.sync_center_from_player_map_px(_player.position)
	_last_tracked_x = cell.x
	_last_tracked_y = cell.y
	if _fog != null:
		_fog.on_player_cell_changed(cell)


func _bootstrap_after_frame() -> void:
	await get_tree().process_frame
	if _player == null:
		return
	if not _ensure_viewport_metrics_ready():
		call_deferred("_bootstrap_after_frame")
		return
	_reposition_all()


func _on_settings_changed() -> void:
	pass


func _setup_fog() -> void:
	if _fog == null or _fog_overlay == null or _player == null:
		return
	_fog.setup(_player, _fog_overlay)
	_chunk_manager.sync_center_from_player_map_px(_player.position)
	var spawn_grid: Vector2i = _chunk_manager.world_px_to_grid_tile(_player.position)
	_fog.bootstrap_exploration(spawn_grid)
	_fog_overlay.set_enabled_visible(_fog.enabled)
	_chunk_manager.force_immediate_startup_pass(spawn_grid)


func _mount_fog_overlay_to_screen_space() -> void:
	if _fog_overlay == null:
		return
	var parent: Node = _fog_overlay.get_parent()
	if parent == self:
		return
	if parent != null:
		parent.remove_child(_fog_overlay)
	add_child(_fog_overlay)


func _sync_spawn_tracking_from_player() -> void:
	if _player == null:
		return
	var spawn_map_px: Vector2 = _player.position
	_chunk_manager.sync_center_from_player_map_px(spawn_map_px)
	var spawn_grid: Vector2i = _chunk_manager.world_px_to_grid_tile(spawn_map_px)
	_last_tracked_x = spawn_grid.x
	_last_tracked_y = spawn_grid.y


func _schedule_zoom_deferred_rebuild() -> void:
	_zoom_rebuild_scheduled_zoom = ViewProjection.zoom
	var rebuild_cb := Callable(self, "_on_zoom_deferred_rebuild")
	if _zoom_rebuild_timer != null and is_instance_valid(_zoom_rebuild_timer):
		if _zoom_rebuild_timer.timeout.is_connected(rebuild_cb):
			_zoom_rebuild_timer.timeout.disconnect(rebuild_cb)
	_zoom_rebuild_timer = get_tree().create_timer(ZOOM_REBUILD_DELAY_SEC)
	_zoom_rebuild_timer.timeout.connect(rebuild_cb, CONNECT_ONE_SHOT)


func _on_zoom_deferred_rebuild() -> void:
	if not is_equal_approx(ViewProjection.zoom, _zoom_rebuild_scheduled_zoom):
		return
	_run_deferred_view_rebuild()


func _run_deferred_view_rebuild() -> void:
	if _chunk_manager != null:
		_chunk_manager.force_viewport_chunk_refresh()
	_refresh_overlays()


## Keeps map scroll and overlay transforms in sync without fog orchestration.
func _sync_view_scroll_and_overlays(force: bool = false) -> void:
	if _player == null:
		return

	var prev_canvas_xf: Transform2D = _last_map_canvas_xf
	var prev_zoom: float = _last_overlay_zoom

	ViewProjection.map_scroll = _player.position
	_apply_view_zoom()
	var target_offset: Vector2 = ViewProjection.scroll_node_canvas_position()
	if _should_snap_scroll_to_pixel():
		target_offset = target_offset.round()
	_world_canvas.offset = Vector2.ZERO
	if not target_offset.is_equal_approx(_map_scroll.position):
		_map_scroll.position = target_offset

	var canvas_xf: Transform2D = ViewProjection.forward_canvas_transform()
	var zoom: float = ViewProjection.zoom
	var scroll_changed: bool = force or not canvas_xf.is_equal_approx(prev_canvas_xf)
	var zoom_changed: bool = force or not is_equal_approx(zoom, prev_zoom)

	if scroll_changed or zoom_changed:
		_grid_overlay.sync_canvas_transform(_map_scroll)
		_refresh_overlays()
		if scroll_changed or zoom_changed:
			_sync_fog_view_transform()
		if scroll_changed:
			_verify_projection_canvas_parity()

	_last_map_canvas_xf = canvas_xf
	_last_overlay_zoom = zoom


func _viewport_grid_center() -> Vector2i:
	var center_grid: Vector2 = ViewTransformsScript.map_local_px_to_grid(ViewProjection.map_scroll)
	return Vector2i(floori(center_grid.x), floori(center_grid.y))


func _refresh_overlays() -> void:
	var center: Vector2i = _viewport_grid_center()
	_grid_overlay.update_region(center.x, center.y, _visual_spawn_radius())


func _sync_fog_view_transform() -> void:
	if _fog_overlay == null or _player == null or not _fog_overlay.has_method("sync_view_transform"):
		return
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return
	var player_cell: Vector2i = _chunk_manager.world_px_to_grid_tile(_player.position)
	_fog_overlay.sync_view_transform(
		viewport.get_visible_rect().size,
		ViewProjection.zoom,
		player_cell,
		ViewProjection.map_scroll
	)


func _refresh_viewport_metrics() -> void:
	_viewport_center = ViewProjection.get_screen_center_offset()


## Returns false when visible rect is not ready (zero size); scroll must not run until true.
func _ensure_viewport_metrics_ready() -> bool:
	var viewport: Viewport = get_viewport()
	if viewport == null:
		return false
	var vp_size: Vector2 = viewport.get_visible_rect().size
	if vp_size.x < 1.0 or vp_size.y < 1.0:
		return false
	_refresh_viewport_metrics()
	if _viewport_center.x < 1.0 or _viewport_center.y < 1.0:
		return false
	return true


func _apply_map_scroll_for_player() -> void:
	_sync_view_scroll_and_overlays(false)


func _verify_projection_canvas_parity() -> void:
	if not OS.is_debug_build() or _map_scroll == null:
		return
	var from_node: Transform2D = _map_scroll.get_global_transform_with_canvas().affine_inverse()
	var from_projection: Transform2D = ViewProjection.canvas_to_map_local_transform()
	if not from_node.is_equal_approx(from_projection):
		push_warning(
			"ViewProjection canvas_to_map parity mismatch: node=%s projection=%s"
			% [from_node, from_projection]
		)


func _recompute_visual_radius_cache() -> void:
	var zoom: float = ViewProjection.zoom
	var vp_size: Vector2 = Vector2.ZERO
	var viewport: Viewport = get_viewport()
	if viewport != null:
		vp_size = viewport.get_visible_rect().size
	_cached_radius_zoom = zoom
	_cached_radius_vp_size = vp_size
	var cell_px: float = float(ViewMetricsRes.CELL_SIZE_PX) * maxf(zoom, 0.0001)
	var buffer_cells: int = Settings.get_int("grid.visual_radius_buffer")
	if cell_px <= 0.0:
		_cached_visual_radius = buffer_cells
		return
	var half_x: int = int(ceil(vp_size.x * 0.5 / cell_px)) + buffer_cells
	var half_y: int = int(ceil(vp_size.y * 0.5 / cell_px)) + buffer_cells
	_cached_visual_radius = maxi(half_x, half_y)


func _visual_spawn_radius() -> int:
	var zoom: float = ViewProjection.zoom
	var vp_size: Vector2 = Vector2.ZERO
	var viewport: Viewport = get_viewport()
	if viewport != null:
		vp_size = viewport.get_visible_rect().size
	if not is_equal_approx(zoom, _cached_radius_zoom) or vp_size != _cached_radius_vp_size:
		_cached_radius_zoom = zoom
		_cached_radius_vp_size = vp_size
		var cell_px: float = float(ViewMetricsRes.CELL_SIZE_PX) * maxf(zoom, 0.0001)
		var buffer_cells: int = Settings.get_int("grid.visual_radius_buffer")
		if cell_px <= 0.0:
			_cached_visual_radius = buffer_cells
		else:
			var half_x: int = int(ceil(vp_size.x * 0.5 / cell_px)) + buffer_cells
			var half_y: int = int(ceil(vp_size.y * 0.5 / cell_px)) + buffer_cells
			_cached_visual_radius = maxi(half_x, half_y)
	return _cached_visual_radius


func _reposition_all() -> void:
	_sync_spawn_tracking_from_player()
	_sync_view_scroll_and_overlays(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			ViewProjection.adjust_zoom(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			ViewProjection.adjust_zoom(-1)
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.keycode == KEY_ESCAPE):
		get_tree().quit()
