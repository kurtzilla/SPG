extends RefCounted

## Core character state. Grid position uses infinite offset coordinates:
## positive x = East, negative x = West; positive y = South, negative y = North.

var id: String = ""
var name: String = ""
var x: int = 0
var y: int = 0


func _init(p_id: String, p_name: String, start_x: int = 0, start_y: int = 0) -> void:
	id = p_id
	name = p_name
	x = start_x
	y = start_y


func move_to(new_x: int, new_y: int) -> void:
	x = new_x
	y = new_y


func move_relative(dx: int, dy: int) -> void:
	x += dx
	y += dy
