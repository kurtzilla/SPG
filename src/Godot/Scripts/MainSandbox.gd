extends Node2D

const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const ViewFrameScript = preload("res://src/Godot/Scripts/ViewFrame.gd")
const PlayerControllerScript = preload("res://src/Godot/Scripts/PlayerController.gd")
const FogExplorationMapScript = preload("res://src/Godot/Scripts/Systems/fog-of-war/FogExplorationMap.gd")

@onready var _world_canvas: CanvasLayer = $WorldCanvas
@onready var _map_scroll: Node2D = $WorldCanvas/Tiles
@onready var _chunk_manager: Node2D = $WorldCanvas/Tiles/ChunkManager
@onready var _fog: FogExplorationMapScript = $FogExploration
## Must be the CanvasLayer with FogOverlay.gd ($FogOverlay), NOT $FogOverlay/FogRect — see FogOverlay.gd WIRING INVARIANT.
@onready var _fog_overlay: FogOverlay = $FogOverlay
@onready var _grid_overlay: GridOverlay = $GridOverlay
@onready var _settings_ui: CanvasLayer = $SettingsUi
@onready var _player: PlayerControllerScript = %Player

var _party: PartyModelGd
var _debug_grid_enabled: bool = false

var _last_tracked_x: int = 0
var _last_tracked_y: int = 0

var _snap_scroll_to_pixel: bool = false

const ZOOM_REBUILD_DELAY_SEC: float = 0.05

var _zoom_rebuild_timer: SceneTreeTimer
var _zoom_rebuild_scheduled_zoom: float = -1.0

var _cached_view_frame: ViewFrameScript
var _last_applied_scroll: Vector2 = Vector2(-999999.0, -999999.0)
var _last_applied_player_pos: Vector2 = Vector2(-999999.0, -999999.0)
var _last_applied_zoom: float = -1.0
var _last_applied_viewport_size: Vector2 = Vector2.ZERO
var _last_canvas_to_map: Transform2D = Transform2D.IDENTITY
var _canvas_to_map_initialized: bool = false
var _view_projection_dirty: bool = true
var _startup_view_frames_remaining: int = 3


func _ready() -> void:
	set_process(true)
	# After PlayerController (10) so pixel snap survives set_camera_focus (F4/A3).
	process_priority = 5
	y_sort_enabled = false
	_map_scroll.y_sort_enabled = false
	_snap_scroll_to_pixel = ProjectSettings.get_setting("rendering/2d/snap/snap_2d_transforms_to_pixel")

	if not ViewProjection.view_changed.is_connected(_on_view_changed):
		ViewProjection.view_changed.connect(_on_view_changed)
	_view_projection_dirty = true

	_read_view_settings()
	_apply_display_perf_settings()
	_apply_internal_viewport_scale()

	if not Settings.view_changed.is_connected(_on_settings_view_changed):
		Settings.view_changed.connect(_on_settings_view_changed)
	if not Settings.setting_changed.is_connected(_on_setting_changed):
		Settings.setting_changed.connect(_on_setting_changed)

	var core: Node = get_node("/root/CoreBridge")
	_party = core.CreatePartyModel()

	var player: CharacterModelGd = core.CreateCharacter("player", "Player", 0, 0)
	_party.AddCharacter(player)

	_last_tracked_x = player.X
	_last_tracked_y = player.Y
	if _player == null:
		push_error("MainSandbox: Player node missing — check Player.tscn instance in MainSandbox.tscn")
		return

	ViewProjection.register_viewport_provider(self)
	ViewProjection.try_seed_viewport_metrics(get_viewport())

	_grid_overlay.configure(_debug_grid_enabled)
	_settings_ui.setup(_party, _player)

	if not _player.grid_cell_changed.is_connected(_on_player_grid_cell_changed):
		_player.grid_cell_changed.connect(_on_player_grid_cell_changed)
	if not _player.map_position_changed.is_connected(_on_player_map_position_changed):
		_player.map_position_changed.connect(_on_player_map_position_changed)

	_player.position = ViewTransformsScript.grid_cell_center_to_map_local_px(float(player.X), float(player.Y))
	ViewProjection.register_camera(_player)

	if not _ensure_viewport_metrics_ready():
		call_deferred("_finish_ready_after_viewport")
		return
	_finish_ready_viewport_dependent()
	call_deferred("_bootstrap_after_frame")


func _read_view_settings() -> void:
	_debug_grid_enabled = Settings.get_bool("grid.debug_grid_lines")


func _on_settings_view_changed() -> void:
	_apply_display_perf_settings()
	_apply_internal_viewport_scale()
	_view_projection_dirty = true


func _on_setting_changed(path: String) -> void:
	if path == "grid.debug_grid_lines":
		_sync_grid_overlay_from_settings()


