extends Node

## Thin facade over Settings for view/camera concerns (zoom wheel, view_changed signal).

signal view_changed


func _ready() -> void:
	if not Settings.view_changed.is_connected(_on_settings_view_changed):
		Settings.view_changed.connect(_on_settings_view_changed)


var zoom: float:
	get:
		return Settings.zoom
	set(value):
		Settings.zoom = value


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
