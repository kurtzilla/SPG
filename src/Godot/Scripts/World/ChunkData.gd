class_name ChunkData

extends RefCounted

var coord: Vector2i
var tiles: PackedByteArray
var chunk_size: int = 32


func _init(chunk_coord: Vector2i, p_chunk_size: int) -> void:
	coord = chunk_coord
	chunk_size = p_chunk_size
	tiles = PackedByteArray()
	tiles.resize(chunk_size * chunk_size)
	tiles.fill(0)


func get_tile_index(flat_index: int) -> int:
	return tiles[flat_index]
