extends Node2D
class_name FogManager

@export var sight_radius_pixels: float = 480.0
@export var feather_width_pixels: float = 120.0
@export var initial_square_diameter_tiles: int = 24
@export var shroud_opacity: float = 0.85
@export var smooth_visual_radius_padding: float = 1.5 # Padding tiles to seamlessly mask the grid pop-in

var _revealed_cells: Dictionary = {}

var _player: Node2D = null
var _player_pixel_position: Vector2 = Vector2.ZERO
var _cell_size: float = 32.0

var _shader_material: ShaderMaterial

# Dynamic History Texture sliding window tracking parameters
var _history_image: Image
var _history_texture: ImageTexture
var _texture_min_bound: Vector2i = Vector2i(99999, 99999)
var _texture_max_bound: Vector2i = Vector2i(-99999, -99999)
var _texture_size: Vector2i = Vector2i.ZERO
var _history_dirty: bool = false

var _last_stamped_cell: Vector2i = Vector2i(-999999, -999999)
var _debug_center_cell: Vector2i = Vector2i.ZERO

const FOG_SHADER: Shader = preload("res://src/Godot/Shaders/FogOverlay.gdshader")

func _ready() -> void:
	z_index = 20
	z_as_relative = true
	set_process(true)
	
	var metrics = load("res://src/Godot/Scripts/ViewMetrics.gd")
	if metrics and "CELL_SIZE_PX" in metrics:
		_cell_size = float(metrics.CELL_SIZE_PX)
		
	_shader_material = ShaderMaterial.new()
	_shader_material.shader = FOG_SHADER
	self.material = _shader_material

func bind_player(player_node: Node2D) -> void:
	if _player and _player.has_signal("map_position_changed"):
		_player.map_position_changed.disconnect(_on_player_position_changed)
		
	_player = player_node
	if _player:
		_player_pixel_position = _player.position
		if _player.has_signal("map_position_changed"):
			_player.map_position_changed.connect(_on_player_position_changed)
		
		var starting_grid = Vector2i(floori(_player_pixel_position.x / _cell_size), floori(_player_pixel_position.y / _cell_size))
		
		# Set an initial baseline padding surrounding the player spawn location
		_texture_min_bound = starting_grid - Vector2i(30, 30)
		_texture_max_bound = starting_grid + Vector2i(30, 30)
		_texture_size = (_texture_max_bound - _texture_min_bound) + Vector2i(1, 1)
		
		_history_image = Image.create(_texture_size.x, _texture_size.y, false, Image.FORMAT_R8)
		_history_image.fill(Color(0, 0, 0, 1))
		_history_texture = ImageTexture.create_from_image(_history_image)
		
		var fill_radius := int(ceili(initial_square_diameter_tiles / 2.0))
		update_fog_around_player(starting_grid, fill_radius)
		
		_update_history_texture()
		_update_shader_uniforms()
		queue_redraw()

func _on_player_position_changed(map_px: Vector2) -> void:
	# Immediately assign the player vector to prevent lookups from trailing behind actual frame state
	_player_pixel_position = map_px

func update_fog_around_player(player_grid_pos: Vector2i, radius: int = -1) -> void:
	var tile_radius := radius
	if tile_radius < 0:
		var active_radius := maxf(sight_radius_pixels, 480.0)
		tile_radius = int(ceili(active_radius / _cell_size))

	var radius_squared := float(tile_radius * tile_radius)
	for dx in range(-tile_radius, tile_radius + 1):
		for dy in range(-tile_radius, tile_radius + 1):
			var cx := float(dx) + 0.5
			var cy := float(dy) + 0.5
			if (cx * cx) + (cy * cy) <= radius_squared:
				_mark_cell_revealed(Vector2i(player_grid_pos.x + dx, player_grid_pos.y + dy))
	_update_history_texture()
	_update_shader_uniforms()
	queue_redraw()

