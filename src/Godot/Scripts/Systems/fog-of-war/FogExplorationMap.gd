extends Node

## Fixed 128×128 exploration mask (white = explored, black = hidden).
## Player must be map-local under WorldCanvas/Tiles (same space as MainSandbox scroll).
## world_cap mapping: map_px -> texel via world_origin_map_px + world_extent_map_px (toroidal).
## GPU/CPU explored UV: world-absolute via world_origin_map_px (toroidal fract). Live circle stays player-centered.
## World radius = fog.reveal_radius_screen_px (map px); screen threshold = radius × zoom.

signal exploration_texture_uploaded
signal exploration_stamped

const BUFFER_SIZE: int = 128
const UNSTAMPED_PLAYER_PX: Vector2 = Vector2(-99999.0, -99999.0)
const STAMP_MOVE_THRESHOLD_SQ: float = 0.25

const EXPLORED_COLOR: Color = Color.WHITE
const HIDDEN_COLOR: Color = Color.BLACK

@export_group("Fog of war")
@export var enabled: bool = true
@export var world_origin_map_px: Vector2 = Vector2.ZERO
@export var world_extent_map_px: Vector2 = Vector2(8192.0, 8192.0)

var _reveal_radius_screen_px: float = 768.0
var _reveal_feather_screen_px: float = 256.0

var _image: Image
var _texture: ImageTexture
var _player: Node2D
var _shader_material: ShaderMaterial
var _last_stamp_player_map_px: Vector2 = UNSTAMPED_PLAYER_PX
var _last_stamp_radius_texels: int = -1
var _texture_dirty: bool = false
var _texture_update_hz: float = 10.0
var _player_map_px: Vector2 = Vector2.ZERO
var _mask_sub_texel_offset: Vector2 = Vector2.ZERO
var _reveal_radius_world_px: float = 768.0
var _reveal_feather_world_px: float = 256.0

var _cached_sub_texel: Vector2 = Vector2(-99999.0, -99999.0)
var _explored_chunks: Dictionary = {}
var _chunk_size_cells: int = 32


func _ready() -> void:
	_read_fog_settings()
	_chunk_size_cells = Settings.get_int("world.chunk_size")
	_image = Image.create(BUFFER_SIZE, BUFFER_SIZE, false, Image.FORMAT_RGBA8)
	_image.fill(HIDDEN_COLOR)
	_texture = ImageTexture.create_from_image(_image)


func _read_fog_settings() -> void:
	if Settings.has("fog.enabled"):
		enabled = Settings.get_bool("fog.enabled")
	if Settings.has("fog.texture_update_hz"):
		_texture_update_hz = maxf(Settings.get_float("fog.texture_update_hz"), 1.0)
	var cell_px: float = float(ViewMetrics.CELL_SIZE_PX)
	if Settings.has("fog.reveal_radius_cells"):
		_reveal_radius_screen_px = maxf(Settings.get_float("fog.reveal_radius_cells"), 1.0) * cell_px
	elif Settings.has("fog.reveal_radius_screen_px"):
		_reveal_radius_screen_px = maxf(Settings.get_float("fog.reveal_radius_screen_px"), 1.0)
	if Settings.has("fog.reveal_feather_cells"):
		_reveal_feather_screen_px = maxf(Settings.get_float("fog.reveal_feather_cells"), 0.0) * cell_px
	elif Settings.has("fog.reveal_feather_screen_px"):
		_reveal_feather_screen_px = maxf(Settings.get_float("fog.reveal_feather_screen_px"), 0.0)
	if Settings.has("fog.world_extent_x") and Settings.has("fog.world_extent_y"):
		world_extent_map_px = Vector2(
			maxf(Settings.get_float("fog.world_extent_x"), 1.0),
			maxf(Settings.get_float("fog.world_extent_y"), 1.0)
		)


func get_reveal_radius_map_px() -> float:
	return _reveal_radius_screen_px


func get_reveal_feather_map_px() -> float:
	return _reveal_feather_screen_px


func configure_world_anchor(anchor_map_px: Vector2) -> void:
	world_origin_map_px = anchor_map_px
	if _shader_material != null:
		_apply_static_shader_uniforms(_shader_material)


func setup(player: Node2D) -> void:
	_player = player
	_explored_chunks.clear()
	_image.fill(HIDDEN_COLOR)
	_last_stamp_player_map_px = UNSTAMPED_PLAYER_PX
	_last_stamp_radius_texels = -1
	_texture_dirty = true
	if _player != null:
		_player_map_px = _player.position
		_update_runtime_derived()
	call_deferred("_bootstrap_exploration_at_player")


