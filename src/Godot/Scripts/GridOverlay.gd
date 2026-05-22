extends Node2D

## Viewport-space grid lines aligned to the scrolling tile map (debug / readability).
## Lives on a CanvasLayer (not under $Tiles) so zoom does not scale line width.

const ObliqueBridge = preload("res://src/Godot/Scripts/ObliqueBridge.gd")

const GRID_LINE_WIDTH_SCREEN_PX: float = 1.0
const GRID_LINE_COLOR: Color = Color(0.12, 0.14, 0.1, 0.38)

var _enabled: bool = true
var _map_scroll: Node2D
var _center_x: int = 0
var _center_y: int = 0
var _visual_radius: int = 0


func configure(enabled: bool) -> void:
	_enabled = enabled
	queue_redraw()


func set_map_scroll(map_scroll: Node2D) -> void:
	_map_scroll = map_scroll


func update_region(center_x: int, center_y: int, visual_radius: int) -> void:
	_center_x = center_x
	_center_y = center_y
	_visual_radius = visual_radius
	queue_redraw()


func on_view_changed() -> void:
	queue_redraw()


func _cell_size() -> float:
	return float(ObliqueBridge.CELL_SIZE_PX)


func _corner_screen(gx: float, gy: float) -> Vector2:
	if _map_scroll == null:
		return Vector2.ZERO
	var local: Vector2 = ObliqueBridge.data_to_screen(gx, gy)
	return _map_scroll.get_global_transform_with_canvas() * local


func _screen_to_local(screen_pos: Vector2) -> Vector2:
	return get_global_transform_with_canvas().affine_inverse() * screen_pos


func _draw_screen_segment(screen_from: Vector2, screen_to: Vector2) -> void:
	draw_line(
		_screen_to_local(screen_from),
		_screen_to_local(screen_to),
		GRID_LINE_COLOR,
		GRID_LINE_WIDTH_SCREEN_PX,
		false
	)


func _draw() -> void:
	if not _enabled or _visual_radius <= 0 or _map_scroll == null:
		return

	var min_gx: int = _center_x - _visual_radius
	var max_gx: int = _center_x + _visual_radius
	var min_gy: int = _center_y - _visual_radius
	var max_gy: int = _center_y + _visual_radius

	for gx in range(min_gx, max_gx + 1):
		var x_screen: float = round(_corner_screen(float(gx), float(min_gy)).x)
		var y0: float = _corner_screen(float(gx), float(min_gy)).y
		var y1: float = _corner_screen(float(gx), float(max_gy + 1)).y
		_draw_screen_segment(Vector2(x_screen, y0), Vector2(x_screen, y1))

	for gy in range(min_gy, max_gy + 1):
		var y_screen: float = round(_corner_screen(float(min_gx), float(gy)).y)
		var x0: float = _corner_screen(float(min_gx), float(gy)).x
		var x1: float = _corner_screen(float(max_gx + 1), float(gy)).x
		_draw_screen_segment(Vector2(x0, y_screen), Vector2(x1, y_screen))

	var tl: Vector2 = _corner_screen(float(min_gx), float(min_gy))
	var tr: Vector2 = _corner_screen(float(max_gx + 1), float(min_gy))
	var bl: Vector2 = _corner_screen(float(min_gx), float(max_gy + 1))
	var br: Vector2 = _corner_screen(float(max_gx + 1), float(max_gy + 1))
	_draw_screen_segment(tl, tr)
	_draw_screen_segment(bl, br)
	_draw_screen_segment(tl, bl)
	_draw_screen_segment(tr, br)
