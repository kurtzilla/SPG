extends RefCounted

var characters: Array = []
var selected_character_id: String = ""


func add_character(character: RefCounted) -> void:
    if character == null:
        return
    var auto_select: bool = selected_character_id.is_empty()
    characters.append(character)
    if auto_select:
        selected_character_id = character.id


func remove_character(id: String) -> void:
    var index: int = _find_index_by_id(id)
    if index < 0:
        return
    var was_selected: bool = selected_character_id == id
    characters.remove_at(index)
    if was_selected:
        if characters.is_empty():
            selected_character_id = ""
        else:
            selected_character_id = (characters[0] as RefCounted).id


func get_character(id: String) -> RefCounted:
    var index: int = _find_index_by_id(id)
    if index < 0:
        return null
    return characters[index] as RefCounted


func get_selected_character() -> RefCounted:
    if selected_character_id.is_empty():
        return null
    return get_character(selected_character_id)


func select_character(id: String) -> bool:
    if _find_index_by_id(id) < 0:
        return false
    selected_character_id = id
    return true


func get_all_characters() -> Array:
    return characters.duplicate()


func _find_index_by_id(id: String) -> int:
    for i in range(characters.size()):
        var character: RefCounted = characters[i] as RefCounted
        if character != null and character.id == id:
            return i
    return -1
