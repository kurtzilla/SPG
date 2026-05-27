class_name ViewTransforms
extends RefCounted

## Canonical view-layer coordinate conversions between named spaces.
## Grid/WorldM rules mirror Core GridMath; pixel scale comes from ViewMetrics.

const ViewMetrics = preload("res://src/Godot/Scripts/ViewMetrics.gd")


static func meters_to_pixels(meters: float) -> float:
	return meters * float(ViewMetrics.PIXELS_PER_METER)


static func pixels_to_meters(pixels: float) -> float:
	return pixels / float(ViewMetrics.PIXELS_PER_METER)


static func zoomed_pixels_per_meter(ctx: ViewContext) -> float:
	return float(ViewMetrics.PIXELS_PER_METER) * _safe_zoom(ctx)


static func grid_to_world_m(gx: float, gy: float) -> Vector2:
	return Vector2(gx * ViewMetrics.METERS_PER_CELL, gy * ViewMetrics.METERS_PER_CELL)


static func world_m_to_grid(world_m: Vector2) -> Vector2:
	return Vector2(world_m.x / ViewMetrics.METERS_PER_CELL, world_m.y / ViewMetrics.METERS_PER_CELL)


static func world_m_to_grid_i(world_m: Vector2) -> Vector2i:
	return Vector2i(
		int(floor(world_m.x / ViewMetrics.METERS_PER_CELL)),
		int(floor(world_m.y / ViewMetrics.METERS_PER_CELL))
	)


static func grid_to_map_local_px(gx: float, gy: float) -> Vector2:
	return Vector2(gx * float(ViewMetrics.CELL_SIZE_PX), gy * float(ViewMetrics.CELL_SIZE_PX))


static func map_local_px_to_grid(px: Vector2) -> Vector2:
	return Vector2(px.x / float(ViewMetrics.CELL_SIZE_PX), px.y / float(ViewMetrics.CELL_SIZE_PX))


static func world_m_to_map_local_px(world_m: Vector2) -> Vector2:
	return Vector2(
		meters_to_pixels(world_m.x),
		meters_to_pixels(world_m.y)
	)


static func map_local_px_to_world_m(px: Vector2) -> Vector2:
	return Vector2(
		pixels_to_meters(px.x),
		pixels_to_meters(px.y)
	)


static func map_local_px_to_canvas(px: Vector2, ctx: ViewContext) -> Vector2:
	if ctx.map_scroll == null:
		return ViewProjection.world_to_screen(px)
	return ctx.map_scroll.get_global_transform_with_canvas() * px


static func canvas_to_map_local_px(canvas: Vector2, ctx: ViewContext) -> Vector2:
	if ctx.map_scroll == null:
		return ViewProjection.screen_to_world(canvas)
	return ctx.map_scroll.get_global_transform_with_canvas().affine_inverse() * canvas


static func canvas_to_world_m(canvas: Vector2, ctx: ViewContext) -> Vector2:
	var map_px: Vector2 = canvas_to_map_local_px(canvas, ctx)
	return map_local_px_to_world_m(map_px)


static func world_m_to_canvas(world_m: Vector2, ctx: ViewContext) -> Vector2:
	var map_px: Vector2 = world_m_to_map_local_px(world_m)
	return map_local_px_to_canvas(map_px, ctx)


static func canvas_to_view(canvas: Vector2, ctx: ViewContext) -> Vector2:
	return canvas - ctx.viewport_center


static func view_to_canvas(view: Vector2, ctx: ViewContext) -> Vector2:
	return view + ctx.viewport_center


static func world_m_to_view(world_m: Vector2, ctx: ViewContext) -> Vector2:
	return canvas_to_view(world_m_to_canvas(world_m, ctx), ctx)


static func view_to_world_m(view: Vector2, ctx: ViewContext) -> Vector2:
	return canvas_to_world_m(view_to_canvas(view, ctx), ctx)


static func canvas_to_overlay_local(canvas: Vector2, overlay: CanvasItem) -> Vector2:
	if overlay == null:
		return canvas
	return overlay.get_global_transform_with_canvas().affine_inverse() * canvas


static func overlay_local_to_canvas(local: Vector2, overlay: CanvasItem) -> Vector2:
	if overlay == null:
		return local
	return overlay.get_global_transform_with_canvas() * local


static func world_m_to_overlay_local(
	world_m: Vector2,
	ctx: ViewContext,
	overlay: CanvasItem
) -> Vector2:
	return canvas_to_overlay_local(world_m_to_canvas(world_m, ctx), overlay)


static func grid_to_canvas(gx: float, gy: float, ctx: ViewContext) -> Vector2:
	return map_local_px_to_canvas(grid_to_map_local_px(gx, gy), ctx)


static func canvas_to_grid(canvas: Vector2, ctx: ViewContext) -> Vector2:
	return map_local_px_to_grid(canvas_to_map_local_px(canvas, ctx))


static func grid_to_overlay_local(
	gx: float,
	gy: float,
	ctx: ViewContext,
	overlay: CanvasItem
) -> Vector2:
	return canvas_to_overlay_local(grid_to_canvas(gx, gy, ctx), overlay)


static func visible_canvas_rect(ctx: ViewContext) -> Rect2:
	return Rect2(Vector2.ZERO, ctx.viewport_size)


static func visible_world_m_rect(ctx: ViewContext) -> Rect2:
	var top_left: Vector2 = canvas_to_world_m(Vector2.ZERO, ctx)
	var bottom_right: Vector2 = canvas_to_world_m(ctx.viewport_size, ctx)
	return Rect2(top_left, bottom_right - top_left)


static func visible_grid_radius_cells(ctx: ViewContext, buffer_cells: int = 0) -> int:
	var cell_px: float = float(ViewMetrics.CELL_SIZE_PX) * _safe_zoom(ctx)
	if cell_px <= 0.0:
		return buffer_cells
	var half_x: int = int(ceil(ctx.viewport_size.x * 0.5 / cell_px)) + buffer_cells
	var half_y: int = int(ceil(ctx.viewport_size.y * 0.5 / cell_px)) + buffer_cells
	return maxi(half_x, half_y)


static func visible_grid_bounds(
	ctx: ViewContext,
	center_gx: int,
	center_gy: int,
	buffer_cells: int = 0
) -> Rect2i:
	var radius: int = visible_grid_radius_cells(ctx, buffer_cells)
	return Rect2i(
		center_gx - radius,
		center_gy - radius,
		radius * 2 + 1,
		radius * 2 + 1
	)


static func world_m_to_normalized_rect(
	world_m: Vector2,
	origin_world_m: Vector2,
	size_world_m: Vector2
) -> Vector2:
	if size_world_m.x <= 0.0 or size_world_m.y <= 0.0:
		return Vector2(-1.0, -1.0)
	return Vector2(
		(world_m.x - origin_world_m.x) / size_world_m.x,
		(world_m.y - origin_world_m.y) / size_world_m.y
	)


static func _safe_zoom(ctx: ViewContext) -> float:
	if ctx == null:
		return 1.0
	var zoom: float = ctx.zoom
	if is_zero_approx(zoom):
		return 1.0
	return zoom
