extends Node
## Headless fog regression gate. Launched via res://tools/FogSmokeRunner.tscn

const FRAMES_AFTER_BOOTSTRAP: int = 4

var _failures: PackedStringArray = PackedStringArray()


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	_failures.append_array(FogOverlay.collect_shader_failures())
	_check_fog_overlay_scene()
	await _check_main_sandbox_bootstrap()
	_report_and_quit()


func _check_fog_overlay_scene() -> void:
	var packed: PackedScene = load("res://src/Godot/Scenes/FogOverlay.tscn") as PackedScene
	if packed == null:
		_failures.append("FogOverlay.tscn failed to load")
		return
	var instance: Node = packed.instantiate()
	_failures.append_array(FogOverlay.collect_scene_wiring_failures(instance))
	instance.free()


func _check_main_sandbox_bootstrap() -> void:
	var main_scene: PackedScene = load("res://src/Godot/Scenes/MainSandbox.tscn") as PackedScene
	if main_scene == null:
		_failures.append("MainSandbox.tscn failed to load")
		return
	var main: Node = main_scene.instantiate()
	add_child(main)
	for _i: int in range(FRAMES_AFTER_BOOTSTRAP):
		await get_tree().process_frame
	var fog_overlay: Node = main.get_node_or_null("FogOverlay")
	if fog_overlay == null:
		_failures.append("MainSandbox missing FogOverlay node")
		main.queue_free()
		return
	_failures.append_array(FogOverlay.collect_scene_wiring_failures(fog_overlay))
	var fog_explore: Node = main.get_node_or_null("FogExploration")
	var player: Node2D = main.find_child("Player", true, false) as Node2D
	if fog_explore == null or player == null:
		_failures.append("MainSandbox missing FogExploration or Player for bootstrap")
		main.queue_free()
		return
	if not fog_explore.has_method("setup") or not fog_explore.has_method("bootstrap_exploration"):
		_failures.append("FogExploration missing setup/bootstrap_exploration")
		main.queue_free()
		return
	fog_explore.setup(player, fog_overlay)
	fog_explore.bootstrap_exploration(Vector2i.ZERO)
	fog_explore.on_player_cell_changed(Vector2i.ZERO)
	for _i: int in range(2):
		await get_tree().process_frame
	_failures.append_array(FogOverlay.collect_bootstrap_failures(fog_overlay as FogOverlay))
	main.queue_free()


func _report_and_quit() -> void:
	if _failures.is_empty():
		print("[FOG_SMOKE] OK — shader, wiring, bootstrap")
		get_tree().quit(0)
		return
	for line: String in _failures:
		push_error("[FOG_SMOKE FAIL] %s" % line)
	print("[FOG_SMOKE] %d failure(s)" % _failures.size())
	get_tree().quit(1)