func _sync_grid_overlay_from_settings() -> void:
	var was_enabled: bool = _debug_grid_enabled
	_debug_grid_enabled = Settings.get_bool("grid.debug_grid_lines")
	if _grid_overlay != null:
		_grid_overlay.configure(_debug_grid_enabled)
	_view_projection_dirty = true
	if _debug_grid_enabled and not was_enabled:
		_apply_view_frame()


func _apply_display_perf_settings() -> void:
	var vsync_enabled: bool = Settings.get_bool("view.vsync_enabled")
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if vsync_enabled else DisplayServer.VSYNC_DISABLED
	)
	var max_fps: int = Settings.get_int("view.max_fps")
	Engine.max_fps = maxi(max_fps, 0)


func _apply_internal_viewport_scale() -> void:
	var internal_scale: float = clampf(Settings.get_float("view.internal_scale"), 0.25, 1.0)
	var base_w: int = int(ProjectSettings.get_setting("display/window/size/viewport_width", 1920))
	var base_h: int = int(ProjectSettings.get_setting("display/window/size/viewport_height", 1080))
	var vp: Viewport = get_viewport()
	if vp == null:
		return
	var target_w: int = maxi(320, int(round(float(base_w) * internal_scale)))
	var target_h: int = maxi(240, int(round(float(base_h) * internal_scale)))
	if vp.size != Vector2i(target_w, target_h):
		vp.size = Vector2i(target_w, target_h)
		ViewProjection.invalidate_viewport_metrics()


func _finish_ready_after_viewport() -> void:
	if not _ensure_viewport_metrics_ready():
		call_deferred("_finish_ready_after_viewport")
		return
	_finish_ready_viewport_dependent()
	call_deferred("_bootstrap_after_frame")


func _finish_ready_viewport_dependent() -> void:
	_apply_view_frame()
	_bootstrap_fog()
	_sync_spawn_tracking_from_player()
	if _chunk_manager != null:
		_chunk_manager.force_viewport_chunk_refresh()


func _process(delta: float) -> void:
	if _player != null and is_instance_valid(_player):
		if _should_apply_view_frame_this_frame():
			_apply_view_frame()
			if _startup_view_frames_remaining > 0:
				_startup_view_frames_remaining -= 1
		if _fog_overlay != null and _fog != null and _fog.enabled and _fog_overlay.is_configured():
			_fog_overlay.update_player_reveal(_player.position, _player.velocity)
			_fog_overlay.tick_presentation(delta)
		if _grid_overlay != null and _debug_grid_enabled:
			_grid_overlay.tick_presentation(delta)


func _should_apply_view_frame_this_frame() -> bool:
	if _startup_view_frames_remaining > 0:
		return true
	if _view_projection_dirty:
		return true

	var target_offset: Vector2 = ViewProjection.scroll_node_canvas_position()
	if _should_snap_scroll_to_pixel():
		target_offset = target_offset.round()
	var zoom: float = ViewProjection.safe_zoom()
	var viewport_size: Vector2 = ViewProjection.get_viewport_size()

	if not target_offset.is_equal_approx(_last_applied_scroll):
		return true
	if not is_equal_approx(zoom, _last_applied_zoom):
		return true
	if not viewport_size.is_equal_approx(_last_applied_viewport_size):
		return true
	if _player != null and is_instance_valid(_player):
		if not _player.position.is_equal_approx(_last_applied_player_pos):
			return true
	return false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_view_projection_dirty = true
		ViewProjection.notify_viewport_resized()
		_sync_spawn_tracking_from_player()
		if _fog_overlay != null:
			_fog_overlay.ensure_buffer_for_viewport()
		_schedule_zoom_deferred_rebuild()


func _apply_view_frame() -> void:
	if _player == null or not is_instance_valid(_player):
		return

	var zoom: float = ViewProjection.safe_zoom()
	var camera_focus: Vector2 = ViewProjection.resolve_camera_focus_map_px(_player)
	if ViewTransformsScript.is_zoom_pixel_aligned(zoom):
		camera_focus = ViewTransformsScript.snap_map_scroll_pixel_aligned(camera_focus, zoom)
	ViewProjection.set_camera_focus(camera_focus)

	var target_offset: Vector2 = ViewProjection.scroll_node_canvas_position()
	if _should_snap_scroll_to_pixel():
		target_offset = target_offset.round()
	_map_scroll.scale = Vector2(zoom, zoom)
	_world_canvas.offset = Vector2.ZERO
	if not target_offset.is_equal_approx(_map_scroll.position):
		_map_scroll.position = target_offset

	var frame: ViewFrameScript = (
		ViewFrameScript.populate_from_applied(_player, _map_scroll) as ViewFrameScript
	)

	if _grid_overlay != null and _debug_grid_enabled:
		_grid_overlay.apply_view_frame(frame)
	if _fog_overlay != null and _fog != null and _fog.enabled:
		_fog_overlay.apply_view_frame(frame)

	if OS.is_debug_build():
		_verify_projection_canvas_parity(frame)

	_last_applied_scroll = target_offset
	_last_applied_player_pos = _player.position
	_last_applied_zoom = frame.zoom
	_last_applied_viewport_size = ViewProjection.get_viewport_size()
	_view_projection_dirty = false


