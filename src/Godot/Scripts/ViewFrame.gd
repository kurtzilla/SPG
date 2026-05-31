extends RefCounted

## Per-frame view snapshot built once in MainSandbox._apply_view_frame() (pooled instance).

const ViewFrameScript = preload("res://src/Godot/Scripts/ViewFrame.gd")

var map_scroll: Vector2 = Vector2.ZERO
var camera_focus_map_px: Vector2 = Vector2.ZERO
var zoom: float = 1.0
var viewport_center: Vector2 = Vector2.ZERO
var viewport_size: Vector2 = Vector2.ZERO
var canvas_transform: Transform2D = Transform2D.IDENTITY
var canvas_to_map_local: Transform2D = Transform2D.IDENTITY
var camera_grid: Vector2i = Vector2i.ZERO


static var _pooled: RefCounted


static func build(player: Node2D = null) -> RefCounted:
	return populate_from_applied(player, null)


## Single build site: projection from applied map scroll node when available.
static func populate_from_applied(player: Node2D, map_scroll_node: Node2D) -> RefCounted:
	if _pooled == null:
		_pooled = ViewFrameScript.new()
	var frame: RefCounted = _pooled
	frame.viewport_center = ViewProjection.get_screen_center_offset()
	frame.viewport_size = ViewProjection.get_viewport_size()
	frame.zoom = ViewProjection.safe_zoom()
	frame.camera_focus_map_px = ViewProjection.resolve_camera_focus_map_px(player)
	frame.map_scroll = frame.camera_focus_map_px
	if map_scroll_node != null and is_instance_valid(map_scroll_node):
		frame.canvas_transform = map_scroll_node.get_global_transform_with_canvas()
	else:
		frame.canvas_transform = ViewProjection.forward_canvas_transform()
	frame.canvas_to_map_local = frame.canvas_transform.affine_inverse()
	frame.camera_grid = ViewProjection.map_local_px_to_grid_cell(frame.camera_focus_map_px)
	return frame
