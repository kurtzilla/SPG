extends Node2D

const ObliqueBridgeScript = preload("res://src/Godot/Scripts/ObliqueBridge.gd")
const PlaceholderTextureGenerator = preload("res://src/Godot/Assets/PlaceholderTextureGenerator.gd")
const TerrainTileTexturesScript = preload("res://src/Godot/Scripts/TerrainTileTextures.gd")

const GRID_PATCH_RADIUS: int = 5
const DEFAULT_MAP_SEED: int = 42
const MOVE_DURATION: float = 0.15
const MOVE_REPEAT_INTERVAL: float = 0.12
const DEBUG_GRID_CHECKERBOARD: bool = true
const ENABLE_SPAWN_FADE: bool = false

@onready var _tiles: Node2D = $Tiles
@onready var _characters: Node2D = $Characters
@onready var _player_sprite: Sprite2D = $Characters/PlayerSprite

var _grid
var _map_generator
var _party
var _viewport_center: Vector2 = Vector2.ZERO
var _move_repeat_timer: float = 0.0

var _map_start_offset: Vector2 = Vector2.ZERO
var _map_target_offset: Vector2 = Vector2.ZERO
var _move_alpha: float = 1.0

var _last_tracked_x: int = 0
var _last_tracked_y: int = 0

var _spawned_tiles: Dictionary = {}

func _ready() -> void:
	y_sort_enabled = false
	_tiles.y_sort_enabled = false
	_characters.z_index = 1
	_characters.y_sort_enabled = false

	var core = get_node("/root/CoreBridge")
	_grid = core.CreateGridModel()
	_map_generator = core.CreateMapGenerator(DEFAULT_MAP_SEED)
	_party = core.CreatePartyModel()

	var player = core.CreateCharacter("player", "Player", 0, 0)
	_party.AddCharacter(player)

	_last_tracked_x = player.X
	_last_tracked_y = player.Y
	_viewport_center = (get_viewport_rect().size * 0.5).floor()

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
		_map_start_offset = _tiles.global_position
		_update_map_target(character.X, character.Y)
		_move_alpha = 0.0
		_last_tracked_x = character.X
		_last_tracked_y = character.Y

	if _move_alpha < 1.0:
		_move_alpha += delta / MOVE_DURATION
		if _move_alpha > 1.0:
			_move_alpha = 1.0
		_tiles.global_position = _map_start_offset.lerp(_map_target_offset, _move_alpha)
	else:
		_tiles.global_position = _map_target_offset.floor()

	_player_sprite.global_position = _viewport_center.floor()


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
	var half_cell_height: float = ObliqueBridgeScript.meters_to_pixels(ObliqueBridgeScript.METERS_PER_CELL * 0.5)
	_player_sprite.centered = true
	_player_sprite.offset = Vector2(0.0, -floor(half_cell_height))
	_player_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _update_map_target(grid_x: int, grid_y: int) -> void:
	var target_screen_pos: Vector2 = ObliqueBridgeScript.data_to_screen(float(grid_x), float(grid_y))
	_map_target_offset = _viewport_center.floor() - target_screen_pos


func _snap_map_offset() -> void:
	_tiles.global_position = _map_target_offset.floor()
	_move_alpha = 1.0


func _sync_all_tile_locals() -> void:
	for tile: Node in _tiles.get_children():
		if tile is Sprite2D:
			var sprite: Sprite2D = tile as Sprite2D
			if sprite.has_meta("grid_x") and sprite.has_meta("grid_y"):
				var gx: int = sprite.get_meta("grid_x") as int
				var gy: int = sprite.get_meta("grid_y") as int
				sprite.position = ObliqueBridgeScript.data_to_screen(float(gx), float(gy))


func _apply_debug_checkerboard_tint(sprite: Sprite2D, gx: int, gy: int) -> void:
	if not DEBUG_GRID_CHECKERBOARD:
		return
	if sprite.get_meta("is_transition", false):
		return
	if (gx + gy) % 2 == 0:
		sprite.modulate = Color(0.82, 0.88, 0.78, 1.0)
	else:
		sprite.modulate = Color(1.0, 1.0, 1.0, 1.0)


func _update_dynamic_world(center_x: int, center_y: int) -> void:
	var solid_texture_map: Dictionary = ObliqueBridgeScript.build_solid_terrain_texture_map()
	var color_map: Dictionary = ObliqueBridgeScript.build_solid_terrain_color_map()
	var noise_mask: Texture2D = TerrainTileTexturesScript.create_seamless_noise_mask_texture()

	var search_radius: int = GRID_PATCH_RADIUS + 1
	_map_generator.GenerateRegion(_grid, center_x, center_y, search_radius)

	for gx in range(center_x - search_radius, center_x + search_radius + 1):
		for gy in range(center_y - search_radius, center_y + search_radius + 1):
			var tile_key: String = str(gx) + "," + str(gy)
			var local_pos: Vector2 = ObliqueBridgeScript.data_to_screen(float(gx), float(gy))

			if not _spawned_tiles.has(tile_key):
				var start_child_count: int = _tiles.get_child_count()

				ObliqueBridgeScript.spawn_cell_visuals(
					_tiles, _grid, gx, gy, local_pos, solid_texture_map, color_map, noise_mask
				)

				for i in range(start_child_count, _tiles.get_child_count()):
					var child = _tiles.get_child(i)
					if child is Sprite2D:
						var sprite: Sprite2D = child as Sprite2D
						if sprite.has_meta("grid_x") and sprite.has_meta("grid_y"):
							var tgx: int = sprite.get_meta("grid_x") as int
							var tgy: int = sprite.get_meta("grid_y") as int
							_apply_debug_checkerboard_tint(sprite, tgx, tgy)
						if ENABLE_SPAWN_FADE:
							sprite.modulate.a = 0.0
				_spawned_tiles[tile_key] = true
			else:
				ObliqueBridgeScript.refresh_cell_visuals(
					_tiles, _grid, gx, gy, local_pos, solid_texture_map, color_map, noise_mask
				)
				var base_sprite: Sprite2D = ObliqueBridgeScript.find_base_sprite(_tiles, gx, gy)
				if base_sprite != null:
					_apply_debug_checkerboard_tint(base_sprite, gx, gy)


func _reposition_all() -> void:
	_player_sprite.global_position = _viewport_center.floor()
	var character = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		_update_map_target(character.X, character.Y)
		_snap_map_offset()
	_sync_all_tile_locals()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.keycode == KEY_ESCAPE):
		get_tree().quit()
