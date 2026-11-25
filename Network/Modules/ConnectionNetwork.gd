extends Node
class_name ConnectionNetwork

var connected := false


func on_client_connected() -> void:
	connected = false

	hello.rpc_id(
		1,
		NetworkProtocol.VERSION,
		Network.player_name
	)


# Клиент отправляет запрос серверу.
@rpc("any_peer", "call_remote", "reliable", 0)
func hello(version: int, requested_name: String) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()

	if sender_id <= 0:
		return

	if version != NetworkProtocol.VERSION:
		reject.rpc_id(sender_id, "Protocol version mismatch")
		return

	var clean_name := requested_name.strip_edges()

	if clean_name.is_empty() or clean_name.length() > NetworkProtocol.MAX_PLAYER_NAME_LENGTH:
		reject.rpc_id(sender_id, "Invalid player name")
		return

	if Network.connected_players.has(sender_id):
		return

	Network.connected_players[sender_id] = {
		"name": clean_name
	}

	print("PLAYER AUTHORIZED: ", clean_name, " ID: ", sender_id)

	welcome.rpc_id(sender_id, sender_id)

	Network.player_network.broadcast_player_list()


# Сервер подтверждает подключение.
@rpc("authority", "call_remote", "reliable", 0)
func welcome(server_assigned_id: int) -> void:
	if connected:
		return

	if server_assigned_id != multiplayer.get_unique_id():
		push_error("Unexpected server-assigned ID!")
		return

	connected = true

	print("JOIN ACCEPTED")
	print("MY NETWORK ID: ", server_assigned_id)


# Сервер отклоняет подключение.
@rpc("authority", "call_remote", "reliable", 0)
func reject(reason: String) -> void:
	print("JOIN REJECTED: ", reason)

	connected = false
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

