extends Node2D

const ViewContextRes = preload("res://src/Godot/Scripts/ViewContext.gd")
const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const ViewMetricsRes = preload("res://src/Godot/Scripts/ViewMetrics.gd")
const PlayerControllerScript = preload("res://src/Godot/Scripts/PlayerController.gd")
const FogExplorationMapScript = preload("res://src/Godot/Scripts/Systems/fog-of-war/FogExplorationMap.gd")
const FogOverlayScript = preload("res://src/Godot/Scripts/Systems/fog-of-war/FogOverlay.gd")

@onready var _map_scroll: Node2D = $WorldCanvas/Tiles
@onready var _chunk_manager: Node2D = $WorldCanvas/Tiles/ChunkManager
@onready var _fog: FogExplorationMapScript = $FogExploration
@onready var _fog_overlay: FogOverlayScript = $FogOverlay/FogRect
@onready var _grid_overlay: ColorRect = $GridOverlay/GridRect
@onready var _settings_ui: CanvasLayer = $SettingsUi
@onready var _player: PlayerControllerScript = %Player

var _party
var _viewport_center: Vector2 = Vector2.ZERO

var _last_tracked_x: int = 0
var _last_tracked_y: int = 0
var _last_overlay_scroll_pos: Vector2 = Vector2(999999, 999999)
var _last_overlay_zoom: float = -1.0

var _snap_scroll_to_pixel: bool = false
var _cached_visual_radius: int = 0
var _cached_radius_zoom: float = -1.0
var _cached_radius_vp_size: Vector2 = Vector2.ZERO


func _ready() -> void:
	y_sort_enabled = false
	_map_scroll.y_sort_enabled = false
	_snap_scroll_to_pixel = ProjectSettings.get_setting("rendering/2d/snap/snap_2d_transforms_to_pixel")

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

	_refresh_viewport_metrics()
	_recompute_visual_radius_cache()

	_grid_overlay.configure(Settings.get_bool("grid.debug_grid_lines"))
	_grid_overlay.set_map_scroll(_map_scroll)

	_settings_ui.setup(_party, _map_scroll, _player)
	if not _settings_ui.settings_changed.is_connected(_on_settings_changed):
		_settings_ui.settings_changed.connect(_on_settings_changed)

	if not _player.grid_cell_changed.is_connected(_on_player_grid_cell_changed):
		_player.grid_cell_changed.connect(_on_player_grid_cell_changed)

	_apply_view_zoom()
	_player.position = ViewTransformsScript.grid_to_map_local_px(float(player.X), float(player.Y))
	_setup_fog()
	_sync_spawn_tracking_from_player()
	_refresh_viewport_metrics()
	_apply_map_scroll_for_player()
	if _fog_overlay != null:
		_fog_overlay.force_resync_scroll()
	_sync_fog_and_overlays(true)
	call_deferred("_bootstrap_after_frame")


