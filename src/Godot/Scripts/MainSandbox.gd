extends Node2D

const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const PlayerControllerScript = preload("res://src/Godot/Scripts/PlayerController.gd")
const FogExplorationMapScript = preload("res://src/Godot/Scripts/Systems/fog-of-war/FogExplorationMap.gd")

@onready var _world_canvas: CanvasLayer = $WorldCanvas
@onready var _map_scroll: Node2D = $WorldCanvas/Tiles
@onready var _chunk_manager: Node2D = $WorldCanvas/Tiles/ChunkManager
@onready var _fog: FogExplorationMapScript = $FogExploration
@onready var _fog_overlay: FogOverlay = $FogOverlay
@onready var _grid_overlay: GridOverlay = $GridOverlay/GridRect
@onready var _settings_ui: CanvasLayer = $SettingsUi
@onready var _player: PlayerControllerScript = %Player

var _party: PartyModelGd
var _debug_grid_enabled: bool = false
var _visual_radius_buffer: int = 2

var _last_tracked_x: int = 0
var _last_tracked_y: int = 0
var _last_map_canvas_xf: Transform2D = Transform2D.IDENTITY
var _last_overlay_zoom: float = -1.0

var _snap_scroll_to_pixel: bool = false

const ZOOM_REBUILD_DELAY_SEC: float = 0.05

var _zoom_rebuild_timer: SceneTreeTimer
var _zoom_rebuild_scheduled_zoom: float = -1.0

var _view_dirty: bool = false
var _view_force_sync: bool = false
var _debug_flush_log_remaining: int = 3
var _debug_process_ticks: int = 0
var _last_fog_parity_zoom: float = -1.0
var _fog_parity_checked_once: bool = false


func _ready() -> void:
	if not ViewProjection.projection_changed.is_connected(_on_projection_changed):
		ViewProjection.projection_changed.connect(_on_projection_changed)
	_view_dirty = true
	_view_force_sync = true
	_flush_view_if_dirty()

	set_process(true)
	process_priority = 15
	y_sort_enabled = false
	_map_scroll.y_sort_enabled = false
	_snap_scroll_to_pixel = ProjectSettings.get_setting("rendering/2d/snap/snap_2d_transforms_to_pixel")
	if not ViewProjection.view_changed.is_connected(_on_view_changed):
		ViewProjection.view_changed.connect(_on_view_changed)

	_read_view_settings()

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
	_grid_overlay.set_map_scroll(_map_scroll)

	_settings_ui.setup(_party, _player)

	if not _player.grid_cell_changed.is_connected(_on_player_grid_cell_changed):
		_player.grid_cell_changed.connect(_on_player_grid_cell_changed)
	if not _player.map_position_changed.is_connected(_on_player_map_position_changed):
		_player.map_position_changed.connect(_on_player_map_position_changed)

	_apply_view_zoom()
	_player.position = ViewTransformsScript.grid_to_map_local_px(float(player.X), float(player.Y))
	ViewProjection.register_camera(_player)
	_force_initial_view_layout()
	if not _ensure_viewport_metrics_ready():
		_debug_log_view_metrics("_ready_deferred")
		call_deferred("_finish_ready_after_viewport")
		return
	_finish_ready_viewport_dependent()
	_debug_log_view_metrics("_ready")
	_debug_force_frame1_render()
	call_deferred("_bootstrap_after_frame")


func _read_view_settings() -> void:
	_debug_grid_enabled = Settings.get_bool("grid.debug_grid_lines")
	_visual_radius_buffer = maxi(int(Settings.get_float("grid.visual_radius_buffer")), 0)


func _finish_ready_after_viewport() -> void:
	if not _ensure_viewport_metrics_ready():
		call_deferred("_finish_ready_after_viewport")
		return
	_force_initial_view_layout()
	_finish_ready_viewport_dependent()
	_debug_force_frame1_render()
	call_deferred("_bootstrap_after_frame")


func _finish_ready_viewport_dependent() -> void:
	_sync_view_scroll_and_overlays(true)
	_setup_fog()
	_sync_spawn_tracking_from_player()
	_force_initial_view_layout()
	_debug_log_view_metrics("finish_ready")
	_debug_force_frame1_render()


