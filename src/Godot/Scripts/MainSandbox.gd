extends Node2D

const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const ViewFrameScript = preload("res://src/Godot/Scripts/ViewFrame.gd")
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

var _last_tracked_x: int = 0
var _last_tracked_y: int = 0

var _snap_scroll_to_pixel: bool = false

const ZOOM_REBUILD_DELAY_SEC: float = 0.05

var _zoom_rebuild_timer: SceneTreeTimer
var _zoom_rebuild_scheduled_zoom: float = -1.0


func _ready() -> void:
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
	_settings_ui.setup(_party, _player)

	if not _player.grid_cell_changed.is_connected(_on_player_grid_cell_changed):
		_player.grid_cell_changed.connect(_on_player_grid_cell_changed)
	if not _player.map_position_changed.is_connected(_on_player_map_position_changed):
		_player.map_position_changed.connect(_on_player_map_position_changed)

	_player.position = ViewTransformsScript.grid_to_map_local_px(float(player.X), float(player.Y))
	ViewProjection.register_camera(_player)

	if not _ensure_viewport_metrics_ready():
		call_deferred("_finish_ready_after_viewport")
		return
	_finish_ready_viewport_dependent()
	call_deferred("_bootstrap_after_frame")


func _read_view_settings() -> void:
	_debug_grid_enabled = Settings.get_bool("grid.debug_grid_lines")


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


func _process(_delta: float) -> void:
	if _player != null and is_instance_valid(_player):
		_apply_view_frame()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		ViewProjection.notify_viewport_resized()
		_sync_spawn_tracking_from_player()
		if _fog_overlay != null:
			_fog_overlay.ensure_buffer_for_viewport()
		_schedule_zoom_deferred_rebuild()


func _apply_view_frame() -> void:
	if _player == null or not is_instance_valid(_player):
		return

	var frame: ViewFrameScript = ViewFrameScript.build(_player)

	_map_scroll.scale = Vector2(frame.zoom, frame.zoom)
	var target_offset: Vector2 = ViewProjection.scroll_node_canvas_position()
	if _should_snap_scroll_to_pixel():
		target_offset = target_offset.round()
	_world_canvas.offset = Vector2.ZERO
	if not target_offset.is_equal_approx(_map_scroll.position):
		_map_scroll.position = target_offset

	if _grid_overlay != null:
		_grid_overlay.apply_view_frame(frame)
	if _fog_overlay != null:
		_fog_overlay.apply_view_frame(frame)

	if OS.is_debug_build():
		_verify_projection_canvas_parity(frame)


func _should_snap_scroll_to_pixel() -> bool:
	if not _snap_scroll_to_pixel:
		return false
	var z: float = ViewProjection.zoom
	return absf(z - roundf(z)) < 0.001


func _on_view_changed() -> void:
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
	if _chunk_manager != null:
		_chunk_manager.sync_center_from_player_map_px(map_px)


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
		get_tree().quit()
