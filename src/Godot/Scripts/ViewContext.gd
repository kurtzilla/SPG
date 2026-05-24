class_name ViewContext
extends RefCounted

## Bundle of view/camera state passed to ViewTransforms conversion functions.

var map_scroll: Node2D
var zoom: float = 1.0
var viewport_center: Vector2 = Vector2.ZERO
var viewport_size: Vector2 = Vector2.ZERO


static func from_viewport(
	map_scroll: Node2D,
	viewport: Viewport,
	zoom_override: float = -1.0
) -> ViewContext:
	var ctx := ViewContext.new()
	ctx.map_scroll = map_scroll
	if viewport != null:
		var rect: Rect2 = viewport.get_visible_rect()
		ctx.viewport_size = rect.size
		ctx.viewport_center = (rect.size * 0.5).floor()
	if zoom_override >= 0.0:
		ctx.zoom = zoom_override
	elif map_scroll != null:
		ctx.zoom = map_scroll.scale.x
	else:
		ctx.zoom = 1.0
	if is_zero_approx(ctx.zoom):
		ctx.zoom = 1.0
	return ctx
