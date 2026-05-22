extends Node

## Runtime view settings for the virtual scroll camera (top-down + zoom).

signal view_changed

const ZOOM_MIN: float = 0.5
const ZOOM_MAX: float = 2.0
const ZOOM_DEFAULT: float = 1.0
const ZOOM_WHEEL_STEP: float = 0.1
const SETTINGS_PATH: String = "user://view_settings.cfg"
const SAVE_DEBOUNCE_SEC: float = 0.5

var zoom: float = ZOOM_DEFAULT

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


func load_settings() -> void:
	var config := ConfigFile.new()
	var err: Error = config.load(SETTINGS_PATH)
	if err != OK:
		zoom = ZOOM_DEFAULT
		return
	zoom = clampf(
		config.get_value("view", "zoom", ZOOM_DEFAULT),
		ZOOM_MIN,
		ZOOM_MAX
	)


func save_settings() -> void:
	var config := ConfigFile.new()
	config.set_value("view", "zoom", zoom)
	config.save(SETTINGS_PATH)
