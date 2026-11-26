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

    # Создаём серверную модель персонажа.
    Network.create_server_player(sender_id)

    var current_planet := Network._get_planet()

    if current_planet == null:
        reject.rpc_id(sender_id, "Server planet not found")
        return

    print("PLAYER AUTHORIZED: ", clean_name, " ID: ", sender_id)

    var world_config := {
        "planet_scale": current_planet.settings.planet_scale,
        "terrain_color": current_planet.settings.terrain_color.to_html(),
    }

    welcome.rpc_id(
        sender_id,
        sender_id,
        world_config
    )

    Network._broadcast_player_list()


# Сервер подтверждает подключение.
@rpc("authority", "call_remote", "reliable", 0)
func welcome(
    server_assigned_id: int,
    world_config: Dictionary
) -> void:

    if connected:
        return

    if server_assigned_id != multiplayer.get_unique_id():
        push_error("Unexpected server-assigned ID!")
        return

    var current_planet := Network._get_planet()

    if current_planet == null:
        push_error("Local planet not found!")
        return

    if not world_config.has("planet_scale"):
        push_error("Server did not provide planet scale!")
        return

    var server_scale: int = int(world_config["planet_scale"])

    if not current_planet.configure_world(server_scale):
        push_error("Failed to apply server world configuration!")
        return

    if world_config.has("terrain_color"):
        current_planet.settings.terrain_color = Color.from_string(
            str(world_config["terrain_color"]),
            Color("#8b765e")
        )

        current_planet.terrain_material.albedo_color = current_planet.settings.terrain_color

    connected = true

    print("JOIN ACCEPTED")
    print("MY NETWORK ID: ", server_assigned_id)
    print("CONNECTED TO SERVER WORLD")

# Сервер отклоняет подключение.
@rpc("authority", "call_remote", "reliable", 0)
func reject(reason: String) -> void:
    print("JOIN REJECTED: ", reason)

    connected = false
    multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()