func _should_snap_scroll_to_pixel() -> bool:
	if not _snap_scroll_to_pixel:
		return false
	return ViewTransformsScript.is_zoom_pixel_aligned(ViewProjection.safe_zoom())


func _on_view_changed() -> void:
	_view_projection_dirty = true
	if _fog_overlay != null and _fog != null and _fog.enabled:
		_fog_overlay.ensure_buffer_for_current_zoom()
		_fog_overlay.flush_pending_on_view_changed()
	_schedule_zoom_deferred_rebuild()


func _on_player_grid_cell_changed(cell: Vector2i) -> void:
	if cell.x == _last_tracked_x and cell.y == _last_tracked_y:
		return

	var character: CharacterModelGd = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		character.MoveTo(cell.x, cell.y)

	_chunk_manager.sync_center_from_player_map_px(_player.position)
	_last_tracked_x = cell.x
	_last_tracked_y = cell.y
	if _fog != null:
		_fog.on_player_cell_changed(cell)


func _on_player_map_position_changed(map_px: Vector2) -> void:
	if _chunk_manager != null and _player != null:
		_chunk_manager.sync_center_from_player_motion(map_px, _player.velocity)
	if _fog != null:
		_fog.on_player_map_position_changed(map_px)


func _bootstrap_after_frame() -> void:
	await get_tree().process_frame
	if _player == null:
		return
	if not _ensure_viewport_metrics_ready():
		call_deferred("_bootstrap_after_frame")
		return
	_sync_spawn_tracking_from_player()
	_apply_view_frame()
	if _fog_overlay != null and not _fog_overlay.is_configured():
		_bootstrap_fog()
	if _chunk_manager != null:
		var spawn_grid: Vector2i = ViewProjection.get_camera_center_map()
		_chunk_manager.force_immediate_startup_pass(spawn_grid)


func _bootstrap_fog() -> void:
	if _fog == null or _fog_overlay == null or _player == null or not is_instance_valid(_player):
		return
	if not FogOverlay.validate_host_node(_fog_overlay):
		push_error(
			"Fog wiring broken: MainSandbox._fog_overlay must be $FogOverlay (CanvasLayer + FogOverlay.gd). "
			+ "Pointing at FogRect causes full-black fog with no setup. See FogOverlay.gd WIRING INVARIANT."
		)
		return
	_fog.setup(_player, _fog_overlay)
	if _chunk_manager != null:
		_chunk_manager.sync_center_from_player_map_px(_player.position)
	var spawn_grid: Vector2i = ViewProjection.get_camera_center_map()
	if spawn_grid == Vector2i.ZERO:
		spawn_grid = ViewProjection.map_local_px_to_grid_cell(_player.position)
	_fog.bootstrap_exploration(spawn_grid)
	_fog.on_player_cell_changed(spawn_grid)
	_fog_overlay.set_enabled_visible(_fog.enabled)
	_apply_view_frame()


func _log_perf_baseline_diagnostics() -> void:
	if not OS.is_debug_build():
		return
	var refresh_hz: float = DisplayServer.screen_get_refresh_rate(
		DisplayServer.window_get_current_screen()
	)
	print(
		"[PerfBaseline] vsync=%s max_fps=%d internal_scale=%.2f grid=%s fog=%s viewport=%s refresh=%.0fHz — toggle settings to measure idle FPS split"
		% [
			Settings.get_bool("view.vsync_enabled"),
			Settings.get_int("view.max_fps"),
			Settings.get_float("view.internal_scale"),
			Settings.get_bool("grid.debug_grid_lines"),
			Settings.get_bool("fog.enabled"),
			ViewProjection.get_viewport_size(),
			refresh_hz,
		]
	)


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
	if _chunk_manager != null:
		_chunk_manager.force_viewport_chunk_refresh()


func _ensure_viewport_metrics_ready() -> bool:
	if ViewProjection.are_viewport_metrics_ready():
		return true
	return ViewProjection.try_seed_viewport_metrics(get_viewport())


func _verify_projection_canvas_parity(frame: ViewFrameScript) -> void:
	if _map_scroll == null or frame == null:
		return
	var from_node: Transform2D = _map_scroll.get_global_transform_with_canvas().affine_inverse()
	var from_projection: Transform2D = frame.canvas_transform.affine_inverse()
	if not from_node.is_equal_approx(from_projection):
		push_warning(
			"ViewProjection canvas parity mismatch: node=%s projection=%s"
			% [from_node, from_projection]
		)
	ViewProjection.verify_fog_projection_parity(
		frame.viewport_center,
		frame.camera_focus_map_px,
		frame.zoom
	)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			ViewProjection.adjust_zoom(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			ViewProjection.adjust_zoom(-1)
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.keycode == KEY_ESCAPE):
		call_deferred("_request_quit")


func _request_quit() -> void:
	get_tree().quit()
