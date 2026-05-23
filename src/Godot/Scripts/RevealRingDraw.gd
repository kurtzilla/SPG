extends Node2D

## Debug fog boundary drawn on CanvasLayer 3 (morphs with explored trail + live edge).

const ViewTransforms = preload("res://src/Godot/Scripts/ViewTransforms.gd")
const FogOverlayScript = preload("res://src/Godot/Scripts/FogOverlay.gd")
const FogCoverEvalScript = preload("res://src/Godot/Scripts/FogCoverEval.gd")

const RING_COLOR: Color = Color(1.0, 0.45, 0.1, 0.95)
const RING_WIDTH_PX: float = 2.5
const RING_SEGMENTS: int = 96
const ISO_COVER: float = 0.5
const MAX_GRID_SAMPLES: int = 128

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
var _contour_segments: Array[PackedVector2Array] = []


func sync_from_fog(fog_overlay: Sprite2D, map_scroll: Node2D) -> void:
	_map_scroll = map_scroll
	if fog_overlay == null or not is_instance_valid(fog_overlay):
		_show_ring = false
		_contour_segments.clear()
		queue_redraw()
		return

	_show_ring = (
		FogOverlayScript.DEBUG_REVEAL_BORDER
		and fog_overlay.visible
		and fog_overlay.has_method("get_live_radius_m")
		and fog_overlay.get_live_radius_m() > 0.0
	)
	if not _show_ring:
		_contour_segments.clear()
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
	_contour_segments = _build_contour_segments()
	queue_redraw()


func _draw() -> void:
	if not _show_ring or _map_scroll == null or _sight_radius_m <= 0.0:
		return

	if _contour_segments.is_empty():
		_draw_fallback_arc()
		return

	for segment in _contour_segments:
		if segment.size() < 2:
			continue
		var local_points: PackedVector2Array = PackedVector2Array()
		local_points.resize(segment.size())
		for i in segment.size():
			local_points[i] = _world_to_local(segment[i])
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


func _world_to_local(world_m: Vector2) -> Vector2:
	return ViewTransforms.world_m_to_overlay_local(world_m, _view_context(), self)


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


func _build_contour_segments() -> Array[PackedVector2Array]:
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

	var covers: PackedFloat32Array = PackedFloat32Array()
	covers.resize(cols * rows)
	for row in range(rows):
		for col in range(cols):
			var world_m: Vector2 = _mask_origin_world_m + Vector2(
				float(col) * step_x,
				float(row) * step_y
			)
			covers[row * cols + col] = _cover_at(world_m)

	var segments: Array[PackedVector2Array] = []
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

			var p_tl: Vector2 = Vector2(x0, y0)
			var p_tr: Vector2 = Vector2(x1, y0)
			var p_bl: Vector2 = Vector2(x0, y1)
			var p_br: Vector2 = Vector2(x1, y1)

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

			var top: Vector2 = _edge_cross(p_tl, tl, p_tr, tr)
			var right: Vector2 = _edge_cross(p_tr, tr, p_br, br)
			var bottom: Vector2 = _edge_cross(p_bl, bl, p_br, br)
			var left: Vector2 = _edge_cross(p_tl, tl, p_bl, bl)

			match case_idx:
				1, 14:
					segments.append(PackedVector2Array([left, top]))
				2, 13:
					segments.append(PackedVector2Array([top, right]))
				3, 12:
					segments.append(PackedVector2Array([left, right]))
				4, 11:
					segments.append(PackedVector2Array([right, bottom]))
				5:
					segments.append(PackedVector2Array([left, top]))
					segments.append(PackedVector2Array([right, bottom]))
				6, 9:
					segments.append(PackedVector2Array([top, bottom]))
				7, 8:
					segments.append(PackedVector2Array([left, bottom]))
				10:
					segments.append(PackedVector2Array([top, right]))
					segments.append(PackedVector2Array([left, bottom]))

	return segments


static func _edge_cross(a: Vector2, cover_a: float, b: Vector2, cover_b: float) -> Vector2:
	var denom: float = cover_b - cover_a
	if absf(denom) < 0.00001:
		return a.lerp(b, 0.5)
	var t: float = clampf((ISO_COVER - cover_a) / denom, 0.0, 1.0)
	return a.lerp(b, t)
