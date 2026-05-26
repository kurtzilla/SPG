class_name ViewContext
extends RefCounted

## Bundle of view/camera state passed to ViewTransforms conversion functions.

var map_scroll: Node2D
var zoom: float = 1.0
var viewport_center: Vector2 = Vector2.ZERO
var viewport_size: Vector2 = Vector2.ZERO

static var _cached: ViewContext = null
static var _cached_zoom: float = -1.0
static var _cached_scroll_pos: Vector2 = Vector2.INF
static var _cached_viewport_size: Vector2 = Vector2.ZERO


static func viewport_center_from(viewport: Viewport) -> Vector2:
	if viewport == null:
		return Vector2.ZERO
	# Visible rect matches FRAGCOORD / canvas space under stretch modes.
	return viewport.get_visible_rect().get_center()


static func from_viewport(
	p_map_scroll: Node2D,
	viewport: Viewport,
	zoom_override: float = -1.0
) -> ViewContext:
	var z: float
	if zoom_override >= 0.0:
		z = zoom_override
	elif p_map_scroll != null:
		z = p_map_scroll.scale.x
	else:
		z = 1.0
	if is_zero_approx(z):
		z = 1.0

	var vp_size: Vector2 = Vector2.ZERO
	if viewport != null:
		vp_size = viewport.get_visible_rect().size

	var scroll_pos: Vector2 = Vector2.ZERO
	if p_map_scroll != null:
		scroll_pos = p_map_scroll.global_position

	if _cached != null and is_equal_approx(z, _cached_zoom) and scroll_pos == _cached_scroll_pos and vp_size == _cached_viewport_size:
		return _cached

	var ctx := ViewContext.new()
	ctx.map_scroll = p_map_scroll
	ctx.zoom = z
	ctx.viewport_size = vp_size
	ctx.viewport_center = viewport_center_from(viewport)

	_cached = ctx
	_cached_zoom = z
	_cached_scroll_pos = scroll_pos
	_cached_viewport_size = vp_size
	return ctx
