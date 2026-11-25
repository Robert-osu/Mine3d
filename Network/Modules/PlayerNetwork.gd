extends Node
class_name PlayerNetwork


var visible_players: Dictionary = {}

# Последний принятый ввод каждого игрока.
var latest_inputs: Dictionary = {}

# Последний обработанный порядковый номер.
var last_input_sequence: Dictionary = {}


# --------------------------------------------------
# CLIENT -> SERVER
# --------------------------------------------------

var input_sequence := 0


func send_input(
	move_input: Vector2,
	look_direction: Vector3,
	buttons: int
) -> void:
	if not multiplayer.has_multiplayer_peer():
		return

	if multiplayer.is_server():
		return

	if not Network.connection_network.connected:
		return

	input_sequence += 1

	submit_input.rpc_id(
		1,
		input_sequence,
		move_input,
		look_direction,
		buttons
	)


@rpc("any_peer", "call_remote", "unreliable_ordered", 0)
func submit_input(
	sequence: int,
	move_input: Vector2,
	look_direction: Vector3,
	buttons: int
) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()

	# Принимать ввод можно только от зарегистрированных игроков.
	if not Network.connected_players.has(sender_id):
		return

	# Не принимаем устаревшие пакеты.
	var previous_sequence: int = last_input_sequence.get(sender_id, -1)

	if sequence <= previous_sequence:
		return

	# Проверяем допустимые значения.
	if sequence < 0:
		return

	if move_input.length() > 1.01:
		return

	if look_direction.length_squared() < 0.0001:
		return

	# Сохраняем последний ввод игрока.
	last_input_sequence[sender_id] = sequence

	latest_inputs[sender_id] = {
		"move_input": move_input.limit_length(1.0),
		"look_direction": look_direction.normalized(),
		"buttons": buttons
	}


func broadcast_player_list() -> void:
	if not multiplayer.is_server():
		return

	sync_player_list.rpc(Network.connected_players)


@rpc("authority", "call_remote", "reliable", 0)
func sync_player_list(players: Dictionary) -> void:
	visible_players = players.duplicate(true)

	print("========== PLAYERS ONLINE ==========")

	for id in visible_players:
		var player_data: Dictionary = visible_players[id]

		print(
			"ID: ", id,
			" | NAME: ", player_data["name"]
		)

	print("====================================")