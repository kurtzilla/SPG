extends Node2D

## Debug fog boundary drawn on CanvasLayer 3 (morphs with explored trail + live edge).

const ViewTransforms = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const FogOverlayScript = preload("res://src/Godot/Scripts/FogOverlay.gd")
const FogCoverEvalScript = preload("res://src/Godot/Scripts/FogCoverEval.gd")

const RING_COLOR: Color = Color(1.0, 0.45, 0.1, 0.95)
const RING_WIDTH_PX: float = 2.5
const RING_SEGMENTS: int = 96
const ISO_COVER: float = 0.5
const MAX_GRID_SAMPLES: int = 64

var _map_scroll: Node2D
var _center_x: int = 0
var _center_y: int = 0
var _player_world_m: Vector2 = Vector2.ZERO
var _sight_radius_m: float = 0.0
var _feather_m: float = 0.0
var _mask_origin_world_m: Vector2 = Vector2.ZERO
var _mask_world_size: Vector2 = Vector2.ZERO
var _explored_memory = null
var _show_ring: bool = false
var _chains: Array[PackedVector2Array] = []
var _last_fog_version: int = -1
var _last_map_scroll_pos: Vector2 = Vector2.INF


func sync_from_fog(fog_overlay: Node2D, map_scroll: Node2D) -> void:
	_map_scroll = map_scroll
	if fog_overlay == null or not is_instance_valid(fog_overlay):
		_show_ring = false
		_chains.clear()
		queue_redraw()
		return

	_show_ring = (
		FogOverlayScript.DEBUG_REVEAL_BORDER
		and fog_overlay.visible
		and fog_overlay.has_method("get_live_radius_m")
		and fog_overlay.get_live_radius_m() > 0.0
	)
	if not _show_ring:
		_chains.clear()
		queue_redraw()
		return

	if fog_overlay.has_method("get_center_cell"):
		var cell: Vector2i = fog_overlay.get_center_cell()
		_center_x = cell.x
		_center_y = cell.y
	_player_world_m = fog_overlay.get_player_world_m()
	_sight_radius_m = fog_overlay.get_live_radius_m()
	_feather_m = fog_overlay.get_feather_m() if fog_overlay.has_method("get_feather_m") else 0.0
	_mask_origin_world_m = fog_overlay.get_mask_origin_world_m()
	_mask_world_size = fog_overlay.get_mask_world_size()
	_explored_memory = fog_overlay.get_explored_memory()

	var fog_version: int = (
		fog_overlay.get_fog_stamp_version()
		if fog_overlay.has_method("get_fog_stamp_version")
		else -1
	)
	var scroll_pos: Vector2 = map_scroll.global_position if map_scroll != null else Vector2.ZERO
	var needs_rebuild: bool = (
		fog_version != _last_fog_version
		or scroll_pos != _last_map_scroll_pos
	)
	if needs_rebuild:
		_chains = _build_chains()
		_last_fog_version = fog_version
		_last_map_scroll_pos = scroll_pos
	queue_redraw()


func _draw() -> void:
	if not _show_ring or _map_scroll == null or _sight_radius_m <= 0.0:
		return

	if _chains.is_empty():
		_draw_fallback_arc()
		return

	var ctx: ViewContext = _view_context()
	for chain in _chains:
		if chain.size() < 2:
			continue
		var local_points := PackedVector2Array()
		local_points.resize(chain.size())
		for i in chain.size():
			local_points[i] = ViewTransforms.world_m_to_overlay_local(chain[i], ctx, self)
		draw_polyline(local_points, RING_COLOR, RING_WIDTH_PX, true)


func _draw_fallback_arc() -> void:
	var ctx: ViewContext = _view_context()
	var draw_center: Vector2 = ViewTransforms.grid_to_overlay_local(
		float(_center_x),
		float(_center_y),
		ctx,
		self
	)
	var radius_px: float = (
		_sight_radius_m / ViewTransforms.METERS_PER_CELL
		* float(ViewTransforms.CELL_SIZE_PX)
		* maxf(ctx.zoom, 0.01)
	)
	draw_arc(draw_center, radius_px, 0.0, TAU, RING_SEGMENTS, RING_COLOR, RING_WIDTH_PX, true)


func _view_context() -> ViewContext:
	return ViewContext.from_viewport(_map_scroll, get_viewport(), ViewProjection.zoom)


func _cover_at(world_m: Vector2) -> float:
	return FogCoverEvalScript.cover_at_world(
		world_m,
		_player_world_m,
		_sight_radius_m,
		_feather_m,
		_explored_memory,
		_mask_origin_world_m,
		_mask_world_size
	)


