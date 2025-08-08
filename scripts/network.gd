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


# onready fetches the real node once the scene is ready
@onready var agents_container: Node = get_tree().get_current_scene().get_node("HBoxContainer/SubViewportContainer/SubViewport/agents")
@onready var StartButton: Button = get_tree().get_current_scene().get_node("HBoxContainer/uiLeft/StartButton")


func _ready():
	# sanity‐check that we actually found your "agents" node
	if not agents_container:
		push_error("Could not find agents_container %s")
	# start the WebSocket
	var err = socket.connect_to_url("ws://127.0.0.1:8181")
	if err != OK:
		push_error("WebSocketPeer.connect failed: %s" % err)
	set_process(true)
	# Toggle-Setup
	StartButton.toggle_mode = true
	StartButton.text = "Start"
	StartButton.button_pressed = false
	StartButton.toggled.connect(_on_start_toggled)

var input_cooldown := 0.2
var time_since_last_input := 0.0

func _process(delta):
	
	time_since_last_input += delta

	var direction := "null"
	
	# Nur prüfen, wenn Cooldown vorbei ist
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
			time_since_last_input = 0.0  # Reset cooldown

	# WebSocket weiter verarbeiten
	socket.poll()

	# 📨 Pakete empfangen
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
	#print("🔄 Raw from MARS:", raw) #debug print

	# JSON parsing
	var parser = JSON.new()
	var err = parser.parse(raw)
	if err != OK:
		push_error("Invalid JSON: %s" % raw)
		return
	var state = parser.data

	# acknowledge the tick so MARS can continue
	if state.has("expectingTick"):
		var next_tick = state["expectingTick"]
		print("✨ ACKing tick", next_tick)
		socket.send_text(str(next_tick))

	# only proceed if there's actually an agents array
	if not state.has("agents") or typeof(state.agents) != TYPE_ARRAY:
		return

	emit_signal("state_update", state)
	_apply_state(state)


func _apply_state(state) -> void:
	for data in state.agents:
		var id     = int(data.id)                # cast to int
		var kind   = data.breed
		var pos    = Vector2(data.x, data.y)
		var head   = data.heading
		var is_hidden = data.has("hidden") and data.hidden

		if not agents.has(id):
			var inst
			match kind:
				"car":           inst = CarScene.instantiate()
				"truck":         inst = TruckScene.instantiate()
				"log":          inst = LogScene.instantiate()
				"turtle": inst = RiverTurtleScene.instantiate()
				"pad":          inst = PadScene.instantiate()
				"frog":         inst = FrogScene.instantiate()
				_: continue
			inst.agent_id = id
			agents[id] = inst
			# use the exposed container
			agents_container.add_child(inst)

		# update existing agent
		match kind:
			"car", "truck", "log":
				agents[id].update_state(pos, head)
			"turtle":
				agents[id].update_state(pos, head, is_hidden)
			"pad":
				agents[id].update_state(pos, head)
			"frog":
				agents[id].update_state(pos, head)

func _on_start_toggled(pressed: bool) -> void:
	if socket.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("WebSocket not open")
		return
	if not has_started:
	# erster Klick => Start
		var msg = {"type": "control", "cmd": "start"}
		socket.send_text(JSON.stringify(msg))
		has_started = true
		StartButton.text = "Pause"      # jetzt kann man pausieren
		StartButton.button_pressed = true
		return
		
	# Danach ist es ein echter Toggle:
	if pressed:	
		# Button ist „down“ ⇒ Resume läuft ⇒ Button zeigt 'Pause'
		socket.send_text(JSON.stringify({"type":"control","cmd":"resume"}))
		StartButton.text = "Pause"
	else:
		# Button ist „up“ ⇒ Pause ⇒ Button zeigt 'Resume'
		socket.send_text(JSON.stringify({"type":"control","cmd":"pause"}))
		StartButton.text = "Resume"
