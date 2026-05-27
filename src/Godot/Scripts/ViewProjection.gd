extends Node

## Autoload facade: zoom/settings plus centered map-local ↔ canvas transforms.
## map_scroll is the camera focus in map-local px (not the WorldCanvas/Tiles node position).

signal view_changed

## Camera focus in map-local px. When zero, world origin is at screen center.
var map_scroll: Vector2 = Vector2.ZERO

var _cached_screen_center: Vector2 = Vector2.ZERO
var _viewport_provider: Node = null


func register_viewport_provider(node: Node) -> void:
	_viewport_provider = node
	invalidate_screen_center_cache()


func _ready() -> void:
	if not Settings.view_changed.is_connected(_on_settings_view_changed):
		Settings.view_changed.connect(_on_settings_view_changed)


var zoom: float:
	get:
		return Settings.zoom
	set(value):
		Settings.zoom = value


func invalidate_screen_center_cache() -> void:
	_cached_screen_center = Vector2.ZERO


func get_view_dimensions() -> Vector2:
	var center: Vector2 = get_screen_center_offset()
	if center.x > 0.0 and center.y > 0.0:
		return center * 2.0
	var main_loop := Engine.get_main_loop()
	if main_loop is SceneTree and main_loop.root != null:
		var vp: Viewport = main_loop.root.get_viewport()
		if vp != null:
			return vp.get_visible_rect().size
	return Vector2(
		float(ProjectSettings.get_setting("display/window/size/viewport_width", 1920)),
		float(ProjectSettings.get_setting("display/window/size/viewport_height", 1080))
	)


func get_screen_center_offset() -> Vector2:
	if _cached_screen_center != Vector2.ZERO:
		return _cached_screen_center
	var center: Vector2 = _read_viewport_center()
	if center.x > 0.0 and center.y > 0.0:
		_cached_screen_center = center
	return center


func _read_viewport_center() -> Vector2:
	var vp: Viewport = null
	if _viewport_provider != null and _viewport_provider.is_inside_tree():
		vp = _viewport_provider.get_viewport()
	if vp == null:
		var main_loop := Engine.get_main_loop()
		if main_loop is SceneTree and main_loop.root != null:
			vp = main_loop.root.get_viewport()
	if vp == null:
		return Vector2.ZERO
	var rect: Rect2 = vp.get_visible_rect()
	if rect.size.x < 1.0 or rect.size.y < 1.0:
		return Vector2.ZERO
	# Visible rect origin is (0,0) under viewport stretch; center = half size.
	return rect.size * 0.5


func world_to_screen(world_pos: Vector2) -> Vector2:
	return (world_pos - map_scroll) * zoom + get_screen_center_offset()


func screen_to_world(screen_pos: Vector2) -> Vector2:
	var z: float = zoom if not is_zero_approx(zoom) else 1.0
	return ((screen_pos - get_screen_center_offset()) / z) + map_scroll


func scroll_node_canvas_position() -> Vector2:
	return world_to_screen(Vector2.ZERO)


## Map-local px -> canvas px (scale then translate scroll origin).
func forward_canvas_transform() -> Transform2D:
	var z: float = zoom if not is_zero_approx(zoom) else 1.0
	var scroll_pos: Vector2 = scroll_node_canvas_position()
	return Transform2D(Vector2(z, 0.0), Vector2(0.0, z), scroll_pos)


## Canvas px -> map-local px; matches FogOverlay.sync_scroll forward inverse.
func canvas_to_map_local_transform() -> Transform2D:
	return forward_canvas_transform().affine_inverse()


## Headless/tests: pin screen center when no viewport provider exists.
func pin_screen_center_for_tests(center: Vector2) -> void:
	_cached_screen_center = center


func adjust_zoom(delta_steps: int) -> bool:
	var step: float = Settings.get_float("view.zoom_wheel_step")
	var new_zoom: float = Settings.get_float("view.zoom") + float(delta_steps) * step
	var min_zoom: Variant = Settings.get_min("view.zoom")
	var max_zoom: Variant = Settings.get_max("view.zoom")
	if min_zoom != null and max_zoom != null:
		new_zoom = clampf(new_zoom, float(min_zoom), float(max_zoom))
	if is_equal_approx(new_zoom, Settings.zoom):
		return false
	Settings.zoom = new_zoom
	return true


func get_settings_panel_visible() -> bool:
	return Settings.get_settings_panel_visible()


func set_settings_panel_visible(visible: bool) -> void:
	Settings.set_settings_panel_visible(visible)


func load_settings() -> void:
	Settings.load_user_settings()


func save_settings() -> void:
	Settings.save_user_settings()


func _on_settings_view_changed() -> void:
	view_changed.emit()
