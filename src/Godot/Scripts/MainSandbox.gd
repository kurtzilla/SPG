extends Node2D

const ObliqueBridgeScript = preload("res://src/Godot/Scripts/ObliqueBridge.gd")
const ViewTransformsScript = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const PlaceholderTextureGenerator = preload("res://src/Godot/Assets/PlaceholderTextureGenerator.gd")
const TerrainMapSyncScript = preload("res://src/Godot/Scripts/TerrainMapSync.gd")
const FogRevealContextScript = preload("res://src/Godot/Scripts/FogRevealContext.gd")

const GRID_PATCH_RADIUS: int = 5
const VISUAL_RADIUS_BUFFER: int = 2
const DEFAULT_MAP_SEED: int = 42
const MOVE_REPEAT_INTERVAL: float = 0.12
const DEBUG_GRID_LINES: bool = true

@onready var _map_scroll: Node2D = $WorldCanvas/Tiles
@onready var _terrain_layer: TileMapLayer = $WorldCanvas/Tiles/TerrainLayer
@onready var _grid_overlay: Node2D = $GridOverlay/GridDraw
@onready var _fog_overlay: Sprite2D = $FogLayer/FogOverlay
@onready var _reveal_ring_draw: Node2D = $RevealRingLayer/RevealRingDraw
@onready var _settings_ui: CanvasLayer = $SettingsUi
@onready var _characters: Node2D = $GameEntitiesLayer/Characters
@onready var _player_sprite: Sprite2D = $GameEntitiesLayer/Characters/PlayerSprite

var _grid
var _map_generator
var _party
var _visibility
var _terrain_sync
var _viewport_center: Vector2 = Vector2.ZERO
var _move_repeat_timer: float = 0.0

var _map_target_offset: Vector2 = Vector2.ZERO

var _last_tracked_x: int = 0
var _last_tracked_y: int = 0
var _cached_visual_radius: int = 0
var _zoom_sync_pending: bool = false
var _last_overlay_scroll_pos: Vector2 = Vector2.INF
var _last_fog_enabled: bool = true


func _ready() -> void:
	y_sort_enabled = false
	_map_scroll.y_sort_enabled = false
	_characters.z_index = 1
	_characters.y_sort_enabled = false

	ViewProjection.load_settings()
	if not ViewProjection.view_changed.is_connected(_on_view_changed):
		ViewProjection.view_changed.connect(_on_view_changed)

	var core = get_node("/root/CoreBridge")
	_grid = core.CreateGridModel()
	_map_generator = core.CreateMapGenerator(DEFAULT_MAP_SEED)
	_party = core.CreatePartyModel()
	_visibility = core.CreateVisibilityModel()
	ViewProjection.apply_fog_to_visibility(_visibility)
	_last_fog_enabled = _visibility.FogEnabled

	var player = core.CreateCharacter("player", "Player", 0, 0)
	_party.AddCharacter(player)

	_last_tracked_x = player.X
	_last_tracked_y = player.Y
	_viewport_center = (get_viewport_rect().size * 0.5).floor()

	_terrain_sync = TerrainMapSyncScript.new()
	_terrain_sync.setup(_terrain_layer)

	_grid_overlay.configure(DEBUG_GRID_LINES)
	_grid_overlay.set_map_scroll(_map_scroll)

	_fog_overlay.set_map_scroll(_map_scroll)
	_fog_overlay.set_visibility(_visibility)
	_fog_overlay.set_fog_enabled(_visibility.FogEnabled)

	_settings_ui.setup(_visibility, _party, _map_scroll)
	if not _settings_ui.settings_changed.is_connected(_on_settings_changed):
		_settings_ui.settings_changed.connect(_on_settings_changed)

	_apply_view_zoom()
	_setup_player_sprite()
	_update_map_target(player.X, player.Y)
	_snap_map_offset()
	_player_sprite.global_position = _viewport_center.floor()
	call_deferred("_bootstrap_fog_after_frame")


func _process(delta: float) -> void:
	if Input.is_physical_key_pressed(KEY_ESCAPE):
		get_tree().quit()
		return

	if _party == null or _party.GetSelectedCharacter() == null:
		return

	var character = _party.GetSelectedCharacter()
	var move_delta: Vector2i = _get_held_move_delta()

	if move_delta != Vector2i.ZERO:
		_move_repeat_timer -= delta
		if _move_repeat_timer <= 0.0:
			character.MoveRelative(move_delta.x, move_delta.y)
			_move_repeat_timer = MOVE_REPEAT_INTERVAL
	else:
		_move_repeat_timer = 0.0

	if character.X != _last_tracked_x or character.Y != _last_tracked_y:
		var visual_radius: int = _visual_spawn_radius()
		var fog_radius_changed: bool = visual_radius != _cached_visual_radius
		_refresh_overlays_on_move(character.X, character.Y, fog_radius_changed)
		_sync_world_and_terrain(character.X, character.Y)
		_update_map_target(character.X, character.Y)
		_snap_map_offset()
		_last_tracked_x = character.X
		_last_tracked_y = character.Y

	_player_sprite.global_position = _viewport_center.floor()
	_sync_overlay_scroll()
	_sync_reveal_ring_if_active()

	if _zoom_sync_pending:
		_zoom_sync_pending = false
		_sync_tiles_after_zoom(character.X, character.Y)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_viewport_center = (get_viewport_rect().size * 0.5).floor()
		_reposition_all()


