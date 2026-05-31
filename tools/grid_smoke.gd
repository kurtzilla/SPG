extends Node
## Headless grid regression gate. Launched via res://tools/GridSmokeRunner.tscn

const FRAMES_AFTER_BOOTSTRAP: int = 4

var _failures: PackedStringArray = PackedStringArray()


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_failures.append_array(GridOverlay.collect_shader_failures())
	await _check_grid_overlay_scene()
	await _check_main_sandbox_bootstrap()
	_report_and_quit()


func _check_grid_overlay_scene() -> void:
	var packed: PackedScene = load("res://src/Godot/Scenes/GridOverlay.tscn") as PackedScene
	if packed == null:
		_failures.append("GridOverlay.tscn failed to load")
		return
	var instance: Node = packed.instantiate()
	add_child(instance)
	await get_tree().process_frame
	_failures.append_array(GridOverlay.collect_scene_wiring_failures(instance))
	var grid: GridOverlay = instance as GridOverlay
	grid.configure(true)
	grid.apply_canvas_transform(Transform2D.IDENTITY)
	await get_tree().process_frame
	_failures.append_array(GridOverlay.collect_bootstrap_failures(grid))
	instance.queue_free()


func _check_main_sandbox_bootstrap() -> void:
	var main_scene: PackedScene = load("res://src/Godot/Scenes/MainSandbox.tscn") as PackedScene
	if main_scene == null:
		_failures.append("MainSandbox.tscn failed to load")
		return
	var main: Node = main_scene.instantiate()
	add_child(main)
	for _i: int in range(FRAMES_AFTER_BOOTSTRAP):
		await get_tree().process_frame
	var grid_overlay: Node = main.get_node_or_null("GridOverlay")
	if grid_overlay == null:
		_failures.append("MainSandbox missing GridOverlay node")
		main.queue_free()
		return
	_failures.append_array(GridOverlay.collect_scene_wiring_failures(grid_overlay))
	if not grid_overlay is GridOverlay:
		_failures.append("MainSandbox GridOverlay node is not GridOverlay type")
		main.queue_free()
		return
	var grid: GridOverlay = grid_overlay as GridOverlay
	grid.configure(true)
	grid.apply_canvas_transform(Transform2D.IDENTITY)
	await get_tree().process_frame
	_failures.append_array(GridOverlay.collect_bootstrap_failures(grid))
	main.queue_free()


func _report_and_quit() -> void:
	if _failures.is_empty():
		print("[GRID_SMOKE] OK — shader, wiring, bootstrap")
		get_tree().quit(0)
		return
	for line: String in _failures:
		push_error("[GRID_SMOKE FAIL] %s" % line)
	print("[GRID_SMOKE] %d failure(s)" % _failures.size())
	get_tree().quit(1)
