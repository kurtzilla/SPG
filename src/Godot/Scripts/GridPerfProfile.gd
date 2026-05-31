class_name GridPerfProfile
extends RefCounted

## Debug-only scoped timers for grid overlay hot paths.

static var _enabled: bool = OS.is_debug_build()

static var _scopes_usec: Dictionary = {}
static var _gpu_refresh_count: int = 0
static var _report_timer: float = 0.0
const REPORT_INTERVAL_SEC: float = 2.0


static func begin(scope_name: StringName) -> int:
	if not _enabled:
		return 0
	return Time.get_ticks_usec()


static func end(scope_name: StringName, start_usec: int) -> void:
	if not _enabled or start_usec <= 0:
		return
	var elapsed: int = Time.get_ticks_usec() - start_usec
	var key: String = String(scope_name)
	_scopes_usec[key] = int(_scopes_usec.get(key, 0)) + elapsed


static func record_gpu_refresh() -> void:
	if not _enabled:
		return
	_gpu_refresh_count += 1


static func maybe_report(delta: float) -> void:
	if not _enabled:
		return
	_report_timer += delta
	if _report_timer < REPORT_INTERVAL_SEC:
		return
	_report_timer = 0.0
	if _scopes_usec.is_empty() and _gpu_refresh_count <= 0:
		return
	var lines: PackedStringArray = PackedStringArray()
	for key: String in _scopes_usec.keys():
		var total_usec: int = int(_scopes_usec[key])
		lines.append("%s: %.2f ms" % [key, float(total_usec) / 1000.0])
	_scopes_usec.clear()
	if _gpu_refresh_count > 0:
		lines.append("gpu_refresh_count: %d" % _gpu_refresh_count)
		_gpu_refresh_count = 0
	print("[GridPerf] ", ", ".join(lines))
