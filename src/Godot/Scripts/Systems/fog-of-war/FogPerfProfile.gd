class_name FogPerfProfile
extends RefCounted

## Debug-only scoped timers for fog hot paths (Godot Profiler → Script functions).
## Reports interval totals and peak ms/frame (mirrors ChunkPerfProfile shape).

static var _enabled: bool = OS.is_debug_build()

static var _scopes_usec: Dictionary = {}
static var _frame_scope_usec: Dictionary = {}
static var _peak_scope_usec: Dictionary = {}
static var _mask_commit_count: int = 0
static var _mask_commit_partial_count: int = 0
static var _recenter_event_count: int = 0
static var _report_timer: float = 0.0
const REPORT_INTERVAL_SEC: float = 2.0

## Scopes listed first in [FogPerf] reports (recenter block, then hot path).
const _REPORT_SCOPE_ORDER: Array[StringName] = [
	&"recenter_total",
	&"recenter_duplicate",
	&"recenter_shift",
	&"recenter_holes",
	&"recenter_restore",
	&"recenter_restore_square",
	&"recenter_restore_disc",
	&"recenter_upload",
	&"persist_player_reveal",
	&"reveal_disc_path_stamp",
	&"motion_bake_stamp",
	&"apply_overlay_projection",
	&"commit_mask_gpu",
]


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
	_frame_scope_usec[key] = int(_frame_scope_usec.get(key, 0)) + elapsed


static func record_mask_commit(partial: bool) -> void:
	if not _enabled:
		return
	_mask_commit_count += 1
	if partial:
		_mask_commit_partial_count += 1


static func log_recenter(message: String) -> void:
	if not _enabled:
		return
	_recenter_event_count += 1
	print("[FogRecenter] ", message)


static func notify_frame() -> void:
	if not _enabled:
		return
	for key: String in _frame_scope_usec.keys():
		var frame_usec: int = int(_frame_scope_usec[key])
		var peak_usec: int = int(_peak_scope_usec.get(key, 0))
		if frame_usec > peak_usec:
			_peak_scope_usec[key] = frame_usec
	_frame_scope_usec.clear()


static func maybe_report(delta: float) -> void:
	if not _enabled:
		return
	_report_timer += delta
	if _report_timer < REPORT_INTERVAL_SEC:
		return
	_report_timer = 0.0
	if _scopes_usec.is_empty() and _mask_commit_count <= 0 and _recenter_event_count <= 0:
		return
	var lines: PackedStringArray = PackedStringArray()
	var interval_sec: float = REPORT_INTERVAL_SEC
	var reported: Dictionary = {}
	for scope_name: StringName in _REPORT_SCOPE_ORDER:
		var key: String = String(scope_name)
		if not _scopes_usec.has(key):
			continue
		lines.append(_format_scoped_metric(key, int(_scopes_usec[key]), interval_sec))
		reported[key] = true
	for key: String in _scopes_usec.keys():
		if reported.has(key):
			continue
		lines.append(_format_scoped_metric(key, int(_scopes_usec[key]), interval_sec))
	_scopes_usec.clear()
	if _mask_commit_count > 0:
		var full_count: int = _mask_commit_count - _mask_commit_partial_count
		lines.append(
			"commit_mask_gpu: %d commits (%d partial, %d full)" % [
				_mask_commit_count,
				_mask_commit_partial_count,
				full_count,
			]
		)
		_mask_commit_count = 0
		_mask_commit_partial_count = 0
	if _recenter_event_count > 0:
		lines.append("recenter_events: %d" % _recenter_event_count)
		_recenter_event_count = 0
	_peak_scope_usec.clear()
	print("[FogPerf] ", ", ".join(lines))


static func _format_scoped_metric(scope_name: String, total_usec: int, interval_sec: float) -> String:
	var total_ms: float = float(total_usec) / 1000.0
	var peak_usec: int = int(_peak_scope_usec.get(scope_name, 0))
	var peak_ms: float = float(peak_usec) / 1000.0
	if peak_usec > 0:
		return "%s: %.2f ms / %.1fs (peak %.2f ms/frame)" % [
			scope_name, total_ms, interval_sec, peak_ms
		]
	return "%s: %.2f ms / %.1fs" % [scope_name, total_ms, interval_sec]
