extends Node

## Central settings autoload. Single source of truth: game_settings.json (see USE_USER_SETTINGS_FILE).

const SettingsContext = preload("res://src/Godot/Scripts/SettingsContext.gd")
const ViewMetrics = preload("res://src/Godot/Scripts/ViewMetrics.gd")

signal setting_changed(path: String)
signal movement_changed
signal fog_changed
signal view_changed

const DEFAULTS_PATH: String = "res://src/Godot/Config/game_settings.json"
## Dev stage: false = only game_settings.json; true = load/save user://settings.cfg for persist keys.
const USE_USER_SETTINGS_FILE: bool = false
const USER_PATH: String = "user://settings.cfg"
const LEGACY_MOVEMENT_PATH: String = "user://player_movement.cfg"
const LEGACY_VIEW_PATH: String = "user://view_settings.cfg"

const SKIP_SECTIONS: Array[String] = ["schema_version"]

const MOVEMENT_PATHS: Array[String] = [
	"player_movement.max_speed",
	"player_movement.acceleration",
	"player_movement.friction",
]

const VIEW_PATHS: Array[String] = [
	"view.zoom",
	"view.settings_panel_visible",
]

const FOG_PATHS: Array[String] = [
	"fog.initial_reveal_radius",
	"fog.player_reveal_radius",
]

const LEGACY_FOG_PATH_INITIAL: String = "fog.initial_reveal_radius_cells"
const LEGACY_FOG_PATH_PLAYER: String = "fog.movement_reveal_radius_cells"
const LEGACY_FOG_PATH_REVEAL_RADIUS: String = "fog.reveal_radius_cells"
const FOG_DEFAULT_PATH_INITIAL: String = "fog.initial_reveal_radius"
const FOG_DEFAULT_PATH_PLAYER: String = "fog.player_reveal_radius"

var _schema: Dictionary = {}
var _values: Dictionary = {}
var _save_timer: Timer


func _ready() -> void:
	_load_defaults()
	_apply_scale_snapshot()
	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = get_float("view.save_debounce_sec")
	_save_timer.timeout.connect(save_user_settings)
	add_child(_save_timer)
	load_user_settings()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		save_user_settings()


func _exit_tree() -> void:
	save_user_settings()


# --- Convenience properties (hot paths) ---

var zoom: float:
	get:
		return get_float("view.zoom")
	set(value):
		set_float("view.zoom", value)


var max_speed: float:
	get:
		return get_float("player_movement.max_speed")
	set(value):
		set_float("player_movement.max_speed", value)


var acceleration: float:
	get:
		return get_float("player_movement.acceleration")
	set(value):
		set_float("player_movement.acceleration", value)


var friction: float:
	get:
		return get_float("player_movement.friction")
	set(value):
		set_float("player_movement.friction", value)


var settings_panel_visible: bool:
	get:
		return get_bool("view.settings_panel_visible")
	set(value):
		set_bool("view.settings_panel_visible", value)


var initial_reveal_radius: int:
	get:
		return get_int("fog.initial_reveal_radius")
	set(value):
		set_int("fog.initial_reveal_radius", value)


var player_reveal_radius: int:
	get:
		return get_int("fog.player_reveal_radius")
	set(value):
		set_int("fog.player_reveal_radius", value)


# --- Typed getters ---

func get_setting(path: String, default_value: Variant = null) -> Variant:
	if not has(path):
		return default_value
	match _schema[path].get("type", TYPE_NIL):
		TYPE_BOOL:
			return get_bool(path)
		TYPE_INT:
			return get_int(path)
		_:
			return get_float(path)

func get_float(path: String) -> float:
	return float(_values.get(path, _schema.get(path, {}).get("default", 0.0)))


func get_int(path: String) -> int:
	return int(_values.get(path, _schema.get(path, {}).get("default", 0)))


func get_bool(path: String) -> bool:
	return bool(_values.get(path, _schema.get(path, {}).get("default", false)))


func get_color(path: String) -> Color:
	var raw: Variant = _values.get(path, _schema.get(path, {}).get("default", Color.WHITE))
	return _to_color(raw)


func get_default(path: String) -> Variant:
	if not _schema.has(path):
		return null
	return _schema[path].get("default")


func get_min(path: String) -> Variant:
	if not _schema.has(path):
		return null
	return _schema[path].get("min")