func _process(_delta: float) -> void:
	if _player != null and is_instance_valid(_player):
		_sync_view_scroll_and_overlays(false)
		_sync_fog_view_transform()

	if _view_dirty or _view_force_sync:
		_flush_view_if_dirty()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		ViewContext.invalidate_cache()
		ViewProjection.notify_viewport_resized()
		_sync_spawn_tracking_from_player()
		_mark_view_dirty(true)
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
	_mark_view_dirty(true)
	_schedule_zoom_deferred_rebuild()


func _on_projection_changed() -> void:
	_mark_view_dirty(false)


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
	if _chunk_manager != null:
		_chunk_manager.sync_center_from_player_map_px(map_px)


func _bootstrap_after_frame() -> void:
	await get_tree().process_frame
	if _player == null:
		return
	if not _ensure_viewport_metrics_ready():
		call_deferred("_bootstrap_after_frame")
		return
	_reposition_all()
	_bootstrap_fog_exploration()


func _setup_fog() -> void:
	if _fog == null or _fog_overlay == null or _player == null or not is_instance_valid(_player):
		print("[MainSandbox:fog] _setup_fog skipped: fog=%s overlay=%s player=%s" % [_fog, _fog_overlay, _player])
		return
	_fog.setup(_player, _fog_overlay)
	if _chunk_manager != null:
		_chunk_manager.sync_center_from_player_map_px(_player.position)
	var spawn_grid: Vector2i = _resolve_authoritative_map_center()
	_fog.bootstrap_exploration(spawn_grid)
	_fog.on_player_cell_changed(spawn_grid)
	_fog_overlay.set_enabled_visible(_fog.enabled)
	_sync_fog_view_transform()


func _bootstrap_fog_exploration() -> void:
	if _fog == null or _fog_overlay == null or _player == null or not is_instance_valid(_player):
		return
	_sync_view_scroll_and_overlays(true)
	if _chunk_manager != null:
		_chunk_manager.sync_center_from_player_map_px(_player.position)
	var spawn_grid: Vector2i = _resolve_authoritative_map_center()
	if not _fog_overlay.is_configured():
		print(
			"[MainSandbox:fog] spawn map_px=%s spawn_grid=%s fog_enabled=%s map_scroll=%s registered=%s"
			% [
				_player.position,
				spawn_grid,
				_fog.enabled,
				ViewProjection.map_scroll,
				ViewProjection.is_camera_registered()
			]
		)
		_fog.bootstrap_exploration(spawn_grid)
		_fog.on_player_cell_changed(spawn_grid)
		print(
			"[MainSandbox:fog] bootstrap_exploration called; viewport_ready=%s"
			% ViewProjection.are_viewport_metrics_ready()
		)
	_fog_overlay.set_enabled_visible(_fog.enabled)
	_sync_fog_view_transform()
	call_deferred("_startup_chunk_pass", spawn_grid)


func _startup_chunk_pass(center_grid_tile: Vector2i) -> void:
	if _chunk_manager != null:
		_chunk_manager.force_immediate_startup_pass(center_grid_tile)


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


## Keeps map scroll and overlay transforms in sync without fog orchestration.
func _sync_view_scroll_and_overlays(force: bool = false) -> void:
	if _player == null:
		return

	var prev_canvas_xf: Transform2D = _last_map_canvas_xf
	var prev_zoom: float = _last_overlay_zoom

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
		if scroll_changed:
			_verify_projection_canvas_parity()

	_last_map_canvas_xf = canvas_xf
	_last_overlay_zoom = zoom


func _sync_fog_view_transform() -> void:
	if _fog_overlay == null or _player == null or not is_instance_valid(_player):
		return
	var viewport_center_px: Vector2 = ViewProjection.get_screen_center_offset()
	var camera_focus_map_px: Vector2 = ViewProjection.resolve_camera_focus_map_px(_player)
	var zoom_val: float = ViewProjection.zoom if not is_zero_approx(ViewProjection.zoom) else 1.0
	_fog_overlay.sync_view_transform(
		viewport_center_px,
		camera_focus_map_px,
		zoom_val,
		_player.position
	)
	if OS.is_debug_build():
		if not _fog_parity_checked_once:
			_fog_parity_checked_once = true
			ViewProjection.verify_fog_projection_parity(
				viewport_center_px,
				camera_focus_map_px,
				zoom_val
			)
		elif not is_equal_approx(zoom_val, _last_fog_parity_zoom):
			_last_fog_parity_zoom = zoom_val
			ViewProjection.verify_fog_projection_parity(
				viewport_center_px,
				camera_focus_map_px,
				zoom_val
			)


