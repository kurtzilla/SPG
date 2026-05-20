extends RefCounted

enum CellState {
    WALKABLE,
    BLOCKED,
}

# Dictionary mapping String keys "x,y" to CellState values
var _cells: Dictionary = {}

# Default state for coordinates that haven't been generated yet
var default_state: CellState = CellState.WALKABLE


func _init() -> void:
    # Starts completely empty. Procedural generation or manual placement 
    # will populate the hash map dynamically.
    _cells.clear()


# Since the grid is infinite, it is always technically in bounds.
func is_in_bounds(_x: int, _y: int) -> bool:
    return true


func get_cell_state(x: int, y: int) -> CellState:
    var key: String = _make_key(x, y)
    if _cells.has(key):
        return _cells[key] as CellState
    return default_state


func set_cell_state(x: int, y: int, state: CellState) -> void:
    var key: String = _make_key(x, y)
    _cells[key] = state


func is_walkable(x: int, y: int) -> bool:
    return get_cell_state(x, y) == CellState.WALKABLE


# Clears out data—great for clearing a seed to start a new procedural map
func clear_grid() -> void:
    _cells.clear()


# Helper to convert coordinates into a deterministic dictionary lookup key
func _make_key(x: int, y: int) -> String:
    return str(x) + "," + str(y)