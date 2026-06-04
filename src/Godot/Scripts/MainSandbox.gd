extends Node2D

const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const ViewFrameScript = preload("res://src/Godot/Scripts/ViewFrame.gd")
const PlayerControllerScript = preload("res://src/Godot/Scripts/PlayerController.gd")
const FogManagerScript = preload("res://src/Godot/Scripts/World/FogManager.gd")

@onready var _world_canvas: CanvasLayer = $WorldCanvas
@onready var _map_scroll: Node2D = $WorldCanvas/Tiles
@onready var _chunk_manager: Node2D = $WorldCanvas/Tiles/ChunkManager
@onready var _fog_manager: FogManagerScript = $WorldCanvas/Tiles/FogLayer
@onready var _grid_overlay: GridOverlay = $GridOverlay
@onready var _settings_ui: CanvasLayer = $SettingsUi
@onready var _player: PlayerControllerScript = %Player
@onready var serializer: Node = $FogDiskSerializer

@export var autosave_interval_sec: float = 300.0

var _party: PartyModelGd
var _autosave_timer: Timer
var _save_in_flight: bool = false
var _debug_grid_enabled: bool = false

var _last_tracked_x: int = 0
var _last_tracked_y: int = 0

var _snap_scroll_to_pixel: bool = false

const ZOOM_REBUILD_DELAY_SEC: float = 0.05

const ZOOM_WHEEL_DEBOUNCE_SEC: float = 0.05

var _zoom_rebuild_timer: SceneTreeTimer
var _zoom_rebuild_scheduled_zoom: float = -1.0
var _zoom_wheel_debounce_sec: float = 0.0

var _last_applied_scroll: Vector2 = Vector2(-999999.0, -999999.0)
var _last_applied_player_pos: Vector2 = Vector2(-999999.0, -999999.0)
var _last_applied_zoom: float = -1.0
var _last_applied_viewport_size: Vector2 = Vector2.ZERO
var _view_projection_dirty: bool = true
var _startup_view_frames_remaining: int = 3


func _ready() -> void:
	set_process(true)
	# After PlayerController (10): view apply runs at 15 so camera focus is current first.
	process_priority = 15
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
	if serializer == null:
		push_error("MainSandbox: FogDiskSerializer node missing — check MainSandbox.tscn")
		return

	_setup_autosave_timer()

	ViewProjection.register_viewport_provider(self)
	ViewProjection.try_seed_viewport_metrics(get_viewport())

	_grid_overlay.configure(_debug_grid_enabled)
	_settings_ui.setup(_party, _player)

	if not _player.grid_cell_changed.is_connected(_on_player_grid_step):
		_player.grid_cell_changed.connect(_on_player_grid_step)
	if not _player.map_position_changed.is_connected(_on_player_map_position_changed):
		_player.map_position_changed.connect(_on_player_map_position_changed)
	_connect_fog_manager()

	_player.position = ViewTransformsScript.grid_to_map_local_px(float(player.X), float(player.Y))
	if _fog_manager != null:
		_fog_manager.bind_player(_player)
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
	_sync_spawn_tracking_from_player()
	if _chunk_manager != null:
		_chunk_manager.force_viewport_chunk_refresh()


func _process(delta: float) -> void:
	if _zoom_wheel_debounce_sec > 0.0:
		_zoom_wheel_debounce_sec = maxf(_zoom_wheel_debounce_sec - delta, 0.0)
	if _player != null and is_instance_valid(_player):
		if _should_apply_view_frame_this_frame():
			_apply_view_frame()
			if _startup_view_frames_remaining > 0:
				_startup_view_frames_remaining -= 1
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
		_schedule_zoom_deferred_rebuild()


func _apply_view_frame() -> void:
	if _player == null or not is_instance_valid(_player):
		return

	var zoom: float = ViewProjection.safe_zoom()
	var zoom_changed: bool = not is_equal_approx(zoom, _last_applied_zoom)
	var camera_focus: Vector2 = ViewProjection.resolve_camera_focus_map_px(_player)
	if ViewTransformsScript.is_zoom_pixel_aligned(zoom) and not zoom_changed:
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
	_schedule_zoom_deferred_rebuild()


func _on_player_grid_step(new_cell: Vector2i) -> void:
	if new_cell.x == _last_tracked_x and new_cell.y == _last_tracked_y:
		return

	var character: CharacterModelGd = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		character.MoveTo(new_cell.x, new_cell.y)

	_chunk_manager.sync_center_from_player_map_px(_player.position)
	_last_tracked_x = new_cell.x
	_last_tracked_y = new_cell.y


func _on_player_map_position_changed(map_px: Vector2) -> void:
	if _chunk_manager != null and _player != null:
		_chunk_manager.sync_center_from_player_motion(map_px, _player.velocity)


