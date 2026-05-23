extends Node

## Runtime view settings for the virtual scroll camera (top-down + zoom).

signal view_changed

const ZOOM_MIN: float = 0.2
const ZOOM_MAX: float = 2.0
const ZOOM_DEFAULT: float = 1.0
const ZOOM_WHEEL_STEP: float = 0.1
const SETTINGS_PATH: String = "user://view_settings.cfg"
const SAVE_DEBOUNCE_SEC: float = 0.5

const FOG_ENABLED_DEFAULT: bool = true
const FOG_INITIAL_RADIUS_DEFAULT: int = 12
const FOG_MOVE_RADIUS_DEFAULT: int = 12
const FOG_MASK_METERS_PER_TEXEL_DEFAULT: float = 1.0
const FOG_FEATHER_CELLS_DEFAULT: int = 2
const FOG_MASK_METERS_PER_TEXEL_MIN: float = 1.0
const FOG_MASK_METERS_PER_TEXEL_MAX: float = 8.0
const FOG_FEATHER_CELLS_MIN: int = 1
const FOG_FEATHER_CELLS_MAX: int = 12
const SETTINGS_PANEL_VISIBLE_DEFAULT: bool = true

var zoom: float = ZOOM_DEFAULT

var _cached_fog_enabled: bool = FOG_ENABLED_DEFAULT
var _cached_fog_initial_radius: int = FOG_INITIAL_RADIUS_DEFAULT
var _cached_fog_move_radius: int = FOG_MOVE_RADIUS_DEFAULT
var _cached_fog_mask_meters_per_texel: float = FOG_MASK_METERS_PER_TEXEL_DEFAULT
var _cached_fog_feather_cells: int = FOG_FEATHER_CELLS_DEFAULT
var _cached_settings_panel_visible: bool = SETTINGS_PANEL_VISIBLE_DEFAULT

var _save_timer: Timer


func _ready() -> void:
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = SAVE_DEBOUNCE_SEC
	_save_timer.timeout.connect(save_settings)
	add_child(_save_timer)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_settings()


func _exit_tree() -> void:
	save_settings()


func adjust_zoom(delta_steps: int) -> bool:
	var new_zoom: float = clampf(
		zoom + float(delta_steps) * ZOOM_WHEEL_STEP,
		ZOOM_MIN,
		ZOOM_MAX
	)
	if is_equal_approx(new_zoom, zoom):
		return false
	zoom = new_zoom
	view_changed.emit()
	_schedule_save()
	return true


func _schedule_save() -> void:
	if _save_timer != null:
		_save_timer.start()


func get_settings_panel_visible() -> bool:
	return _cached_settings_panel_visible


func set_settings_panel_visible(visible: bool) -> void:
	_cached_settings_panel_visible = visible
	_schedule_save()


func get_fog_mask_meters_per_texel() -> float:
	return _cached_fog_mask_meters_per_texel


func set_fog_mask_meters_per_texel(value: float) -> void:
	_cached_fog_mask_meters_per_texel = clampf(
		value,
		FOG_MASK_METERS_PER_TEXEL_MIN,
		FOG_MASK_METERS_PER_TEXEL_MAX
	)


func get_fog_feather_cells() -> int:
	return _cached_fog_feather_cells


func set_fog_feather_cells(value: int) -> void:
	_cached_fog_feather_cells = clampi(value, FOG_FEATHER_CELLS_MIN, FOG_FEATHER_CELLS_MAX)


func apply_fog_to_visibility(visibility) -> void:
	if visibility == null:
		return
	visibility.FogEnabled = _cached_fog_enabled
	visibility.InitialRevealRadius = _cached_fog_initial_radius
	visibility.MovementRevealRadius = _cached_fog_move_radius


func load_settings() -> void:
	var config := ConfigFile.new()
	var err: Error = config.load(SETTINGS_PATH)
	if err != OK:
		zoom = ZOOM_DEFAULT
		_reset_fog_cache_to_defaults()
		return
	zoom = clampf(
		config.get_value("view", "zoom", ZOOM_DEFAULT),
		ZOOM_MIN,
		ZOOM_MAX
	)
	_reset_fog_cache_to_defaults()
	_cached_settings_panel_visible = config.get_value(
		"view", "settings_panel_visible", SETTINGS_PANEL_VISIBLE_DEFAULT
	)


func _reset_fog_cache_to_defaults() -> void:
	_cached_fog_enabled = FOG_ENABLED_DEFAULT
	_cached_fog_initial_radius = FOG_INITIAL_RADIUS_DEFAULT
	_cached_fog_move_radius = FOG_MOVE_RADIUS_DEFAULT
	_cached_fog_mask_meters_per_texel = FOG_MASK_METERS_PER_TEXEL_DEFAULT
	_cached_fog_feather_cells = FOG_FEATHER_CELLS_DEFAULT
	_cached_settings_panel_visible = SETTINGS_PANEL_VISIBLE_DEFAULT


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("view", "zoom", zoom)
	config.set_value("view", "settings_panel_visible", _cached_settings_panel_visible)
	config.save(SETTINGS_PATH)