func bind_shader_material(material: ShaderMaterial) -> void:
	_shader_material = material
	if material != null:
		_apply_static_shader_uniforms(material)
		sync_shader_uniform(material)


func get_texture() -> ImageTexture:
	return _texture


func get_player_map_px() -> Vector2:
	return _player_map_px


func sync_shader_uniform(material: ShaderMaterial, param_name: StringName = &"explored_mask") -> void:
	if material != null and _texture != null:
		material.set_shader_parameter(param_name, _texture)


func push_runtime_uniforms(material: ShaderMaterial) -> void:
	if material == null or not enabled:
		return

	_update_runtime_derived()

	if _mask_sub_texel_offset != _cached_sub_texel:
		material.set_shader_parameter(&"mask_sub_texel_offset", _mask_sub_texel_offset)
		_cached_sub_texel = _mask_sub_texel_offset


func chunk_map_rect(chunk_coord: Vector2i, chunk_size_cells: int, cell_px: int) -> Rect2:
	var size_px: float = float(chunk_size_cells * cell_px)
	var origin := Vector2(float(chunk_coord.x * chunk_size_cells * cell_px), float(chunk_coord.y * chunk_size_cells * cell_px))
	return Rect2(origin, Vector2(size_px, size_px))


func is_chunk_visible(chunk_coord: Vector2i, chunk_size_cells: int, cell_px: int) -> bool:
	if not enabled:
		return true

	var rect: Rect2 = chunk_map_rect(chunk_coord, chunk_size_cells, cell_px)
	if _rect_intersects_live_disc(rect):
		return true
	return _explored_chunks.has(chunk_coord)


func _process(_delta: float) -> void:
	if not enabled or _player == null:
		return

	# position is map-local under WorldCanvas/Tiles (same space as scroll / shader map_local)
	_player_map_px = _player.position
	_update_runtime_derived()
	_try_stamp_exploration()

	if _shader_material != null:
		push_runtime_uniforms(_shader_material)

	if _texture_dirty:
		_texture.update(_image)
		_texture_dirty = false
		exploration_texture_uploaded.emit()


func _update_runtime_derived() -> void:
	_reveal_radius_world_px = get_reveal_radius_map_px()
	_reveal_feather_world_px = get_reveal_feather_map_px()
	_mask_sub_texel_offset = Vector2.ZERO


func _bootstrap_exploration_at_player() -> void:
	force_stamp_now()


## Force exploration stamp + texture upload (startup / after chunk load).
func force_stamp_now() -> void:
	if not enabled or _player == null:
		return
	_player_map_px = _player.position
	_update_runtime_derived()
	_last_stamp_player_map_px = UNSTAMPED_PLAYER_PX
	_last_stamp_radius_texels = -1
	_try_stamp_exploration()
	if _texture_dirty:
		_texture.update(_image)
		_texture_dirty = false
		exploration_texture_uploaded.emit()


func _try_stamp_exploration() -> void:
	var radius_texels: int = _reveal_radius_texels()
	if _player_map_px.distance_squared_to(_last_stamp_player_map_px) < STAMP_MOVE_THRESHOLD_SQ \
			and radius_texels == _last_stamp_radius_texels:
		return

	_stamp_disc_texels(radius_texels)
	_last_stamp_player_map_px = _player_map_px
	_last_stamp_radius_texels = radius_texels
	_texture_dirty = true
	exploration_stamped.emit()


func _apply_static_shader_uniforms(material: ShaderMaterial) -> void:
	material.set_shader_parameter(&"world_origin_map_px", world_origin_map_px)
	material.set_shader_parameter(&"world_extent_map_px", world_extent_map_px)
	material.set_shader_parameter(&"fog_enabled", enabled)


func _rect_intersects_live_disc(rect: Rect2) -> bool:
	var radius: float = _reveal_radius_world_px + _reveal_feather_world_px
	var r_sq: float = radius * radius
	var center: Vector2 = _player_map_px

	var corners: Array[Vector2] = [
		rect.position,
		rect.position + Vector2(rect.size.x, 0.0),
		rect.position + rect.size,
		rect.position + Vector2(0.0, rect.size.y),
	]
	for corner: Vector2 in corners:
		if center.distance_squared_to(corner) <= r_sq:
			return true

	var closest_x: float = clampf(center.x, rect.position.x, rect.position.x + rect.size.x)
	var closest_y: float = clampf(center.y, rect.position.y, rect.position.y + rect.size.y)
	var closest := Vector2(closest_x, closest_y)
	return center.distance_squared_to(closest) <= r_sq


