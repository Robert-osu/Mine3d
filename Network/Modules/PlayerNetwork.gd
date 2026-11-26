extends Node
class_name PlayerNetwork


var visible_players: Dictionary = {}

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

	if not Network.server_players.has(sender_id):
		return

	var server_player: ServerPlayer = Network.server_players[sender_id]

	server_player.set_input(
		sequence,
		move_input,
		look_direction,
		buttons
	)

	# Не засоряем консоль каждым пакетом.
	if sequence % 60 == 0:
		print(
			"INPUT RECEIVED | ID: ", sender_id,
			" | SEQUENCE: ", sequence,
			" | MOVE: ", move_input,
			" | LOOK: ", look_direction,
			" | BUTTONS: ", buttons
		)


func broadcast_player_list() -> void:
	if not multiplayer.is_server():
		return

	sync_player_list.rpc(Network.connected_players)


@rpc("authority", "call_remote", "reliable", 0)
func sync_player_list(players: Dictionary) -> void:
	visible_players = players.duplicate(true)

		for id in visible_players:
		var player_data: Dictionary = visible_players[id]

			print("====================================")