func _resolve_authoritative_map_center() -> Vector2i:
	if ViewProjection.is_camera_registered():
		return ViewProjection.get_camera_center_map()
	var players: Array[Node] = get_tree().get_nodes_in_group("player")
	if not players.is_empty():
		var player_node := players[0] as Node2D
		if player_node != null:
			ViewProjection.update_camera_position(player_node.position, true)
			_mark_view_dirty(true)
			return ViewProjection.resolve_map_center_from_player(player_node)
	if _player != null and is_instance_valid(_player):
		ViewProjection.update_camera_position(_player.position, true)
		_mark_view_dirty(true)
		return ViewProjection.map_local_px_to_grid_cell(_player.position)
	return Vector2i.ZERO


## Returns false when visible rect is not ready (zero size); scroll must not run until true.
func _ensure_viewport_metrics_ready() -> bool:
	if ViewProjection.are_viewport_metrics_ready():
		return true
	return ViewProjection.try_seed_viewport_metrics(get_viewport())


func _force_initial_view_layout() -> void:
	_mark_view_dirty(true)
	_flush_view_if_dirty()
	if _chunk_manager != null:
		_chunk_manager.force_viewport_chunk_refresh()


func _debug_force_frame1_render() -> void:
	set_process(true)
	_view_dirty = true
	_view_force_sync = true
	ViewProjection.try_seed_viewport_metrics(get_viewport())
	_sync_view_scroll_and_overlays(true)
	_flush_view_if_dirty()
	if _grid_overlay != null:
		_grid_overlay.sync_uniforms(null, true)
	if _chunk_manager != null:
		_chunk_manager.force_viewport_chunk_refresh()
	_debug_log_view_metrics("force_frame1")


func _get_visual_radius() -> int:
	var radius: int = ViewProjection.get_visual_radius(_visual_radius_buffer)
	if radius <= 0:
		radius = ViewProjection.VISUAL_RADIUS_HARD_FALLBACK
	return radius


func _debug_log_view_metrics(tag: String) -> void:
	var vp_size: Vector2 = ViewProjection.get_viewport_size()
	var cell_px: int = ViewMetricsRes.CELL_SIZE_PX
	var radius: int = _get_visual_radius()
	print(
		"[MainSandbox:%s] viewport_size=%s cell_size_px=%d visual_radius=%d map_scroll=%s zoom=%s player_pos=%s"
		% [tag, vp_size, cell_px, radius, ViewProjection.map_scroll, ViewProjection.zoom, _player.position if _player != null else Vector2.ZERO]
	)


func _apply_map_scroll_for_player() -> void:
	_mark_view_dirty(false)


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


func _reposition_all() -> void:
	_sync_spawn_tracking_from_player()
	_mark_view_dirty(true)


func _mark_view_dirty(force: bool = false) -> void:
	_view_dirty = true
	if force:
		_view_force_sync = true


func _flush_view_if_dirty() -> void:
	if not _view_dirty and not _view_force_sync:
		return
	var force: bool = _view_force_sync
	_view_dirty = false
	_view_force_sync = false
	if force:
		_sync_view_scroll_and_overlays(true)
		if _grid_overlay != null:
			_grid_overlay.sync_uniforms(null, true)
		_sync_fog_view_transform()
	if OS.is_debug_build() and (force or _debug_flush_log_remaining > 0):
		print("[MainSandbox:flush] force=%s" % force)
		_debug_log_view_metrics("flush")
		if not force and _debug_flush_log_remaining > 0:
			_debug_flush_log_remaining -= 1


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_W, KEY_A, KEY_S, KEY_D:
				_mark_view_dirty(true)
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			if ViewProjection.adjust_zoom(1):
				_sync_view_scroll_and_overlays(true)
				_sync_fog_view_transform()
				_mark_view_dirty(true)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if ViewProjection.adjust_zoom(-1):
				_sync_view_scroll_and_overlays(true)
				_sync_fog_view_transform()
				_mark_view_dirty(true)
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.keycode == KEY_ESCAPE):
		get_tree().quit()