func _map_px_to_uv_raw(map_px: Vector2) -> Vector2:
	var extent_x: float = maxf(world_extent_map_px.x, 1.0)
	var extent_y: float = maxf(world_extent_map_px.y, 1.0)
	var rel: Vector2 = (map_px - world_origin_map_px) / Vector2(extent_x, extent_y)
	return rel * 1.3333 + Vector2(0.5, 0.5)


func _wrap_uv01(uv: Vector2) -> Vector2:
	return Vector2(uv.x - floor(uv.x), uv.y - floor(uv.y))


func _texel_from_map_px(map_px: Vector2) -> Vector2i:
	var uv: Vector2 = _map_px_to_uv_raw(map_px)
	var tx: int = int(floor(uv.x * float(BUFFER_SIZE)))
	var ty: int = int(floor(uv.y * float(BUFFER_SIZE)))
	return Vector2i(posmod(tx, BUFFER_SIZE), posmod(ty, BUFFER_SIZE))


func _map_px_to_texel(map_px: Vector2) -> Vector2i:
	return _texel_from_map_px(map_px)


func _reveal_radius_texels() -> int:
	var radius_map_px: float = _reveal_radius_world_px
	var texel_w_px: float = maxf(world_extent_map_px.x, 1.0) / float(BUFFER_SIZE)
	var texel_h_px: float = maxf(world_extent_map_px.y, 1.0) / float(BUFFER_SIZE)
	var texel_px: float = (texel_w_px + texel_h_px) * 0.5
	return maxi(1, int(ceil(radius_map_px / texel_px)))


func _stamp_disc_texels(radius: int) -> void:
	# Distance test in map px from the player so the explored disc matches the GPU live circle.
	var center_map_px: Vector2 = _player_map_px
	var r_sq: float = _reveal_radius_world_px * _reveal_radius_world_px
	var texel_w_px: float = maxf(world_extent_map_px.x, 1.0) / float(BUFFER_SIZE)
	var texel_h_px: float = maxf(world_extent_map_px.y, 1.0) / float(BUFFER_SIZE)
	for dy: int in range(-radius, radius + 1):
		for dx: int in range(-radius, radius + 1):
			var sample_map_px: Vector2 = center_map_px + Vector2(
				float(dx) * texel_w_px,
				float(dy) * texel_h_px
			)
			if center_map_px.distance_squared_to(sample_map_px) > r_sq:
				continue
			var stamp_texel: Vector2i = _texel_from_map_px(sample_map_px)
			_image.set_pixel(stamp_texel.x, stamp_texel.y, EXPLORED_COLOR)
	_mark_explored_chunks_for_disc(center_map_px, _reveal_radius_world_px)


func _mark_explored_chunks_for_disc(center_map_px: Vector2, radius_map_px: float) -> void:
	var cell_px: int = ViewMetrics.CELL_SIZE_PX
	var min_px: Vector2 = center_map_px - Vector2(radius_map_px, radius_map_px)
	var max_px: Vector2 = center_map_px + Vector2(radius_map_px, radius_map_px)
	var min_chunk: Vector2i = _map_px_to_chunk_coord(min_px, _chunk_size_cells, cell_px)
	var max_chunk: Vector2i = _map_px_to_chunk_coord(max_px, _chunk_size_cells, cell_px)
	for cy: int in range(min_chunk.y, max_chunk.y + 1):
		for cx: int in range(min_chunk.x, max_chunk.x + 1):
			_explored_chunks[Vector2i(cx, cy)] = true


func _map_px_to_chunk_coord(map_px: Vector2, chunk_size_cells: int, cell_px: int) -> Vector2i:
	var grid_x: int = floori(map_px.x / float(cell_px))
	var grid_y: int = floori(map_px.y / float(cell_px))
	return Vector2i(
		_div_floor(grid_x, chunk_size_cells),
		_div_floor(grid_y, chunk_size_cells)
	)


func _div_floor(a: int, b: int) -> int:
	if b == 0:
		return 0
	if a >= 0:
		return a / b
	return (a - b + 1) / b