func get_max(path: String) -> Variant:
	if not _schema.has(path):
		return null
	return _schema[path].get("max")


func get_step(path: String) -> Variant:
	if not _schema.has(path):
		return null
	return _schema[path].get("step")


func get_context(path: String) -> SettingsContext.Context:
	if not _schema.has(path):
		return SettingsContext.Context.GAME
	return _schema[path].get("context", SettingsContext.Context.GAME)


func has(path: String) -> bool:
	return _schema.has(path)


# --- Typed setters ---

func set_float(path: String, value: float) -> void:
	_set_value(path, _clamp_float(path, value))


func set_int(path: String, value: int) -> void:
	_set_value(path, _clamp_int(path, value))


func set_bool(path: String, value: bool) -> void:
	_set_value(path, value)


func set_color(path: String, value: Color) -> void:
	_set_value(path, value)


func set_max_speed(value: float) -> void:
	set_float("player_movement.max_speed", value)


func set_acceleration(value: float) -> void:
	set_float("player_movement.acceleration", value)


func set_friction(value: float) -> void:
	set_float("player_movement.friction", value)


func set_settings_panel_visible(visible: bool) -> void:
	set_bool("view.settings_panel_visible", visible)


func get_settings_panel_visible() -> bool:
	return settings_panel_visible


# --- Persistence ---

func load_user_settings() -> void:
	_reset_values_to_defaults()

	if not USE_USER_SETTINGS_FILE:
		_emit_domain_signals()
		return

	if not FileAccess.file_exists(USER_PATH):
		_migrate_legacy_user_settings()
		_migrate_legacy_fog_values()
		_emit_domain_signals()
		return

	var config := ConfigFile.new()
	var err: Error = config.load(USER_PATH)
	if err != OK:
		_migrate_legacy_user_settings()
		_migrate_legacy_fog_values()
		_emit_domain_signals()
		return

	for path: String in _schema:
		var entry: Dictionary = _schema[path]
		if not entry.get("persist", false):
			continue
		var section: String = SettingsContext.to_section_name(entry.get("context", SettingsContext.Context.GAME))
		if not config.has_section_key(section, path):
			continue
		_values[path] = _coerce_value(path, config.get_value(section, path))

	_migrate_legacy_fog_keys_from_config(config)
	_emit_domain_signals()


func save_user_settings() -> void:
	if not USE_USER_SETTINGS_FILE:
		return

	var config := ConfigFile.new()
	for path: String in _schema:
		var entry: Dictionary = _schema[path]
		if not entry.get("persist", false):
			continue
		var section: String = SettingsContext.to_section_name(entry.get("context", SettingsContext.Context.GAME))
		config.set_value(section, path, _values.get(path, entry.get("default")))
	config.save(USER_PATH)


# --- Internal ---

func _load_defaults() -> void:
	_schema.clear()
	_values.clear()

	var file := FileAccess.open(DEFAULTS_PATH, FileAccess.READ)
	if file == null:
		push_error("Settings: Failed to open defaults: " + DEFAULTS_PATH)
		return

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("Settings: Failed to parse defaults JSON: " + json.get_error_message())
		file.close()
		return
	file.close()

	var root: Variant = json.data
	if typeof(root) != TYPE_DICTIONARY:
		push_error("Settings: Defaults root must be a Dictionary")
		return

	for section_name: String in root:
		if section_name in SKIP_SECTIONS or section_name.begins_with("_"):
			continue
		var section: Variant = root[section_name]
		if typeof(section) != TYPE_DICTIONARY:
			continue
		_parse_section(section_name, section)

	_reset_values_to_defaults()


func _parse_section(prefix: String, section: Dictionary) -> void:
	for key: String in section:
		if key.begins_with("_"):
			continue
		var path: String = "%s.%s" % [prefix, key]
		var raw: Variant = section[key]
		if typeof(raw) == TYPE_DICTIONARY and raw.has("value"):
			_register_schema_entry(path, raw)
		else:
			_register_schema_entry(path, {"value": raw})


func _register_schema_entry(path: String, raw: Dictionary) -> void:
	if raw.get("source") == "core":
		return

	var default_value: Variant = raw.get("value")
	var entry: Dictionary = {
		"default": default_value,
		"type": _infer_type(default_value),
		"context": SettingsContext.from_string(str(raw.get("context", "game"))),
		"persist": bool(raw.get("persist", false)),
	}
	if raw.has("min"):
		entry["min"] = raw["min"]
	if raw.has("max"):
		entry["max"] = raw["max"]
	if raw.has("step"):
		entry["step"] = raw["step"]
	_schema[path] = entry