func _physics_process(_delta: float) -> void:
	if _party == null or _party.GetSelectedCharacter() == null:
		return
	_apply_map_scroll_for_player()
	if _player != null:
		_chunk_manager.sync_center_from_player_map_px(_player.position)
	_sync_fog_and_overlays(false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_refresh_viewport_metrics()
		_recompute_visual_radius_cache()
		_reposition_all()
		if _chunk_manager != null:
			_chunk_manager.force_viewport_chunk_refresh()


func _apply_view_zoom() -> void:
	var z: float = ViewProjection.zoom
	_map_scroll.scale = Vector2(z, z)


func _on_view_changed() -> void:
	_apply_view_zoom()
	_recompute_visual_radius_cache()
	_apply_map_scroll_for_player()
	if _chunk_manager != null:
		_chunk_manager.force_viewport_chunk_refresh()
	_grid_overlay.on_view_changed()
	if _fog_overlay != null:
		_fog_overlay.on_view_changed()
	_sync_fog_and_overlays(true)


func _on_player_grid_cell_changed(cell: Vector2i) -> void:
	if cell.x == _last_tracked_x and cell.y == _last_tracked_y:
		return

	var character = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		character.MoveTo(cell.x, cell.y)

	_grid_overlay.update_region(cell.x, cell.y, _capped_grid_radius(_visual_spawn_radius()))
	_chunk_manager.sync_center_from_player_map_px(_player.position)
	_last_tracked_x = cell.x
	_last_tracked_y = cell.y


func _bootstrap_after_frame() -> void:
	await get_tree().process_frame
	if _player == null:
		return
	_refresh_viewport_metrics()
	_sync_spawn_tracking_from_player()
	var spawn_grid: Vector2i = _chunk_manager.world_px_to_grid_tile(_player.position)
	_grid_overlay.update_region(spawn_grid.x, spawn_grid.y, _capped_grid_radius(_visual_spawn_radius()))
	if _fog_overlay != null:
		_fog_overlay.force_resync_scroll()
	_sync_fog_and_overlays(true)


func _on_settings_changed() -> void:
	pass


func _setup_fog() -> void:
	if _fog == null or _fog_overlay == null or _player == null:
		return
	_fog.configure_world_anchor(_player.position)
	_fog.setup(_player)
	var fog_mat: ShaderMaterial = _fog_overlay.get_shader_material()
	_fog.bind_shader_material(fog_mat)
	_fog_overlay.set_map_scroll(_map_scroll)
	_fog_overlay.set_player(_player)
	_fog_overlay.configure(_fog.enabled, Color(0.0, 0.0, 0.0, 0.85))
	_fog_overlay.apply_static_uniforms(
		_fog.world_origin_map_px,
		_fog.world_extent_map_px,
		_fog.get_texture()
	)
	_chunk_manager.set_fog_exploration_map(_fog)
	_chunk_manager.sync_center_from_player_map_px(_player.position)
	var spawn_grid: Vector2i = _chunk_manager.world_px_to_grid_tile(_player.position)
	_chunk_manager.force_immediate_startup_pass(spawn_grid)
	if not _fog.exploration_texture_uploaded.is_connected(_on_fog_texture_uploaded):
		_fog.exploration_texture_uploaded.connect(_on_fog_texture_uploaded)


func _sync_spawn_tracking_from_player() -> void:
	if _player == null:
		return
	var spawn_map_px: Vector2 = _player.position
	_fog.configure_world_anchor(spawn_map_px)
	_chunk_manager.sync_center_from_player_map_px(spawn_map_px)
	var spawn_grid: Vector2i = _chunk_manager.world_px_to_grid_tile(spawn_map_px)
	_last_tracked_x = spawn_grid.x
	_last_tracked_y = spawn_grid.y


func _on_fog_texture_uploaded() -> void:
	_sync_fog_and_overlays(false)


## Scroll transforms when the camera moves; runtime fog uniforms + chunk culling every call.
func _sync_fog_and_overlays(force: bool = false) -> void:
	_refresh_viewport_metrics()
	var pos: Vector2 = _map_scroll.global_position
	var zoom: float = ViewProjection.zoom
	var scroll_changed: bool = force or pos != _last_overlay_scroll_pos
	var zoom_changed: bool = force or not is_equal_approx(zoom, _last_overlay_zoom)
	if scroll_changed:
		_last_overlay_scroll_pos = pos
		_grid_overlay.sync_scroll(pos, zoom)
	if scroll_changed or zoom_changed:
		_last_overlay_zoom = zoom
		if _fog_overlay != null:
			_fog_overlay.refresh_viewport_center(_viewport_center)
			_fog_overlay.sync_scroll(pos, zoom)
	if _fog_overlay != null and _fog != null:
		_fog_overlay.sync_runtime(_fog)
	_chunk_manager.refresh_chunk_fog_visibility()


func _refresh_overlays(center_x: int, center_y: int) -> void:
	_grid_overlay.update_region(center_x, center_y, _capped_grid_radius(_visual_spawn_radius()))


func _refresh_viewport_metrics() -> void:
	_viewport_center = ViewContextRes.viewport_center_from(get_viewport())


func _apply_map_scroll_for_player() -> void:
	if _player == null:
		return
	var target_screen_pos: Vector2 = _player.position
	var new_scroll: Vector2 = _viewport_center - target_screen_pos * ViewProjection.zoom
	if _snap_scroll_to_pixel:
		new_scroll = new_scroll.round()
	if new_scroll.is_equal_approx(_map_scroll.global_position):
		return
	_map_scroll.global_position = new_scroll


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
		_recompute_visual_radius_cache()
	return _cached_visual_radius


func _capped_grid_radius(visual_radius: int) -> int:
	return mini(visual_radius, Settings.get_int("grid.max_grid_radius"))


func _reposition_all() -> void:
	_apply_map_scroll_for_player()
	_sync_spawn_tracking_from_player()
	if _player != null:
		var spawn_grid: Vector2i = _chunk_manager.world_px_to_grid_tile(_player.position)
		_refresh_overlays(spawn_grid.x, spawn_grid.y)
	_sync_fog_and_overlays(true)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			ViewProjection.adjust_zoom(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			ViewProjection.adjust_zoom(-1)
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.keycode == KEY_ESCAPE):
		get_tree().quit()
