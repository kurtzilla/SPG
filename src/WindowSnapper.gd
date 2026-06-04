extends Node

func _ready() -> void:
	# 0 is always the primary screen. 
	# If you have 2 screens, 1 is the secondary (your Left Monitor 2).
	if DisplayServer.get_screen_count() > 1:
		DisplayServer.window_set_current_screen(1)