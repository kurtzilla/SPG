class_name ChunkPerfProfile
extends RefCounted

## Debug-only scoped timers for chunk streaming hot paths.

static var _enabled: bool = OS.is_debug_build()

static var _scopes_usec: Dictionary = {}
static var _paint_cells_count: int = 0
static var _report_timer: float = 0.0
static var _frame_paint_usec: int = 0
static var _frame_gen_usec: int = 0
static var _peak_paint_frame_usec: int = 0
static var _peak_gen_frame_usec: int = 0
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
	if key == "paint_cells":
		_frame_paint_usec += elapsed
	elif key == "generate":
		_frame_gen_usec += elapsed


static func record_paint_cells(count: int) -> void:
	if not _enabled or count <= 0:
		return
	_paint_cells_count += count


static func notify_frame() -> void:
	if not _enabled:
		return
	if _frame_paint_usec > _peak_paint_frame_usec:
		_peak_paint_frame_usec = _frame_paint_usec
	if _frame_gen_usec > _peak_gen_frame_usec:
		_peak_gen_frame_usec = _frame_gen_usec
	_frame_paint_usec = 0
	_frame_gen_usec = 0


static func maybe_report(delta: float) -> void:
	if not _enabled:
		return
	_report_timer += delta
	if _report_timer < REPORT_INTERVAL_SEC:
		return
	_report_timer = 0.0
	if _scopes_usec.is_empty() and _paint_cells_count <= 0:
		return
	var lines: PackedStringArray = PackedStringArray()
	var interval_sec: float = REPORT_INTERVAL_SEC
	for key: String in _scopes_usec.keys():
		if key == "paint_cells" or key == "generate":
			continue
		var total_usec: int = int(_scopes_usec[key])
		lines.append("%s: %.2f ms" % [key, float(total_usec) / 1000.0])
	if _scopes_usec.has("paint_cells"):
		lines.append(_format_scoped_metric(
			"paint_cells",
			int(_scopes_usec["paint_cells"]),
			_paint_cells_count,
			_peak_paint_frame_usec,
			interval_sec
		))
	if _scopes_usec.has("generate"):
		lines.append(_format_scoped_metric(
			"generate",
			int(_scopes_usec["generate"]),
			0,
			_peak_gen_frame_usec,
			interval_sec
		))
	_scopes_usec.clear()
	_paint_cells_count = 0
	_peak_paint_frame_usec = 0
	_peak_gen_frame_usec = 0
	print("[ChunkPerf] ", ", ".join(lines))


static func _format_scoped_metric(
	scope_name: String,
	total_usec: int,
	call_count: int,
	peak_frame_usec: int,
	interval_sec: float
) -> String:
	var total_ms: float = float(total_usec) / 1000.0
	var peak_ms: float = float(peak_frame_usec) / 1000.0
	if scope_name == "paint_cells" and call_count > 0:
		var us_per_call: float = float(total_usec) / float(call_count)
		return (
			"paint_cells: %.2f ms / %.1fs (peak %.2f ms/frame, %d calls, %.1f µs/call)" % [
				total_ms,
				interval_sec,
				peak_ms,
				call_count,
				us_per_call,
			]
		)
	return "%s: %.2f ms / %.1fs (peak %.2f ms/frame)" % [scope_name, total_ms, interval_sec, peak_ms]
