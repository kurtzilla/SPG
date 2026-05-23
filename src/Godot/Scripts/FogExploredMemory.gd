class_name FogExploredMemory
extends RefCounted

## Low-res explored mask (0 = clear, 255 = hidden). Stamps on dirty rects only.

const HIDDEN_BYTE: int = 255
const CLEAR_BYTE: int = 0

var _image: Image
var _texture: ImageTexture
var _buffer: PackedByteArray = PackedByteArray()
var _origin_world_m: Vector2 = Vector2.ZERO
var _meters_per_texel: float = 2.0


func configure(origin_world_m: Vector2, meters_per_texel: float, texel_dims: Vector2i) -> void:
	_origin_world_m = origin_world_m
	_meters_per_texel = maxf(meters_per_texel, 0.5)
	_alloc(texel_dims)


func get_texture() -> ImageTexture:
	return _texture


func get_origin_world_m() -> Vector2:
	return _origin_world_m


func set_origin_world_m(origin: Vector2) -> void:
	_origin_world_m = origin


func get_texel_dims() -> Vector2i:
	if _image == null:
		return Vector2i.ZERO
	return Vector2i(_image.get_width(), _image.get_height())


func is_clear_at_cell(gx: int, gy: int) -> bool:
	return is_clear_at_world(RevealMath.cell_center_world_m(gx, gy))


func is_cell_explored(gx: int, gy: int) -> bool:
	var gx_f: float = float(gx)
	var gy_f: float = float(gy)
	var samples: Array[Vector2] = [
		RevealMath.cell_center_world_m(gx, gy),
		ViewTransforms.grid_to_world_m(gx_f, gy_f),
		ViewTransforms.grid_to_world_m(gx_f + 1.0, gy_f),
		ViewTransforms.grid_to_world_m(gx_f, gy_f + 1.0),
		ViewTransforms.grid_to_world_m(gx_f + 1.0, gy_f + 1.0),
	]
	for world_m: Vector2 in samples:
		if is_clear_at_world(world_m):
			return true
	return false


func is_clear_at_world(world_m: Vector2) -> bool:
	return get_hidden_at_world(world_m) < 0.5


func get_hidden_at_world(world_m: Vector2) -> float:
	if _image == null or _buffer.is_empty():
		return 1.0
	var uv: Vector2 = world_to_uv(world_m)
	if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
		return 1.0
	var dims: Vector2i = get_texel_dims()
	var fx: float = uv.x * float(dims.x) - 0.5
	var fy: float = uv.y * float(dims.y) - 0.5
	var tx0: int = clampi(int(floor(fx)), 0, dims.x - 1)
	var ty0: int = clampi(int(floor(fy)), 0, dims.y - 1)
	var tx1: int = mini(tx0 + 1, dims.x - 1)
	var ty1: int = mini(ty0 + 1, dims.y - 1)
	var sx: float = fx - floor(fx)
	var sy: float = fy - floor(fy)
	var v00: float = float(_buffer[ty0 * dims.x + tx0]) / 255.0
	var v10: float = float(_buffer[ty0 * dims.x + tx1]) / 255.0
	var v01: float = float(_buffer[ty1 * dims.x + tx0]) / 255.0
	var v11: float = float(_buffer[ty1 * dims.x + tx1]) / 255.0
	return lerpf(lerpf(v00, v10, sx), lerpf(v01, v11, sx), sy)


func world_to_uv(world_m: Vector2) -> Vector2:
	var size_m: Vector2 = Vector2(
		float(get_texel_dims().x) * _meters_per_texel,
		float(get_texel_dims().y) * _meters_per_texel
	)
	return ViewTransforms.world_m_to_normalized_rect(world_m, _origin_world_m, size_m)


func fill_hidden() -> void:
	if _buffer.is_empty():
		return
	_buffer.fill(HIDDEN_BYTE)
	_push_to_gpu()


func scroll_from(old_origin: Vector2, old_buffer: PackedByteArray, old_dims: Vector2i) -> void:
	if _image == null or old_buffer.size() != old_dims.x * old_dims.y:
		return
	var tex_w: int = _image.get_width()
	var tex_h: int = _image.get_height()
	var scrolled: PackedByteArray = PackedByteArray()
	scrolled.resize(tex_w * tex_h)
	scrolled.fill(HIDDEN_BYTE)
	var mpt: float = _meters_per_texel

	for ty in range(tex_h):
		var wy: float = _origin_world_m.y + (float(ty) + 0.5) * mpt
		for tx in range(tex_w):
			var wx: float = _origin_world_m.x + (float(tx) + 0.5) * mpt
			var otx: int = int(floor((wx - old_origin.x) / mpt - 0.5))
			var oty: int = int(floor((wy - old_origin.y) / mpt - 0.5))
			if otx < 0 or otx >= old_dims.x or oty < 0 or oty >= old_dims.y:
				continue
			scrolled[ty * tex_w + tx] = old_buffer[oty * old_dims.x + otx]

	_buffer = scrolled
	_push_to_gpu()


