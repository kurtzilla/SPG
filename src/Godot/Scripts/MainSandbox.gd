extends Node2D

const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const PlayerControllerScript = preload("res://src/Godot/Scripts/PlayerController.gd")

@onready var _map_scroll: Node2D = $WorldCanvas/Tiles
@onready var _chunk_manager: Node2D = $WorldCanvas/Tiles/ChunkManager
@onready var _grid_overlay: ColorRect = $GridOverlay/GridRect
@onready var _settings_ui: CanvasLayer = $SettingsUi
@onready var _player: PlayerControllerScript = %Player

var _party
var _viewport_center: Vector2 = Vector2.ZERO

var _last_tracked_x: int = 0
var _last_tracked_y: int = 0
var _last_overlay_scroll_pos: Vector2 = Vector2(999999, 999999)
var _last_chunk_coord: Vector2i = Vector2i(999999, 999999)


func _ready() -> void:
	y_sort_enabled = false
	_map_scroll.y_sort_enabled = false

	if not ViewProjection.view_changed.is_connected(_on_view_changed):
		ViewProjection.view_changed.connect(_on_view_changed)

	var core = get_node("/root/CoreBridge")
	_party = core.CreatePartyModel()

	var player = core.CreateCharacter("player", "Player", 0, 0)
	_party.AddCharacter(player)

	_last_tracked_x = player.X
	_last_tracked_y = player.Y
	_viewport_center = (get_viewport_rect().size * 0.5).floor()

	_grid_overlay.configure(Settings.get_bool("grid.debug_grid_lines"))
	_grid_overlay.set_map_scroll(_map_scroll)

	_settings_ui.setup(_party, _map_scroll, _player)
	if not _settings_ui.settings_changed.is_connected(_on_settings_changed):
		_settings_ui.settings_changed.connect(_on_settings_changed)

	if _player == null:
		push_error("MainSandbox: Player node missing — check Player.tscn instance in MainSandbox.tscn")
		return

	if not _player.grid_cell_changed.is_connected(_on_player_grid_cell_changed):
		_player.grid_cell_changed.connect(_on_player_grid_cell_changed)

	_apply_view_zoom()
	_player.position = ViewTransformsScript.grid_to_map_local_px(float(player.X), float(player.Y))
	_apply_map_scroll_for_player()
	_update_chunks_if_needed(player.X, player.Y)
	_force_sync_overlay_scroll()
	call_deferred("_bootstrap_after_frame")


func _process(_delta: float) -> void:
	if Input.is_physical_key_pressed(KEY_ESCAPE):
		get_tree().quit()
		return

	if _party == null or _party.GetSelectedCharacter() == null:
		return

	_apply_map_scroll_for_player()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_viewport_center = (get_viewport_rect().size * 0.5).floor()
		_reposition_all()


func _apply_view_zoom() -> void:
	var z: float = ViewProjection.zoom
	_map_scroll.scale = Vector2(z, z)


func _on_view_changed() -> void:
	_apply_view_zoom()
	_apply_map_scroll_for_player()
	_grid_overlay.on_view_changed()
	_force_sync_overlay_scroll()


func _on_player_grid_cell_changed(cell: Vector2i) -> void:
	if cell.x == _last_tracked_x and cell.y == _last_tracked_y:
		return

	var character = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		character.MoveTo(cell.x, cell.y)

	var visual_radius: int = _visual_spawn_radius()
	_grid_overlay.update_region(cell.x, cell.y, _capped_grid_radius(visual_radius))
	_update_chunks_if_needed(cell.x, cell.y)
	_last_tracked_x = cell.x
	_last_tracked_y = cell.y


func _bootstrap_after_frame() -> void:
	await get_tree().process_frame
	var character = _party.GetSelectedCharacter() if _party != null else null
	if character == null:
		return
	var visual_radius: int = _visual_spawn_radius()
	_grid_overlay.update_region(character.X, character.Y, _capped_grid_radius(visual_radius))
	_update_chunks_if_needed(character.X, character.Y)
	_force_sync_overlay_scroll()


func _update_chunks_if_needed(grid_x: int, grid_y: int) -> void:
	var grid_tile := Vector2i(grid_x, grid_y)
	var chunk_coord: Vector2i = _chunk_manager.grid_to_chunk_coord(grid_tile)
	if chunk_coord == _last_chunk_coord:
		return
	_last_chunk_coord = chunk_coord
	_chunk_manager.update_center_grid(grid_tile)


func _on_settings_changed() -> void:
	pass


func _sync_overlay_scroll_if_moved() -> void:
	var pos: Vector2 = _map_scroll.global_position
	if pos == _last_overlay_scroll_pos:
		return
	_last_overlay_scroll_pos = pos
	_grid_overlay.set_map_scroll(_map_scroll)
	_grid_overlay.sync_uniforms()


func _force_sync_overlay_scroll() -> void:
	_last_overlay_scroll_pos = Vector2(999999, 999999)
	_sync_overlay_scroll_if_moved()


func _refresh_overlays(center_x: int, center_y: int) -> void:
	var visual_radius: int = _visual_spawn_radius()
	_grid_overlay.update_region(center_x, center_y, _capped_grid_radius(visual_radius))


func _apply_map_scroll_for_player() -> void:
	if _player == null:
		return
	var target_screen_pos: Vector2 = _player.position
	var new_scroll: Vector2 = _viewport_center - target_screen_pos * ViewProjection.zoom
	if new_scroll.is_equal_approx(_map_scroll.global_position):
		return
	_map_scroll.global_position = new_scroll
	_sync_overlay_scroll_if_moved()


func _visual_spawn_radius() -> int:
	var ctx: ViewContext = _view_context()
	return ViewTransformsScript.visible_grid_radius_cells(
		ctx, Settings.get_int("grid.visual_radius_buffer")
	)


func _capped_grid_radius(visual_radius: int) -> int:
	return mini(visual_radius, Settings.get_int("grid.max_grid_radius"))


func _view_context() -> ViewContext:
	return ViewContext.from_viewport(_map_scroll, get_viewport(), ViewProjection.zoom)


func _reposition_all() -> void:
	_apply_map_scroll_for_player()
	var character = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		_update_chunks_if_needed(character.X, character.Y)
		_refresh_overlays(character.X, character.Y)
		_force_sync_overlay_scroll()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			ViewProjection.adjust_zoom(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			ViewProjection.adjust_zoom(-1)
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.keycode == KEY_ESCAPE):
		get_tree().quit()
