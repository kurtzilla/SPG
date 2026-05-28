extends Node

## Pushes a Node2D focus (player or Camera2D) into ViewProjection each physics tick.

var _camera_source: Node2D = null


func _ready() -> void:
	var parent_source := get_parent() as Node2D
	if parent_source != null:
		register_source(parent_source)


func register_source(source: Node2D) -> void:
	_camera_source = source
	if _camera_source != null:
		ViewProjection.register_camera(_camera_source)


func _physics_process(_delta: float) -> void:
	if _camera_source == null or not is_instance_valid(_camera_source):
		return
	ViewProjection.update_camera_position(_camera_source.position)
