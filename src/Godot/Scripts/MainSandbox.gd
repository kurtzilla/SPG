extends Node2D

const GridModel = preload("res://src/Core/Models/GridModel.gd")
const CharacterModel = preload("res://src/Core/Models/CharacterModel.gd")
const PartyModel = preload("res://src/Core/Models/PartyModel.gd")
const ObliqueBridge = preload("res://src/Godot/Scripts/ObliqueBridge.gd")
const PlaceholderTextureGenerator = preload("res://src/Godot/Assets/PlaceholderTextureGenerator.gd")

const GRID_PATCH_RADIUS: int = 5
const MOVE_LERP_WEIGHT: float = 10.0
const MOVE_REPEAT_INTERVAL: float = 0.12

@onready var _tiles: Node2D = $Tiles
@onready var _player_sprite: Sprite2D = $Characters/PlayerSprite

var _grid: GridModel
var _party: PartyModel
var _viewport_center: Vector2 = Vector2.ZERO
var _move_repeat_timer: float = 0.0


func _ready() -> void:
	_grid = GridModel.new()
	_party = PartyModel.new()
	var player: CharacterModel = CharacterModel.new("player", "Player", 0, 0)
	_party.add_character(player)

	_viewport_center = get_viewport_rect().size * 0.5
	_setup_player_sprite()
	_spawn_tile_patch()
	_player_sprite.global_position = _world_screen_pos(player.x, player.y)


func _process(delta: float) -> void:
	var character: CharacterModel = _party.get_selected_character() as CharacterModel
	if character == null:
		return

	var move_delta: Vector2i = _get_held_move_delta()
	if move_delta != Vector2i.ZERO:
		_move_repeat_timer -= delta
		if _move_repeat_timer <= 0.0:
			character.move_relative(move_delta.x, move_delta.y)
			_move_repeat_timer = MOVE_REPEAT_INTERVAL
	else:
		_move_repeat_timer = 0.0

	var target: Vector2 = _world_screen_pos(character.x, character.y)
	_player_sprite.global_position = _player_sprite.global_position.lerp(
		target,
		MOVE_LERP_WEIGHT * delta
	)


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
	_player_sprite.centered = true
	_player_sprite.offset = Vector2(
		0.0,
		-ObliqueBridge.meters_to_pixels(ObliqueBridge.METERS_PER_CELL * 0.25)
	)


func _spawn_tile_patch() -> void:
	var ground_texture: Texture2D = PlaceholderTextureGenerator.create_ground_tile_texture()
	var min_coord: int = -GRID_PATCH_RADIUS
	var max_coord: int = GRID_PATCH_RADIUS - 1

	for gx in range(min_coord, max_coord + 1):
		for gy in range(min_coord, max_coord + 1):
			var tile: Sprite2D = Sprite2D.new()
			tile.texture = ground_texture
			tile.centered = true
			tile.global_position = _world_screen_pos(gx, gy)
			if _grid.get_cell_state(gx, gy) == GridModel.CellState.BLOCKED:
				tile.modulate = Color(0.45, 0.45, 0.45)
			tile.set_meta("grid_x", gx)
			tile.set_meta("grid_y", gy)
			_tiles.add_child(tile)


func _world_screen_pos(gx: int, gy: int) -> Vector2:
	return _viewport_center + ObliqueBridge.data_to_screen(gx, gy)


func _reposition_all() -> void:
	for tile: Node in _tiles.get_children():
		if tile is Sprite2D:
			var sprite: Sprite2D = tile as Sprite2D
			if sprite.has_meta("grid_x") and sprite.has_meta("grid_y"):
				var gx: int = sprite.get_meta("grid_x") as int
				var gy: int = sprite.get_meta("grid_y") as int
				sprite.global_position = _world_screen_pos(gx, gy)
