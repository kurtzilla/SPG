extends Node

## Fixed 128×128 exploration mask (white = explored, black = hidden).
## Player must be map-local under WorldCanvas/Tiles (same space as MainSandbox scroll).
## world_cap mapping: map_px -> texel via world_origin_map_px + world_extent_map_px (toroidal).
## GPU mask uses fract(uv_raw - mask_sub_texel_offset); CPU uses posmod texel / _wrap_uv01.
## World radius = fog.reveal_radius_screen_px (map px); screen threshold = radius × zoom.

signal exploration_texture_uploaded

const BUFFER_SIZE: int = 128
const UNSTAMPED: Vector2i = Vector2i(-99999, -99999)

const EXPLORED_COLOR: Color = Color.WHITE
const HIDDEN_COLOR: Color = Color.BLACK

@export_group("Fog of war")
@export var enabled: bool = true
@export var world_origin_map_px: Vector2 = Vector2.ZERO
@export var world_extent_map_px: Vector2 = Vector2(8192.0, 8192.0)

var _reveal_radius_screen_px: float = 60.0
var _reveal_feather_screen_px: float = 16.0

var _image: Image
var _texture: ImageTexture
var _player: Node2D
var _shader_material: ShaderMaterial
var _last_stamp_texel: Vector2i = UNSTAMPED
var _last_stamp_radius_texels: int = -1
var _texture_dirty: bool = false
var _upload_accum: float = 0.0
var _texture_update_hz: float = 10.0
var _player_map_px: Vector2 = Vector2.ZERO
var _mask_sub_texel_offset: Vector2 = Vector2.ZERO
var _reveal_radius_world_px: float = 60.0
var _reveal_feather_world_px: float = 16.0

var _cached_sub_texel: Vector2 = Vector2(-99999.0, -99999.0)
var _cached_reveal_radius_px: float = -1.0
var _cached_reveal_feather_px: float = -1.0


func _ready() -> void:
	_read_fog_settings()
	_image = Image.create(BUFFER_SIZE, BUFFER_SIZE, false, Image.FORMAT_RGBA8)
	_image.fill(HIDDEN_COLOR)
	_texture = ImageTexture.create_from_image(_image)
	if not ViewProjection.view_changed.is_connected(_on_view_changed):
		ViewProjection.view_changed.connect(_on_view_changed)


func _read_fog_settings() -> void:
	if Settings.has("fog.enabled"):
		enabled = Settings.get_bool("fog.enabled")
	if Settings.has("fog.texture_update_hz"):
		_texture_update_hz = maxf(Settings.get_float("fog.texture_update_hz"), 1.0)
	if Settings.has("fog.reveal_radius_screen_px"):
		_reveal_radius_screen_px = maxf(Settings.get_float("fog.reveal_radius_screen_px"), 1.0)
	if Settings.has("fog.reveal_feather_screen_px"):
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
	_last_stamp_texel = UNSTAMPED
	_last_stamp_radius_texels = -1
	_texture_dirty = false
	_upload_accum = 0.0
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

	if not is_equal_approx(_reveal_radius_world_px, _cached_reveal_radius_px):
		material.set_shader_parameter(&"reveal_radius_screen_px", _reveal_radius_world_px)
		_cached_reveal_radius_px = _reveal_radius_world_px

	if not is_equal_approx(_reveal_feather_world_px, _cached_reveal_feather_px):
		material.set_shader_parameter(&"reveal_feather_screen_px", _reveal_feather_world_px)
		_cached_reveal_feather_px = _reveal_feather_world_px


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
	return _rect_has_explored_texel(rect)


func _physics_process(_delta: float) -> void:
	if not enabled or _player == null:
		return

	# position is map-local under WorldCanvas/Tiles (same space as scroll / shader map_local)
	_player_map_px = _player.position
	_update_runtime_derived()
	_try_stamp_exploration()


func _process(delta: float) -> void:
	if _shader_material != null:
		push_runtime_uniforms(_shader_material)

	if not enabled or not _texture_dirty:
		return

	_upload_accum += delta
	var upload_interval: float = 1.0 / _texture_update_hz
	if _upload_accum < upload_interval:
		return

	_upload_accum -= upload_interval
	_texture.update(_image)
	_texture_dirty = false
	exploration_texture_uploaded.emit()


