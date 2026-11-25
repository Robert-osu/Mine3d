extends Node
class_name PlayerNetwork

var visible_players: Dictionary = {}


func broadcast_player_list() -> void:
	if not multiplayer.is_server():
		return

	sync_player_list.rpc(Network.connected_players)


@rpc("authority", "call_remote", "reliable")
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