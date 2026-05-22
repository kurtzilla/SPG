extends Node2D

const ObliqueBridgeScript = preload("res://src/Godot/Scripts/ObliqueBridge.gd")
const PlaceholderTextureGenerator = preload("res://src/Godot/Assets/PlaceholderTextureGenerator.gd")
const TerrainMapSyncScript = preload("res://src/Godot/Scripts/TerrainMapSync.gd")

const GRID_PATCH_RADIUS: int = 5
const VISUAL_RADIUS_BUFFER: int = 2
const DEFAULT_MAP_SEED: int = 42
const MOVE_DURATION: float = 0.15
const MOVE_REPEAT_INTERVAL: float = 0.12
const DEBUG_GRID_LINES: bool = true

@onready var _map_scroll: Node2D = $Tiles
@onready var _terrain_layer: TileMapLayer = $Tiles/TerrainLayer
@onready var _grid_overlay: Node2D = $GridOverlay/GridDraw
@onready var _characters: Node2D = $Characters
@onready var _player_sprite: Sprite2D = $Characters/PlayerSprite

var _grid
var _map_generator
var _party
var _terrain_sync: TerrainMapSync
var _viewport_center: Vector2 = Vector2.ZERO
var _move_repeat_timer: float = 0.0

var _map_start_offset: Vector2 = Vector2.ZERO
var _map_target_offset: Vector2 = Vector2.ZERO
var _move_alpha: float = 1.0

var _last_tracked_x: int = 0
var _last_tracked_y: int = 0
var _cached_visual_radius: int = 0
var _zoom_sync_pending: bool = false


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

	var player = core.CreateCharacter("player", "Player", 0, 0)
	_party.AddCharacter(player)

	_last_tracked_x = player.X
	_last_tracked_y = player.Y
	_viewport_center = (get_viewport_rect().size * 0.5).floor()

	_terrain_sync = TerrainMapSyncScript.new()
	_terrain_sync.setup(_terrain_layer)
	_grid_overlay.configure(DEBUG_GRID_LINES)
	_grid_overlay.set_map_scroll(_map_scroll)
	_apply_view_zoom()

	_setup_player_sprite()
	_update_dynamic_world(player.X, player.Y)
	_update_map_target(player.X, player.Y)
	_snap_map_offset()
	_player_sprite.global_position = _viewport_center.floor()


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
		_update_dynamic_world(character.X, character.Y)
		_grid_overlay.set_map_scroll(_map_scroll)
		_map_start_offset = _map_scroll.global_position
		_update_map_target(character.X, character.Y)
		_move_alpha = 0.0
		_last_tracked_x = character.X
		_last_tracked_y = character.Y

	if _move_alpha < 1.0:
		_move_alpha += delta / MOVE_DURATION
		if _move_alpha > 1.0:
			_move_alpha = 1.0
		_map_scroll.global_position = _map_start_offset.lerp(_map_target_offset, _move_alpha)
	else:
		_map_scroll.global_position = _map_target_offset.floor()

	_player_sprite.global_position = _viewport_center.floor()
	_grid_overlay.set_map_scroll(_map_scroll)
	_grid_overlay.queue_redraw()

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
		_map_start_offset = _map_scroll.global_position
		_update_map_target(character.X, character.Y)
	_zoom_sync_pending = true
	_player_sprite.global_position = _viewport_center.floor()


func _update_map_target(grid_x: int, grid_y: int) -> void:
	var target_screen_pos: Vector2 = ObliqueBridgeScript.data_to_screen(float(grid_x), float(grid_y))
	_map_target_offset = _viewport_center.floor() - target_screen_pos * ViewProjection.zoom


func _snap_map_offset() -> void:
	_map_scroll.global_position = _map_target_offset.floor()
	_move_alpha = 1.0


func _visual_spawn_radius() -> int:
	var viewport_size: Vector2 = get_viewport_rect().size
	var cell_px: float = float(ObliqueBridgeScript.CELL_SIZE_PX) * ViewProjection.zoom
	var half_x: int = int(ceil(viewport_size.x * 0.5 / cell_px)) + VISUAL_RADIUS_BUFFER
	var half_y: int = int(ceil(viewport_size.y * 0.5 / cell_px)) + VISUAL_RADIUS_BUFFER
	return maxi(half_x, half_y)


func _data_radius(visual_radius: int) -> int:
	return maxi(GRID_PATCH_RADIUS + 1, visual_radius + 1)


func _update_dynamic_world(center_x: int, center_y: int) -> void:
	var visual_radius: int = _visual_spawn_radius()
	_cached_visual_radius = visual_radius
	var data_radius: int = _data_radius(visual_radius)
	_map_generator.GenerateRegion(_grid, center_x, center_y, data_radius)
	_terrain_sync.sync_region(_grid, center_x, center_y, data_radius, visual_radius)
	_grid_overlay.update_region(center_x, center_y, visual_radius)


func _sync_tiles_after_zoom(center_x: int, center_y: int) -> void:
	var new_radius: int = _visual_spawn_radius()
	var old_radius: int = _cached_visual_radius
	_grid_overlay.on_view_changed()
	_grid_overlay.update_region(center_x, center_y, new_radius)

	if new_radius <= old_radius:
		_cached_visual_radius = new_radius
		return

	var data_radius: int = _data_radius(new_radius)
	_map_generator.GenerateRegion(_grid, center_x, center_y, data_radius)
	_terrain_sync.sync_annulus(_grid, center_x, center_y, old_radius, new_radius)
	_cached_visual_radius = new_radius


func _reposition_all() -> void:
	_player_sprite.global_position = _viewport_center.floor()
	var character = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		_update_map_target(character.X, character.Y)
		_snap_map_offset()
		_update_dynamic_world(character.X, character.Y)
		_grid_overlay.set_map_scroll(_map_scroll)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			ViewProjection.adjust_zoom(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			ViewProjection.adjust_zoom(-1)
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.keycode == KEY_ESCAPE):
		get_tree().quit()