func _build_chains() -> Array[PackedVector2Array]:
	if _mask_world_size.x <= 0.0 or _mask_world_size.y <= 0.0:
		return []

	var mpt: float = maxf(
		_mask_world_size.x / float(MAX_GRID_SAMPLES),
		_mask_world_size.y / float(MAX_GRID_SAMPLES)
	)
	var cols: int = clampi(int(ceil(_mask_world_size.x / mpt)) + 1, 2, MAX_GRID_SAMPLES + 1)
	var rows: int = clampi(int(ceil(_mask_world_size.y / mpt)) + 1, 2, MAX_GRID_SAMPLES + 1)
	var step_x: float = _mask_world_size.x / float(cols - 1)
	var step_y: float = _mask_world_size.y / float(rows - 1)

	var covers := PackedFloat32Array()
	covers.resize(cols * rows)
	for row in range(rows):
		for col in range(cols):
			var world_m: Vector2 = _mask_origin_world_m + Vector2(
				float(col) * step_x,
				float(row) * step_y
			)
			covers[row * cols + col] = _cover_at(world_m)

	# Collect raw segments from marching squares
	var seg_starts := PackedVector2Array()
	var seg_ends := PackedVector2Array()
	for row in range(rows - 1):
		for col in range(cols - 1):
			var x0: float = _mask_origin_world_m.x + float(col) * step_x
			var y0: float = _mask_origin_world_m.y + float(row) * step_y
			var x1: float = x0 + step_x
			var y1: float = y0 + step_y

			var tl: float = covers[row * cols + col]
			var tr: float = covers[row * cols + col + 1]
			var bl: float = covers[(row + 1) * cols + col]
			var br: float = covers[(row + 1) * cols + col + 1]

			var case_idx: int = 0
			if tl >= ISO_COVER:
				case_idx |= 1
			if tr >= ISO_COVER:
				case_idx |= 2
			if br >= ISO_COVER:
				case_idx |= 4
			if bl >= ISO_COVER:
				case_idx |= 8

			if case_idx == 0 or case_idx == 15:
				continue

			var p_tl := Vector2(x0, y0)
			var p_tr := Vector2(x1, y0)
			var p_bl := Vector2(x0, y1)
			var p_br := Vector2(x1, y1)
			var top: Vector2 = _edge_cross(p_tl, tl, p_tr, tr)
			var right: Vector2 = _edge_cross(p_tr, tr, p_br, br)
			var bottom: Vector2 = _edge_cross(p_bl, bl, p_br, br)
			var left: Vector2 = _edge_cross(p_tl, tl, p_bl, bl)

			match case_idx:
				1, 14:
					seg_starts.append(left); seg_ends.append(top)
				2, 13:
					seg_starts.append(top); seg_ends.append(right)
				3, 12:
					seg_starts.append(left); seg_ends.append(right)
				4, 11:
					seg_starts.append(right); seg_ends.append(bottom)
				5:
					seg_starts.append(left); seg_ends.append(top)
					seg_starts.append(right); seg_ends.append(bottom)
				6, 9:
					seg_starts.append(top); seg_ends.append(bottom)
				7, 8:
					seg_starts.append(left); seg_ends.append(bottom)
				10:
					seg_starts.append(top); seg_ends.append(right)
					seg_starts.append(left); seg_ends.append(bottom)

	return _chain_segments(seg_starts, seg_ends, step_x, step_y)


func _chain_segments(
	seg_starts: PackedVector2Array,
	seg_ends: PackedVector2Array,
	step_x: float,
	step_y: float
) -> Array[PackedVector2Array]:
	var count: int = seg_starts.size()
	if count == 0:
		return []

	# Spatial hash: quantize endpoints to half-step grid for O(1) lookup
	var quant: float = minf(step_x, step_y) * 0.25
	var inv_quant: float = 1.0 / maxf(quant, 0.0001)

	# endpoint_map: hash → array of [segment_index, is_end_point (0=start, 1=end)]
	var endpoint_map: Dictionary = {}
	for i in range(count):
		var ks: int = _point_hash(seg_starts[i], inv_quant)
		var ke: int = _point_hash(seg_ends[i], inv_quant)
		if not endpoint_map.has(ks):
			endpoint_map[ks] = []
		endpoint_map[ks].append(Vector2i(i, 0))
		if not endpoint_map.has(ke):
			endpoint_map[ke] = []
		endpoint_map[ke].append(Vector2i(i, 1))

	var used := PackedByteArray()
	used.resize(count)
	used.fill(0)
	var chains: Array[PackedVector2Array] = []

	for start_idx in range(count):
		if used[start_idx]:
			continue
		used[start_idx] = 1
		var chain := PackedVector2Array()
		chain.append(seg_starts[start_idx])
		chain.append(seg_ends[start_idx])

		# Extend forward from chain tail
		var extended := true
		while extended:
			extended = false
			var tail: Vector2 = chain[-1]
			var hk: int = _point_hash(tail, inv_quant)
			if endpoint_map.has(hk):
				for entry in endpoint_map[hk]:
					var si: int = entry.x
					var ei: int = entry.y
					if used[si]:
						continue
					var candidate: Vector2 = seg_starts[si] if ei == 0 else seg_ends[si]
					if candidate.distance_squared_to(tail) > quant * quant:
						continue
					used[si] = 1
					var other: Vector2 = seg_ends[si] if ei == 0 else seg_starts[si]
					chain.append(other)
					extended = true
					break

		# Extend backward from chain head
		extended = true
		while extended:
			extended = false
			var head: Vector2 = chain[0]
			var hk: int = _point_hash(head, inv_quant)
			if endpoint_map.has(hk):
				for entry in endpoint_map[hk]:
					var si: int = entry.x
					var ei: int = entry.y
					if used[si]:
						continue
					var candidate: Vector2 = seg_starts[si] if ei == 0 else seg_ends[si]
					if candidate.distance_squared_to(head) > quant * quant:
						continue
					used[si] = 1
					var other: Vector2 = seg_ends[si] if ei == 0 else seg_starts[si]
					chain.insert(0, other)
					extended = true
					break

		if chain.size() >= 2:
			chains.append(chain)

	return chains


static func _point_hash(p: Vector2, inv_quant: float) -> int:
	var ix: int = int(round(p.x * inv_quant))
	var iy: int = int(round(p.y * inv_quant))
	return ix * 73856093 ^ iy * 19349663


static func _edge_cross(a: Vector2, cover_a: float, b: Vector2, cover_b: float) -> Vector2:
	var denom: float = cover_b - cover_a
	if absf(denom) < 0.00001:
		return a.lerp(b, 0.5)
	var t: float = clampf((ISO_COVER - cover_a) / denom, 0.0, 1.0)
	return a.lerp(b, t)
