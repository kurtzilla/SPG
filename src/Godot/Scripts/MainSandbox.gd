extends Node2D

const PlaceholderTextureGenerator = preload("res://src/Godot/Assets/PlaceholderTextureGenerator.gd")
const ObliqueBridgeScript = preload("res://src/Godot/Scripts/ObliqueBridge.gd")
const TerrainTileTexturesScript = preload("res://src/Godot/Scripts/TerrainTileTextures.gd")

const GRID_PATCH_RADIUS: int = 5
const DEFAULT_MAP_SEED: int = 42
const MOVE_DURATION: float = 0.15
const MOVE_REPEAT_INTERVAL: float = 0.12

@onready var _tiles: Node2D = $Tiles
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
	y_sort_enabled = true
	_tiles.y_sort_enabled = true
	if _player_sprite.get_parent() is Node2D:
		(_player_sprite.get_parent() as Node2D).y_sort_enabled = true

	var core = get_node("/root/CoreBridge")
	_grid = core.CreateGridModel()
	_map_generator = core.CreateMapGenerator(DEFAULT_MAP_SEED)
	_party = core.CreatePartyModel()
	
	var player = core.CreateCharacter("player", "Player", 0, 0)
	_party.AddCharacter(player)

	_last_tracked_x = player.X
	_last_tracked_y = player.Y

	_viewport_center = get_viewport_rect().size * 0.5
	_setup_player_sprite()
	
	_player_sprite.global_position = _viewport_center.floor()
	_update_dynamic_world(player.X, player.Y)
	
	_map_target_offset = _viewport_center - ObliqueBridgeScript.data_to_screen(float(player.X), float(player.Y))
	_map_start_offset = _map_target_offset
	_tiles.global_position = _map_target_offset.floor()


func _process(delta: float) -> void:
	# OVERRIDE: Directly poll the OS keyboard state every frame. 
	# If Escape is held, force the window shut immediately.
	if Input.is_physical_key_pressed(KEY_ESCAPE):
		get_tree().quit()
		return

	if _party == null:
		return

	var character = _party.GetSelectedCharacter()
	if character == null:
		return

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
		_map_target_offset = _viewport_center - ObliqueBridgeScript.data_to_screen(float(character.X), float(character.Y))
		
		# JITTER KILLER: If moving up or down (W/S), snap the positions instantly 
		# instead of lerping. This pinpoints if the lerp calculation is causing the jitter.
		if move_delta.y != 0:
			_move_alpha = 1.0
			_tiles.global_position = _map_target_offset.floor()
		else:
			_move_alpha = 0.0
		
		_last_tracked_x = character.X
		_last_tracked_y = character.Y

	if _move_alpha < 1.0:
		_move_alpha += delta / MOVE_DURATION
		if _move_alpha > 1.0:
			_move_alpha = 1.0
		var continuous_pos: Vector2 = _map_start_offset.lerp(_map_target_offset, _move_alpha)
		_tiles.global_position = continuous_pos.floor()
	else:
		_tiles.global_position = _map_target_offset.floor()
	
	_player_sprite.global_position = _viewport_center.floor()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_viewport_center = get_viewport_rect().size * 0.5
		_reposition_all()


func _get_held_move_delta() -> Vector2i:
	var dx: int = 0
	var dy: int = 0
	if Input.is_physical_key_pressed(KEY_D):
		dx = 1
	elif Input.is_physical_key_pressed(KEY_A):
		dx = -1
	if Input.is_physical_key_pressed(KEY_S):
		dy = 1
	elif Input.is_physical_key_pressed(KEY_W):
		dy = -1
	return Vector2i(dx, dy)


func _setup_player_sprite() -> void:
	_player_sprite.texture = PlaceholderTextureGenerator.create_character_billboard_texture()
	var half_cell_height: float = ObliqueBridgeScript.meters_to_pixels(ObliqueBridgeScript.METERS_PER_CELL * 0.5)
	_player_sprite.centered = true
	_player_sprite.offset = Vector2(0.0, -round(half_cell_height))
	_player_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST


func _update_dynamic_world(center_x: int, center_y: int) -> void:
	var solid_texture_map: Dictionary = ObliqueBridgeScript.build_solid_terrain_texture_map()
	var color_map: Dictionary = ObliqueBridgeScript.build_solid_terrain_color_map()
	var noise_mask: Texture2D = TerrainTileTexturesScript.create_seamless_noise_mask_texture()
	
	var min_x: int = center_x - GRID_PATCH_RADIUS
	var max_x: int = center_x + GRID_PATCH_RADIUS
	var min_y: int = center_y - GRID_PATCH_RADIUS
	var max_y: int = center_y + GRID_PATCH_RADIUS

	for gx in range(min_x, max_x + 1):
		for gy in range(min_y, max_y + 1):
			var tile_key: String = str(gx) + "," + str(gy)
			
			if not _spawned_tiles.has(tile_key):
				_map_generator.GenerateRegion(_grid, gx, gy, 1)
				var spawn_pos: Vector2 = ObliqueBridgeScript.data_to_screen(float(gx), float(gy)).floor()
				
				ObliqueBridgeScript.spawn_cell_visuals(
					_tiles,
					_grid,
					gx,
					gy,
					spawn_pos,
					solid_texture_map,
					color_map,
					noise_mask
				)
				_spawned_tiles[tile_key] = true


func _reposition_all() -> void:
	_player_sprite.global_position = _viewport_center.floor()
	var character = _party.GetSelectedCharacter() if _party != null else null
	if character != null:
		_map_target_offset = _viewport_center - ObliqueBridgeScript.data_to_screen(float(character.X), float(character.Y))
		_tiles.global_position = _map_target_offset.floor()

	for tile: Node in _tiles.get_children():
		if tile is Sprite2D:
			var sprite: Sprite2D = tile as Sprite2D
			if sprite.has_meta("grid_x") and sprite.has_meta("grid_y"):
				var gx: int = sprite.get_meta("grid_x") as int
				var gy: int = sprite.get_meta("grid_y") as int
				sprite.position = ObliqueBridgeScript.data_to_screen(float(gx), float(gy)).floor()