func _get_held_move_delta() -> Vector2i:
	var dx: int = 0
	var dy: int = 0
	if Input.is_physical_key_pressed(KEY_D): dx = 1
	elif Input.is_physical_key_pressed(KEY_A): dx = -1
	if Input.is_physical_key_pressed(KEY_S): dy = 1
	elif Input.is_physical_key_pressed(KEY_W): dy = -1
	return Vector2i(dx, dy)


func _setup_player_sprite() -> void:
	_player_sprite.texture = PlaceholderTextureGenerator.create_character_billboard_texture()
	_player_sprite.centered = true
	_player_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_update_player_sprite_anchor()


func _update_player_sprite_anchor() -> void:
	var half_cell_height: float = (
		float(ObliqueBridgeScript.CELL_SIZE_PX) * ViewProjection.zoom * 0.5
	)
	_player_sprite.offset = Vector2(0.0, -floor(half_cell_height))


func _apply_view_zoom() -> void:
	var z: float = ViewProjection.zoom
	_map_scroll.scale = Vector2(z, z)
	_characters.scale = Vector2(z, z)
	_terrain_layer.scale = Vector2.ONE
	_update_player_sprite_anchor()


func _on_view_changed() -> void:
	_apply_view_zoom()
	var character = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		_update_map_target(character.X, character.Y)
		_snap_map_offset()
	_zoom_sync_pending = true
	_player_sprite.global_position = _viewport_center.floor()
	_grid_overlay.on_view_changed()
	_fog_overlay.on_view_changed()


func _reveal_context() -> FogRevealContext:
	var fog_enabled: bool = _visibility != null and _visibility.FogEnabled
	return FogRevealContextScript.from_overlay(_fog_overlay, fog_enabled)


func _push_reveal_context_to_grid() -> void:
	_grid_overlay.set_reveal_context(_reveal_context())


func _sync_reveal_ring_if_active() -> void:
	if _reveal_ring_draw == null:
		return
	if _visibility == null or not _visibility.FogEnabled:
		_reveal_ring_draw.sync_from_fog(null, _map_scroll)
		return
	_reveal_ring_draw.sync_from_fog(_fog_overlay, _map_scroll)


func _bootstrap_fog_after_frame() -> void:
	await get_tree().process_frame
	_fog_overlay.configure(true, true)
	_bootstrap_fog_at_player()


func _bootstrap_fog_at_player() -> void:
	var character = _party.GetSelectedCharacter() if _party != null else null
	if character == null or _visibility == null:
		_refresh_fog_state()
		return
	var visual_radius: int = _visual_spawn_radius()
	var move_radius: int = _visibility.MovementRevealRadius
	_grid_overlay.update_region(character.X, character.Y, visual_radius)
	_fog_overlay.set_fog_enabled(_visibility.FogEnabled)
	if _visibility.FogEnabled:
		_fog_overlay.bootstrap_at(
			character.X,
			character.Y,
			move_radius,
			visual_radius,
			_visibility.InitialRevealRadius
		)
		_fog_overlay.sync_map_scroll()
	else:
		_fog_overlay.configure(true, false)
	_push_reveal_context_to_grid()
	_sync_world_and_terrain(character.X, character.Y)
	_last_overlay_scroll_pos = _map_scroll.global_position
	_sync_reveal_ring_if_active()


func _on_settings_changed() -> void:
	pass


func _refresh_fog_state() -> void:
	var character = _party.GetSelectedCharacter() if _party != null else null
	if character == null:
		return
	var fog_turned_on: bool = (
		_visibility != null
		and _visibility.FogEnabled
		and not _last_fog_enabled
	)
	if _visibility != null:
		_last_fog_enabled = _visibility.FogEnabled
	if fog_turned_on:
		var visual_radius: int = _visual_spawn_radius()
		var move_radius: int = _visibility.MovementRevealRadius
		_grid_overlay.update_region(character.X, character.Y, visual_radius)
		_fog_overlay.set_fog_enabled(true)
		_fog_overlay.bootstrap_at(
			character.X,
			character.Y,
			move_radius,
			visual_radius,
			_visibility.InitialRevealRadius
		)
	else:
		_refresh_overlays(character.X, character.Y)
	_push_reveal_context_to_grid()
	_sync_world_and_terrain(character.X, character.Y)
	_last_overlay_scroll_pos = _map_scroll.global_position
	_sync_reveal_ring_if_active()


