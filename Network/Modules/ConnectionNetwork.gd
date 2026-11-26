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

    if (
        Network.connected_players.has(sender_id)
        or Network.world_network.pending_players.has(sender_id)
    ):
        return

    var current_planet := Network._get_planet()

    if current_planet == null:
        reject.rpc_id(sender_id, "Server planet not found")
        return

    if not Network.world_network.begin_player_sync(sender_id, clean_name):
        reject.rpc_id(sender_id, "Could not initialize world synchronization")
        return

    print("PLAYER AUTHORIZED: ", clean_name, " ID: ", sender_id)

    var server_scale: int = (
        current_planet.world_scale
        if current_planet.world_scale > 0
        else current_planet.settings.planet_scale
    )

    var world_config := {
        "planet_scale": server_scale,
        "terrain_color": current_planet.world_terrain_color.to_html(),
    }

    var sync_id := Network.world_network.get_player_sync_id(sender_id)
    if sync_id < 0:
        reject.rpc_id(sender_id, "Could not initialize world synchronization")
        Network.world_network.cancel_pending_player(sender_id)
        return

    welcome.rpc_id(
        sender_id,
        sender_id,
        world_config,
        sync_id
    )


# Сервер передаёт конфигурацию мира.
@rpc("authority", "call_remote", "reliable", 0)
func welcome(
    server_assigned_id: int,
    world_config: Dictionary,
    sync_id: int
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
    var server_terrain_color := Color("#8b765e")

    if world_config.has("terrain_color"):
        server_terrain_color = Color.from_string(
            str(world_config["terrain_color"]),
            server_terrain_color
        )

    if not current_planet.configure_world(
        server_scale,
        server_terrain_color
    ):
        push_error("Failed to apply server world configuration!")
        return

    if sync_id <= 0:
        push_error("Invalid world sync ID!")
        return

    Network.world_network.reset_client_sync(sync_id)
    Network.world_network.request_world_sync.rpc_id(1, sync_id)

    print("WORLD CONFIG RECEIVED")
    print("SYNCHRONIZING PLANET STATE...")


# Сервер отклоняет подключение.
@rpc("authority", "call_remote", "reliable", 0)
func reject(reason: String) -> void:
    print("JOIN REJECTED: ", reason)

    Network._cleanup_client_connection()
    multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
    Network.peer = null