func stamp_disc(world_center: Vector2, radius_m: float) -> void:
	# Pad by half a texel so coarse masks still cover the movement disc.
	var padded: float = radius_m + _meters_per_texel * 0.5
	_stamp_circle_aa(world_center.x, world_center.y, padded)


func stamp_capsule(from_world: Vector2, to_world: Vector2, radius_m: float) -> void:
	if _image == null or radius_m <= 0.0:
		return
	if from_world.distance_squared_to(to_world) < 0.0001:
		return
	var mpt: float = _meters_per_texel
	var tex_w: int = _image.get_width()
	var tex_h: int = _image.get_height()
	var half_tex: float = mpt * 0.5
	var expand: float = radius_m + half_tex + _meters_per_texel * 0.5

	var min_x: float = minf(from_world.x, to_world.x) - expand
	var max_x: float = maxf(from_world.x, to_world.x) + expand
	var min_y: float = minf(from_world.y, to_world.y) - expand
	var max_y: float = maxf(from_world.y, to_world.y) + expand

	var min_tx: int = clampi(int(floor((min_x - _origin_world_m.x) / mpt)), 0, tex_w - 1)
	var max_tx: int = clampi(int(ceil((max_x - _origin_world_m.x) / mpt)), 0, tex_w - 1)
	var min_ty: int = clampi(int(floor((min_y - _origin_world_m.y) / mpt)), 0, tex_h - 1)
	var max_ty: int = clampi(int(ceil((max_y - _origin_world_m.y) / mpt)), 0, tex_h - 1)

	for ty in range(min_ty, max_ty + 1):
		var wy: float = _origin_world_m.y + (float(ty) + 0.5) * mpt
		var p: Vector2 = Vector2(0.0, wy)
		for tx in range(min_tx, max_tx + 1):
			p.x = _origin_world_m.x + (float(tx) + 0.5) * mpt
			_apply_clear_at_distance(p, _dist_point_to_segment(p, from_world, to_world), radius_m, half_tex, tx, ty)

	_push_to_gpu()


func take_buffer_snapshot() -> Dictionary:
	return {
		"buffer": _buffer.duplicate(),
		"dims": get_texel_dims(),
		"origin": _origin_world_m,
	}


func _alloc(dims: Vector2i) -> void:
	var w: int = maxi(dims.x, 1)
	var h: int = maxi(dims.y, 1)
	_image = Image.create(w, h, false, Image.FORMAT_R8)
	_buffer.resize(w * h)
	_buffer.fill(HIDDEN_BYTE)
	if _texture == null:
		_texture = ImageTexture.create_from_image(_image)
	else:
		_push_to_gpu()


func _push_to_gpu() -> void:
	if _image == null:
		return
	var dims: Vector2i = get_texel_dims()
	_image.set_data(dims.x, dims.y, false, Image.FORMAT_R8, _buffer)
	_texture.update(_image)


func _write_clear_byte(tex_w: int, tx: int, ty: int, clear_byte: int) -> void:
	var idx: int = ty * tex_w + tx
	_buffer[idx] = mini(_buffer[idx], clear_byte)


func _stamp_circle_aa(cx: float, cy: float, radius_m: float) -> void:
	if _image == null or radius_m <= 0.0:
		return
	var mpt: float = _meters_per_texel
	var tex_w: int = _image.get_width()
	var tex_h: int = _image.get_height()
	var half_tex: float = mpt * 0.5

	var min_tx: int = clampi(int(floor((cx - radius_m - _origin_world_m.x) / mpt)), 0, tex_w - 1)
	var max_tx: int = clampi(int(ceil((cx + radius_m - _origin_world_m.x) / mpt)), 0, tex_w - 1)
	var min_ty: int = clampi(int(floor((cy - radius_m - _origin_world_m.y) / mpt)), 0, tex_h - 1)
	var max_ty: int = clampi(int(ceil((cy + radius_m - _origin_world_m.y) / mpt)), 0, tex_h - 1)

	for ty in range(min_ty, max_ty + 1):
		var wy: float = _origin_world_m.y + (float(ty) + 0.5) * mpt
		for tx in range(min_tx, max_tx + 1):
			var wx: float = _origin_world_m.x + (float(tx) + 0.5) * mpt
			_apply_clear_at_distance(
				Vector2(wx, wy),
				Vector2(wx - cx, wy - cy).length(),
				radius_m,
				half_tex,
				tx,
				ty
			)

	_push_to_gpu()


func _apply_clear_at_distance(
	_world_pos: Vector2,
	dist: float,
	radius_m: float,
	half_tex: float,
	tx: int,
	ty: int
) -> void:
	var clear_byte: int
	if dist <= radius_m - half_tex:
		clear_byte = CLEAR_BYTE
	elif dist >= radius_m + half_tex:
		return
	else:
		var t: float = (radius_m + half_tex - dist) / (2.0 * half_tex)
		clear_byte = int(255.0 * (1.0 - clampf(t, 0.0, 1.0)))
	_write_clear_byte(_image.get_width(), tx, ty, clear_byte)


func _dist_point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var len_sq: float = ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)
