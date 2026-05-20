extends Node2D

const GridModel = preload("res://src/Core/Models/GridModel.gd")
const CharacterModel = preload("res://src/Core/Models/CharacterModel.gd")
const PartyModel = preload("res://src/Core/Models/PartyModel.gd")
const ObliqueBridge = preload("res://src/Godot/Scripts/ObliqueBridge.gd")
const PlaceholderTextureGenerator = preload("res://src/Godot/Assets/PlaceholderTextureGenerator.gd")

const GRID_PATCH_RADIUS: int = 5
const MOVE_TWEEN_DURATION: float = 0.12

@onready var _tiles: Node2D = $Tiles
@onready var _player_sprite: Sprite2D = $Characters/PlayerSprite

var _grid: GridModel
var _party: PartyModel
var _viewport_center: Vector2 = Vector2.ZERO
var _move_tween: Tween


func _ready() -> void:
	_grid = GridModel.new()
	_party = PartyModel.new()
	var player: CharacterModel = CharacterModel.new("player", "Player", 0, 0)
	_party.add_character(player)

	_viewport_center = get_viewport_rect().size * 0.5
	_setup_player_sprite()
	_spawn_tile_patch()
	_sync_character_visual(player, false)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_SIZE_CHANGED:
		_viewport_center = get_viewport_rect().size * 0.5
		_reposition_all()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key_event: InputEventKey = event as InputEventKey
	if not key_event.pressed or key_event.echo:
		return

	var dx: int = 0
	var dy: int = 0
	match key_event.keycode:
		KEY_D, KEY_RIGHT:
			dx = 1
		KEY_A, KEY_LEFT:
			dx = -1
		KEY_S, KEY_DOWN:
			dy = 1
		KEY_W, KEY_UP:
			dy = -1
		_:
			return

	var character: CharacterModel = _party.get_selected_character() as CharacterModel
	if character == null:
		return

	character.move_relative(dx, dy)
	_sync_character_visual(character, true)


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
			tile.position = _tile_screen_position(gx, gy)
			if _grid.get_cell_state(gx, gy) == GridModel.CellState.BLOCKED:
				tile.modulate = Color(0.45, 0.45, 0.45)
			tile.set_meta("grid_x", gx)
			tile.set_meta("grid_y", gy)
			_tiles.add_child(tile)


func _tile_screen_position(gx: int, gy: int) -> Vector2:
	return ObliqueBridge.grid_to_screen_centered(gx, gy, _viewport_center, 0)


func _sync_character_visual(character: CharacterModel, animate: bool) -> void:
	var target: Vector2 = ObliqueBridge.grid_to_screen_centered(
		character.x,
		character.y,
		_viewport_center,
		0
	)

	if _move_tween != null:
		_move_tween.kill()

	if not animate:
		_player_sprite.position = target
		return

	_move_tween = create_tween()
	_move_tween.set_trans(Tween.TRANS_QUAD)
	_move_tween.set_ease(Tween.EASE_OUT)
	_move_tween.tween_property(_player_sprite, "position", target, MOVE_TWEEN_DURATION)


func _reposition_all() -> void:
	for tile: Node in _tiles.get_children():
		if tile is Sprite2D:
			var sprite: Sprite2D = tile as Sprite2D
			if sprite.has_meta("grid_x") and sprite.has_meta("grid_y"):
				var gx: int = sprite.get_meta("grid_x") as int
				var gy: int = sprite.get_meta("grid_y") as int
				sprite.position = _tile_screen_position(gx, gy)

	var character: CharacterModel = _party.get_selected_character() as CharacterModel
	if character != null:
		_sync_character_visual(character, false)