func _connect_fog_manager() -> void:
	if _fog_manager == null:
		return
	if _chunk_manager != null and not _chunk_manager.chunk_finished.is_connected(_on_chunk_finished):
		_chunk_manager.chunk_finished.connect(_on_chunk_finished)


func _on_chunk_finished(chunk_coord: Vector2i) -> void:
	if _fog_manager == null:
		return
	var chunk_size: int = Settings.get_int("world.chunk_size")
	_fog_manager.call_deferred("shroud_new_chunk_region", chunk_coord, chunk_size)


func _bootstrap_after_frame() -> void:
	await get_tree().process_frame
	if _player == null:
		return
	if not _ensure_viewport_metrics_ready():
		call_deferred("_bootstrap_after_frame")
		return
	_sync_spawn_tracking_from_player()
	_apply_view_frame()
	if _chunk_manager != null:
		var spawn_grid: Vector2i = ViewProjection.get_camera_center_map()
		_chunk_manager.force_immediate_startup_pass(spawn_grid)


func _log_perf_baseline_diagnostics() -> void:
	if not OS.is_debug_build():
		return
	var refresh_hz: float = DisplayServer.screen_get_refresh_rate(
		DisplayServer.window_get_current_screen()
	)
	print(
		"[PerfBaseline] vsync=%s max_fps=%d internal_scale=%.2f grid=%s viewport=%s refresh=%.0fHz — toggle settings to measure idle FPS split"
		% [
			Settings.get_bool("view.vsync_enabled"),
			Settings.get_int("view.max_fps"),
			Settings.get_float("view.internal_scale"),
			Settings.get_bool("grid.debug_grid_lines"),
			ViewProjection.get_viewport_size(),
			refresh_hz,
		]
	)
	var max_fps: int = Settings.get_int("view.max_fps")
	if max_fps > 0 and refresh_hz > 1.0 and max_fps < int(refresh_hz):
		push_warning(
			"[PerfBaseline] view.max_fps=%d is below monitor refresh %.0fHz — raise or set 0 (uncapped)"
			% [max_fps, refresh_hz]
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


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if _try_adjust_zoom(1):
				get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if _try_adjust_zoom(-1):
				get_viewport().set_input_as_handled()
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.keycode == KEY_ESCAPE):
		call_deferred("_request_quit")


func _try_adjust_zoom(delta_steps: int) -> bool:
	if _zoom_wheel_debounce_sec > 0.0:
		return false
	if not ViewProjection.adjust_zoom(delta_steps):
		return false
	_zoom_wheel_debounce_sec = ZOOM_WHEEL_DEBOUNCE_SEC
	return true


func _request_quit() -> void:
	get_tree().quit()


func _setup_autosave_timer() -> void:
	_autosave_timer = Timer.new()
	_autosave_timer.one_shot = false
	_autosave_timer.wait_time = autosave_interval_sec
	_autosave_timer.autostart = true
	_autosave_timer.timeout.connect(_on_autosave_timer_timeout)
	add_child(_autosave_timer)


func _on_player_clicked_save_game() -> void:
	_request_explicit_save("manual")


func _on_autosave_timer_timeout() -> void:
	_request_explicit_save("autosave")


func _collect_save_snapshot(save_kind: String) -> Dictionary:
	var player_map_px: Array = []
	if _player != null and is_instance_valid(_player):
		player_map_px = [_player.position.x, _player.position.y]

	var chunk_layer_count: int = 0
	if _chunk_manager != null:
		chunk_layer_count = _chunk_manager.get_child_count()

	var placeholder_nodes: Array[String] = []
	for child in get_children():
		placeholder_nodes.append(child.name)

	return {
		"schema_version": 1,
		"save_kind": save_kind,
		"saved_at_unix": Time.get_unix_time_from_system(),
		"saved_at_msec": Time.get_ticks_msec(),
		"player_grid": {"x": _last_tracked_x, "y": _last_tracked_y},
		"player_map_px": player_map_px,
		"view_zoom": ViewProjection.zoom,
		"viewport_size": [ViewProjection.get_viewport_size().x, ViewProjection.get_viewport_size().y],
		"chunk_layer_count": chunk_layer_count,
		"placeholder_nodes": placeholder_nodes,
	}


func _request_explicit_save(save_kind: String) -> void:
	if serializer == null:
		push_error("MainSandbox: FogDiskSerializer node missing")
		return
	if _save_in_flight:
		return
	var state_snapshot: Dictionary = _collect_save_snapshot(save_kind)
	var payload_string: String = JSON.stringify(state_snapshot)
	_run_explicit_save_async(payload_string)


func _run_explicit_save_async(payload_string: String) -> void:
	_save_in_flight = true
	# Maps natively to the explicit Variant[] parameter layout on the C# side
	var ok: bool = await serializer.SaveStateExplicitAsync([payload_string])
	_save_in_flight = false
	if OS.is_debug_build():
		print("[Save] explicit save ok: ", ok)
