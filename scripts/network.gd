extends Node
# Global singleton for WebSocket ↔ MARS communication and scene sync.

signal state_update(state)

# === Member vars ===
var socket: WebSocketPeer = WebSocketPeer.new()
var agents := {}

# === Preload agent scenes ===
var CarScene         = preload("res://car.tscn")
var TruckScene       = preload("res://truck.tscn")
var LogScene         = preload("res://log.tscn")
var RiverTurtleScene = preload("res://turtle.tscn")
var PadScene         = preload("res://pad.tscn")
var FrogScene        = preload("res://player.tscn")
var has_started := false
var game_over_state := false

# onready fetches the real node once the scene is ready
@onready var agents_container: Node = get_tree().get_current_scene().get_node("HBoxContainer/SubViewportContainer/SubViewport/agents")
@onready var StartButton: Button = get_tree().get_current_scene().get_node("HBoxContainer/uiLeft/StartButton")
@onready var ResetButton: Button = get_tree().get_current_scene().get_node("HBoxContainer/uiLeft/ResetButton")
@onready var jump_label : Label = get_tree().get_current_scene().get_node("HBoxContainer/uiRight/JumpLabel")
@onready var lives_label : Label = get_tree().get_current_scene().get_node("HBoxContainer/uiRight/LivesLabel")

func _ready():
	# sanity‐check that we actually found your "agents" node
	if not agents_container:
		push_error("Could not find agents_container %s")
	# start the WebSocket
	var err = socket.connect_to_url("ws://127.0.0.1:8181")
	if err != OK:
		push_error("WebSocketPeer.connect failed: %s" % err)
	set_process(true)
	# Start-Button Setup
	StartButton.toggle_mode = true
	StartButton.text = "Start"
	StartButton.button_pressed = false
	StartButton.toggled.connect(_on_start_toggled)
	# Reset-Button Setup
	ResetButton.disabled = true
	ResetButton.text = "Reset"
	ResetButton.pressed.connect(_on_reset_pressed)

var input_cooldown := 0.2
var time_since_last_input := 0.0

func _process(delta):
	time_since_last_input += delta

	var direction := "null"

	if time_since_last_input >= input_cooldown:
		if Input.is_action_just_pressed("ui_up"):
			direction = "up"
		elif Input.is_action_just_pressed("ui_down"):
			direction = "down"
		elif Input.is_action_just_pressed("ui_left"):
			direction = "left"
		elif Input.is_action_just_pressed("ui_right"):
			direction = "right"

		if direction != "null" and socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
			var input_msg = {
				"type": "input",
				"direction": direction
			}
			print("Sending msg to socket: %s" % input_msg)
			socket.send_text(JSON.stringify(input_msg))
			time_since_last_input = 0.0

	socket.poll()

	if socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		while socket.get_available_packet_count() > 0:
			var raw = socket.get_packet().get_string_from_utf8()
			_on_raw_data(raw)

	elif socket.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		push_warning("WebSocket closed: %d %s" % [
			socket.get_close_code(),
			socket.get_close_reason()
		])
		set_process(false)

func _on_raw_data(raw: String) -> void:
	var parser = JSON.new()
	var err = parser.parse(raw)
	if err != OK:
		push_error("Invalid JSON: %s" % raw)
		return
	var state = parser.data

	if state.has("gameOver") and state["gameOver"]:
		print("Game Over received from server")
		game_over_state = true
		has_started = false
		StartButton.disabled = true
		ResetButton.disabled = false

	if state.has("lives"):
		lives_label.text = "Lives: %d" % int(state.lives)
	
	if state.has("removeIds") and typeof(state.removeIds) == TYPE_ARRAY:
		for rid in state.removeIds:
			var id = int(rid)
			if agents.has(id):
				var node = agents[id]
				if is_instance_valid(node):
					node.queue_free()
				agents.erase(id)

	if state.has("expectingTick"):
		var next_tick = state["expectingTick"]
		print("✨ ACKing tick", next_tick)
		socket.send_text(str(next_tick))

	if not state.has("agents") or typeof(state.agents) != TYPE_ARRAY:
		return

	emit_signal("state_update", state)
	_apply_state(state)

func _apply_state(state) -> void:
	for data in state.agents:
		var id     = int(data.id)
		var kind   = data.breed
		var pos    = Vector2(data.x, data.y)
		var head   = data.heading
		var is_hidden = data.has("hidden") and data.hidden

		if not agents.has(id):
			var inst
			match kind:
				"car":           inst = CarScene.instantiate()
				"truck":         inst = TruckScene.instantiate()
				"log":           inst = LogScene.instantiate()
				"turtle":        inst = RiverTurtleScene.instantiate()
				"pad":           inst = PadScene.instantiate()
				"frog":          inst = FrogScene.instantiate()
				_: continue
			inst.agent_id = id
			agents[id] = inst
			agents_container.add_child(inst)

		match kind:
			"car", "truck", "log":
				agents[id].update_state(pos, head)
			"turtle":
				agents[id].update_state(pos, head, is_hidden)
			"pad":
				agents[id].update_state(pos, head)
				if data.has("occupied") and data.occupied and not data.has("dummy_spawned"):
					var dummy_frog = FrogScene.instantiate()
					dummy_frog.position = agents[id].position
					agents_container.add_child(dummy_frog)
					# Markierung setzen, damit wir nicht doppelt spawnen
					data["dummy_spawned"] = true
			"frog":
				agents[id].update_state(pos, head)
				if data.has("jumps"):
					jump_label.text = "Frog Jumps: %d" % int(data.jumps)

func _on_start_toggled(pressed: bool) -> void:
	if socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("WebSocket not open")
		return

	if not has_started:
		var msg = {"type": "control", "cmd": "start"}
		print ("sending start signal to server")
		socket.send_text(JSON.stringify(msg))
		has_started = true
		StartButton.text = "Pause"
		StartButton.button_pressed = true
		return

	if pressed:
		socket.send_text(JSON.stringify({"type":"control","cmd":"resume"}))
		print ("sending resume signal to server")
		StartButton.text = "Pause"
	else:
		socket.send_text(JSON.stringify({"type":"control","cmd":"pause"}))
		print ("sending pause signal to server")
		StartButton.text = "Resume"

func _on_reset_pressed() -> void:
	if socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("WebSocket not open")
		return

	print("sending restart signal to server")
	socket.send_text(JSON.stringify({"type": "control", "cmd": "restart"}))

	# Szene und UI zurücksetzen
	for id in agents.keys():
		if is_instance_valid(agents[id]):
			agents[id].queue_free()
	agents.clear()

	has_started = false
	game_over_state = false
	StartButton.disabled = false
	ResetButton.disabled = true
	StartButton.text = "Start"
	StartButton.button_pressed = false