func _on_view_changed() -> void:
	_last_stamp_radius_texels = -1
	_cached_reveal_radius_px = -1.0
	_cached_reveal_feather_px = -1.0
	if _shader_material != null:
		push_runtime_uniforms(_shader_material)


func _update_runtime_derived() -> void:
	_reveal_radius_world_px = get_reveal_radius_map_px()
	_reveal_feather_world_px = get_reveal_feather_map_px()

	var uv: Vector2 = _map_px_to_uv_raw(_player_map_px)
	_mask_sub_texel_offset = Vector2(
		uv.x - floor(uv.x * float(BUFFER_SIZE)) / float(BUFFER_SIZE),
		uv.y - floor(uv.y * float(BUFFER_SIZE)) / float(BUFFER_SIZE)
	)


func _bootstrap_exploration_at_player() -> void:
	if not enabled or _player == null:
		return
	_player_map_px = _player.position
	_update_runtime_derived()
	_last_stamp_texel = UNSTAMPED
	_last_stamp_radius_texels = -1
	_try_stamp_exploration()


func _try_stamp_exploration() -> void:
	var texel: Vector2i = _map_px_to_texel(_player_map_px)
	var radius_texels: int = _reveal_radius_texels()
	if texel == _last_stamp_texel and radius_texels == _last_stamp_radius_texels:
		return

	_stamp_disc_texels(texel, radius_texels)
	_last_stamp_texel = texel
	_last_stamp_radius_texels = radius_texels
	_texture_dirty = true


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


func _rect_has_explored_texel(rect: Rect2) -> bool:
	var uv_min: Vector2 = _map_px_to_uv_raw(rect.position)
	var uv_max: Vector2 = _map_px_to_uv_raw(rect.position + rect.size)

	var tx0: int = int(floor(uv_min.x * float(BUFFER_SIZE)))
	var ty0: int = int(floor(uv_min.y * float(BUFFER_SIZE)))
	var tx1: int = int(floor(uv_max.x * float(BUFFER_SIZE)))
	var ty1: int = int(floor(uv_max.y * float(BUFFER_SIZE)))

	return _texel_range_has_explored(tx0, ty0, tx1, ty1)


func _texel_range_has_explored(tx0: int, ty0: int, tx1: int, ty1: int) -> bool:
	var x_segments: Array[Vector2i] = []
	if tx0 <= tx1:
		x_segments.append(Vector2i(tx0, tx1))
	else:
		x_segments.append(Vector2i(tx0, BUFFER_SIZE - 1))
		x_segments.append(Vector2i(0, tx1))

	var y_segments: Array[Vector2i] = []
	if ty0 <= ty1:
		y_segments.append(Vector2i(ty0, ty1))
	else:
		y_segments.append(Vector2i(ty0, BUFFER_SIZE - 1))
		y_segments.append(Vector2i(0, ty1))

	for y_seg: Vector2i in y_segments:
		for x_seg: Vector2i in x_segments:
			for y: int in range(y_seg.x, y_seg.y + 1):
				for x: int in range(x_seg.x, x_seg.y + 1):
					if _explored_texel_at_unwrapped(x, y):
						return true
	return false


func _explored_texel_at_unwrapped(tx: int, ty: int) -> bool:
	return _image.get_pixel(posmod(tx, BUFFER_SIZE), posmod(ty, BUFFER_SIZE)).r > 0.5


func _map_px_to_uv_raw(map_px: Vector2) -> Vector2:
	var extent_x: float = maxf(world_extent_map_px.x, 1.0)
	var extent_y: float = maxf(world_extent_map_px.y, 1.0)
	var rel: Vector2 = map_px - world_origin_map_px
	return Vector2(rel.x / extent_x, rel.y / extent_y)


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


func _stamp_disc_texels(center: Vector2i, radius: int) -> void:
	var r_sq: int = radius * radius
	for dy: int in range(-radius, radius + 1):
		for dx: int in range(-radius, radius + 1):
			if dx * dx + dy * dy > r_sq:
				continue
			_image.set_pixel(
				posmod(center.x + dx, BUFFER_SIZE),
				posmod(center.y + dy, BUFFER_SIZE),
				EXPLORED_COLOR
			)