func _reset_values_to_defaults() -> void:
	for path: String in _schema:
		_values[path] = _schema[path].get("default")


func _set_value(path: String, value: Variant) -> void:
	if not _schema.has(path):
		push_warning("Settings: Unknown path: " + path)
		return

	var current: Variant = _values.get(path)
	if typeof(current) == TYPE_FLOAT and typeof(value) == TYPE_FLOAT:
		if is_equal_approx(float(current), float(value)):
			return
	elif current == value:
		return

	_values[path] = value
	setting_changed.emit(path)
	if path in MOVEMENT_PATHS:
		movement_changed.emit()
	if path in FOG_PATHS:
		fog_changed.emit()
		_persist_fog_path_to_defaults(path, value)
	if path in VIEW_PATHS or path.begins_with("view."):
		view_changed.emit()
	if USE_USER_SETTINGS_FILE and _schema[path].get("persist", false):
		_schedule_save()


func _clamp_float(path: String, value: float) -> float:
	var entry: Dictionary = _schema.get(path, {})
	var min_v: Variant = entry.get("min")
	var max_v: Variant = entry.get("max")
	if min_v != null and max_v != null:
		return clampf(value, float(min_v), float(max_v))
	if min_v != null:
		return maxf(value, float(min_v))
	if max_v != null:
		return minf(value, float(max_v))
	return value


func _clamp_int(path: String, value: int) -> int:
	var entry: Dictionary = _schema.get(path, {})
	var min_v: Variant = entry.get("min")
	var max_v: Variant = entry.get("max")
	if min_v != null and max_v != null:
		return clampi(value, int(min_v), int(max_v))
	if min_v != null:
		return maxi(value, int(min_v))
	if max_v != null:
		return mini(value, int(max_v))
	return value


func _coerce_value(path: String, value: Variant) -> Variant:
	var entry: Dictionary = _schema.get(path, {})
	match entry.get("type", TYPE_NIL):
		TYPE_FLOAT:
			return float(value)
		TYPE_INT:
			return int(value)
		TYPE_BOOL:
			return bool(value)
		TYPE_COLOR:
			return _to_color(value)
		_:
			return value


func _infer_type(value: Variant) -> int:
	match typeof(value):
		TYPE_BOOL:
			return TYPE_BOOL
		TYPE_INT:
			return TYPE_INT
		TYPE_FLOAT:
			return TYPE_FLOAT
		TYPE_ARRAY:
			return TYPE_COLOR
		TYPE_COLOR:
			return TYPE_COLOR
		_:
			return typeof(value)


func _to_color(raw: Variant) -> Color:
	if raw is Color:
		return raw
	if typeof(raw) == TYPE_ARRAY and raw.size() >= 3:
		var alpha: float = 1.0 if raw.size() < 4 else float(raw[3])
		return Color(float(raw[0]), float(raw[1]), float(raw[2]), alpha)
	return Color.WHITE


func _apply_scale_snapshot() -> void:
	ViewMetrics.apply_scale(get_int("scale.pixels_per_meter"), get_float("scale.meters_per_cell"))


func _schedule_save() -> void:
	if _save_timer != null:
		_save_timer.wait_time = get_float("view.save_debounce_sec")
		_save_timer.start()


func _persist_fog_path_to_defaults(path: String, value: Variant) -> void:
	if path != FOG_DEFAULT_PATH_INITIAL and path != FOG_DEFAULT_PATH_PLAYER:
		return
	var serialized_path: String = ProjectSettings.globalize_path(DEFAULTS_PATH)
	var read_file := FileAccess.open(serialized_path, FileAccess.READ)
	if read_file == null:
		push_warning("Settings: Cannot open defaults for fog persistence: " + serialized_path)
		return
	var raw_text: String = read_file.get_as_text()
	read_file.close()
	var json := JSON.new()
	if json.parse(raw_text) != OK:
		push_warning("Settings: Cannot parse defaults JSON for fog persistence: " + json.get_error_message())
		return
	var root: Variant = json.data
	if typeof(root) != TYPE_DICTIONARY:
		push_warning("Settings: Defaults JSON root is not a Dictionary for fog persistence")
		return
	var fog_section: Variant = root.get("fog", null)
	if typeof(fog_section) != TYPE_DICTIONARY:
		push_warning("Settings: Missing fog section in defaults JSON")
		return
	var fog_dict: Dictionary = fog_section
	var key_name: String = path.get_slice(".", 1)
	var fog_entry: Variant = fog_dict.get(key_name, null)
	if typeof(fog_entry) != TYPE_DICTIONARY:
		push_warning("Settings: Missing fog key in defaults JSON: " + path)
		return
	var entry_dict: Dictionary = fog_entry
	entry_dict["value"] = value
	fog_dict[key_name] = entry_dict
	root["fog"] = fog_dict
	var write_file := FileAccess.open(serialized_path, FileAccess.WRITE)
	if write_file == null:
		push_warning("Settings: Cannot write defaults for fog persistence: " + serialized_path)
		return
	write_file.store_string(JSON.stringify(root, "\t"))
	write_file.close()


