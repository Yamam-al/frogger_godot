extends Area2D
@export var agent_id: int 

# Method called from network.gd
func update_state(pos: Vector2, heading: float = 0, is_hidden: bool = false) -> void:
	position = pos * 64 - Vector2(32,32)               # Beispiel: 1 Grid-Unit = 64px
	rotation_degrees = heading
	visible = not is_hidden