func _mark_cell_revealed(cell: Vector2i) -> void:
	if not _revealed_cells.has(cell):
		_revealed_cells[cell] = true
		_history_dirty = true
		
		# If the player reaches the window boundary edge, expand the tracking window matrix
		if cell.x < _texture_min_bound.x or cell.y < _texture_min_bound.y or cell.x > _texture_max_bound.x or cell.y > _texture_max_bound.y:
			# Apply a generous buffer padding increment to minimize frequent allocations
			_texture_min_bound.x = min(_texture_min_bound.x, cell.x - 30)
			_texture_min_bound.y = min(_texture_min_bound.y, cell.y - 30)
			_texture_max_bound.x = max(_texture_max_bound.x, cell.x + 30)
			_texture_max_bound.y = max(_texture_max_bound.y, cell.y + 30)
			
			_texture_size = (_texture_max_bound - _texture_min_bound) + Vector2i(1, 1)
			_history_image = Image.create(_texture_size.x, _texture_size.y, false, Image.FORMAT_R8)
			_history_image.fill(Color(0, 0, 0, 1))
			
			# Re-map our historical context matrix coordinates onto the fresh texture canvas array
			for old_cell in _revealed_cells:
				var local_pos = old_cell - _texture_min_bound
				if local_pos.x >= 0 and local_pos.x < _texture_size.x and local_pos.y >= 0 and local_pos.y < _texture_size.y:
					_history_image.set_pixel(local_pos.x, local_pos.y, Color(1, 1, 1, 1))
					
			_history_texture = ImageTexture.create_from_image(_history_image)
		else:
			# Direct single pixel update if we remain safely within bounds
			if _history_image:
				var local_pos = cell - _texture_min_bound
				_history_image.set_pixel(local_pos.x, local_pos.y, Color(1, 1, 1, 1))

func shroud_new_chunk_region(_chunk_coord: Vector2i, _chunk_size: int) -> void:
	_history_dirty = true
	queue_redraw()

func _process(_delta: float) -> void:
	# Hot path: frame-rate GPU presentation (sub-pixel)
	if is_instance_valid(_player):
		_player_pixel_position = _player.position

	if _shader_material:
		_shader_material.set_shader_parameter("player_pixel_pos", _player_pixel_position)

		var active_radius := maxf(sight_radius_pixels, 480.0)
		var reveal_radius_tiles := int(ceili(active_radius / _cell_size))
		var visual_radius := (reveal_radius_tiles + smooth_visual_radius_padding) * _cell_size
		_shader_material.set_shader_parameter("realtime_radius", visual_radius)

	# Cold path: discrete cell-cross stamping (unchanged)
	var current_cell := Vector2i(
		floori(_player_pixel_position.x / _cell_size),
		floori(_player_pixel_position.y / _cell_size)
	)
	if current_cell != _last_stamped_cell:
		_last_stamped_cell = current_cell
		_debug_center_cell = current_cell
		var active_radius := maxf(sight_radius_pixels, 480.0)
		var reveal_radius_tiles := int(ceili(active_radius / _cell_size))
		update_fog_around_player(current_cell, reveal_radius_tiles)
		queue_redraw()

func _update_history_texture() -> void:
	if not _history_dirty: return
	if not _history_texture or not _history_image: return
	
	_history_texture.update(_history_image)
	_shader_material.set_shader_parameter("history_texture", _history_texture)
	_shader_material.set_shader_parameter("map_texture_origin_tiles", Vector2(_texture_min_bound))
	_shader_material.set_shader_parameter("map_texture_size_tiles", Vector2(_texture_size))
	_history_dirty = false

func _update_shader_uniforms() -> void:
	if not _shader_material: return
	
	var active_radius = max(sight_radius_pixels, 480.0)
	var active_feather = max(feather_width_pixels, 120.0)
	
	_shader_material.set_shader_parameter("player_pixel_pos", _player_pixel_position)
	_shader_material.set_shader_parameter("sight_radius", active_radius)
	_shader_material.set_shader_parameter("feather_width", active_feather)
	_shader_material.set_shader_parameter("realtime_feather_px", maxf(feather_width_pixels, _cell_size * 0.5))
	_shader_material.set_shader_parameter("cell_size", _cell_size)
	_shader_material.set_shader_parameter("shroud_opacity", shroud_opacity)

func _draw() -> void:
	var transform_inverse = get_canvas_transform().affine_inverse()
	var viewport_dimensions = get_viewport_rect()
	
	var world_top_left = transform_inverse * viewport_dimensions.position
	var world_bottom_right = transform_inverse * (viewport_dimensions.position + viewport_dimensions.size)
	
	var view_w = world_bottom_right.x - world_top_left.x
	var view_h = world_bottom_right.y - world_top_left.y
	
	# Massive 16x canvas safety factor ensures the shroud completely covers the window even at ultra-deep zoom outs
	var adaptive_render_rect = Rect2(
		world_top_left.x - view_w * 7.5,
		world_top_left.y - view_h * 7.5,
		view_w * 16.0,
		view_h * 16.0
	)
	
	draw_rect(adaptive_render_rect, Color.WHITE, true)

	if OS.is_debug_build():
		var cell_world_origin := Vector2(
			_debug_center_cell.x * _cell_size,
			_debug_center_cell.y * _cell_size
		)
		draw_rect(Rect2(cell_world_origin, Vector2(_cell_size, _cell_size)), Color(1, 1, 0, 0.4), true)