func _migrate_legacy_user_settings() -> void:
	var migrated: bool = false

	var movement_cfg := ConfigFile.new()
	if movement_cfg.load(LEGACY_MOVEMENT_PATH) == OK:
		if movement_cfg.has_section_key("movement", "max_speed"):
			_values["player_movement.max_speed"] = _clamp_float(
				"player_movement.max_speed",
				float(movement_cfg.get_value("movement", "max_speed"))
			)
			migrated = true
		if movement_cfg.has_section_key("movement", "acceleration"):
			_values["player_movement.acceleration"] = _clamp_float(
				"player_movement.acceleration",
				float(movement_cfg.get_value("movement", "acceleration"))
			)
			migrated = true
		if movement_cfg.has_section_key("movement", "friction"):
			_values["player_movement.friction"] = _clamp_float(
				"player_movement.friction",
				float(movement_cfg.get_value("movement", "friction"))
			)
			migrated = true

	var view_cfg := ConfigFile.new()
	if view_cfg.load(LEGACY_VIEW_PATH) == OK:
		if view_cfg.has_section_key("view", "zoom"):
			_values["view.zoom"] = _clamp_float("view.zoom", float(view_cfg.get_value("view", "zoom")))
			migrated = true
		if view_cfg.has_section_key("view", "settings_panel_visible"):
			_values["view.settings_panel_visible"] = bool(
				view_cfg.get_value("view", "settings_panel_visible")
			)
			migrated = true

	if migrated:
		save_user_settings()

	_migrate_legacy_fog_values()


func _migrate_legacy_fog_keys_from_config(config: ConfigFile) -> void:
	if _migrate_legacy_fog_values_from_config(config):
		save_user_settings()


func _migrate_legacy_fog_values() -> void:
	if not FileAccess.file_exists(USER_PATH):
		return
	var config := ConfigFile.new()
	if config.load(USER_PATH) != OK:
		return
	if _migrate_legacy_fog_values_from_config(config):
		save_user_settings()


func _migrate_legacy_fog_values_from_config(config: ConfigFile) -> bool:
	var migrated: bool = false
	var section: String = SettingsContext.to_section_name(SettingsContext.Context.GAME)
	if (
		config.has_section_key(section, LEGACY_FOG_PATH_INITIAL)
		and not config.has_section_key(section, "fog.initial_reveal_radius")
	):
		_values["fog.initial_reveal_radius"] = _clamp_int(
			"fog.initial_reveal_radius",
			int(config.get_value(section, LEGACY_FOG_PATH_INITIAL))
		)
		migrated = true
	if (
		config.has_section_key(section, LEGACY_FOG_PATH_PLAYER)
		and not config.has_section_key(section, "fog.player_reveal_radius")
	):
		_values["fog.player_reveal_radius"] = _clamp_int(
			"fog.player_reveal_radius",
			int(config.get_value(section, LEGACY_FOG_PATH_PLAYER))
		)
		migrated = true
	if (
		config.has_section_key(section, LEGACY_FOG_PATH_REVEAL_RADIUS)
		and not config.has_section_key(section, "fog.initial_reveal_radius")
	):
		_values["fog.initial_reveal_radius"] = _clamp_int(
			"fog.initial_reveal_radius",
			int(config.get_value(section, LEGACY_FOG_PATH_REVEAL_RADIUS))
		)
		migrated = true
	return migrated


func _emit_domain_signals() -> void:
	movement_changed.emit()
	fog_changed.emit()
	view_changed.emit()