func _sync_overlay_scroll() -> void:
	_grid_overlay.set_map_scroll(_map_scroll)
	var scroll_pos: Vector2 = _map_scroll.global_position
	if scroll_pos != _last_overlay_scroll_pos:
		_last_overlay_scroll_pos = scroll_pos
		_fog_overlay.sync_map_scroll()
		_grid_overlay.queue_redraw()
	_sync_reveal_ring_if_active()


func _refresh_overlays(center_x: int, center_y: int) -> void:
	var visual_radius: int = _visual_spawn_radius()
	var fog_active: bool = _visibility != null and _visibility.FogEnabled
	var move_radius: int = (
		_visibility.MovementRevealRadius if _visibility != null else 0
	)
	if _visibility != null:
		_fog_overlay.set_fog_enabled(_visibility.FogEnabled)
	_fog_overlay.configure(true, fog_active)
	_grid_overlay.update_region(center_x, center_y, visual_radius)
	if fog_active:
		_fog_overlay.update_region(center_x, center_y, visual_radius, move_radius)
	_push_reveal_context_to_grid()
	_last_overlay_scroll_pos = _map_scroll.global_position


func _refresh_overlays_on_move(center_x: int, center_y: int, fog_radius_changed: bool) -> void:
	var visual_radius: int = _visual_spawn_radius()
	_grid_overlay.update_region(center_x, center_y, visual_radius)
	var move_radius: int = (
		_visibility.MovementRevealRadius if _visibility != null else 0
	)
	if fog_radius_changed:
		_fog_overlay.update_region(center_x, center_y, visual_radius, move_radius)
	elif _visibility != null and _visibility.FogEnabled:
		_fog_overlay.on_player_moved(center_x, center_y, move_radius, visual_radius)
	_push_reveal_context_to_grid()
	_last_overlay_scroll_pos = _map_scroll.global_position


func _update_map_target(grid_x: int, grid_y: int) -> void:
	var target_screen_pos: Vector2 = ObliqueBridgeScript.data_to_screen(float(grid_x), float(grid_y))
	_map_target_offset = _viewport_center.floor() - target_screen_pos * ViewProjection.zoom


func _snap_map_offset() -> void:
	_map_scroll.global_position = _map_target_offset.floor()


func _visual_spawn_radius() -> int:
	var ctx: ViewContext = _view_context()
	return ViewTransformsScript.visible_grid_radius_cells(ctx, VISUAL_RADIUS_BUFFER)


func _view_context() -> ViewContext:
	return ViewContext.from_viewport(_map_scroll, get_viewport(), ViewProjection.zoom)


func _data_radius(visual_radius: int) -> int:
	return maxi(GRID_PATCH_RADIUS + 1, visual_radius + 1)


func _update_dynamic_world(center_x: int, center_y: int) -> void:
	_sync_world_and_terrain(center_x, center_y)


func _sync_world_and_terrain(center_x: int, center_y: int) -> void:
	var visual_radius: int = _visual_spawn_radius()
	_cached_visual_radius = visual_radius
	var data_radius: int = _data_radius(visual_radius)
	var reveal_context: FogRevealContext = _reveal_context()
	_map_generator.GenerateRegion(_grid, center_x, center_y, data_radius)
	_terrain_sync.sync_region(
		_grid, center_x, center_y, data_radius, visual_radius, reveal_context
	)
	if reveal_context.fog_enabled:
		_terrain_sync.sync_revealed_in_view(
			_grid, reveal_context, center_x, center_y, visual_radius
		)


func _sync_tiles_after_zoom(center_x: int, center_y: int) -> void:
	var new_radius: int = _visual_spawn_radius()
	var old_radius: int = _cached_visual_radius
	_grid_overlay.on_view_changed()
	_fog_overlay.on_view_changed()
	_refresh_overlays(center_x, center_y)

	if new_radius <= old_radius:
		_cached_visual_radius = new_radius
		return

	var data_radius: int = _data_radius(new_radius)
	var reveal_context: FogRevealContext = _reveal_context()
	_map_generator.GenerateRegion(_grid, center_x, center_y, data_radius)
	_terrain_sync.sync_annulus(
		_grid, center_x, center_y, old_radius, new_radius, reveal_context
	)
	_cached_visual_radius = new_radius


func _reposition_all() -> void:
	_player_sprite.global_position = _viewport_center.floor()
	var character = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		_update_map_target(character.X, character.Y)
		_snap_map_offset()
		_update_dynamic_world(character.X, character.Y)
		_refresh_overlays(character.X, character.Y)
		_last_overlay_scroll_pos = Vector2.INF
		_sync_overlay_scroll()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			ViewProjection.adjust_zoom(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			ViewProjection.adjust_zoom(-1)
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.keycode == KEY_ESCAPE):
		get_tree().quit()
