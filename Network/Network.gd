extends Node

# Это центральный менеджер. Он создаёт подсистемы и управляет подключениями.

const PORT := 7777
const MAX_CLIENTS := 100

var peer: ENetMultiplayerPeer

var player_name := "Player"

var connected_players: Dictionary = {}
# Серверные экземпляры игроков.
var server_players: Dictionary = {}

var connection_network: ConnectionNetwork
var player_network: PlayerNetwork
var world_network: WorldNetwork




func _ready() -> void:
    _create_modules()

    if DisplayServer.get_name() == "headless":
        start_server()
    else:
        start_client("127.0.0.1")


func _create_modules() -> void:
    connection_network = ConnectionNetwork.new()
    connection_network.name = "ConnectionNetwork"
    add_child(connection_network)

    player_network = PlayerNetwork.new()
    player_network.name = "PlayerNetwork"
    add_child(player_network)

    world_network = WorldNetwork.new()
    world_network.name = "WorldNetwork"
    add_child(world_network)


# --------------------------------------------------
# SERVER
# --------------------------------------------------

func start_server() -> void:
    peer = ENetMultiplayerPeer.new()

    var error := peer.create_server(PORT, MAX_CLIENTS)

    if error != OK:
        push_error("Server startup failed: %s" % error)
        return

    multiplayer.peer_connected.connect(_on_peer_connected)
    multiplayer.peer_disconnected.connect(_on_peer_disconnected)

    multiplayer.multiplayer_peer = peer

    print("SERVER STARTED ON PORT ", PORT)


func _on_peer_connected(id: int) -> void:
    print("PLAYER CONNECTED: ", id, " — WAITING FOR HELLO")


func _on_peer_disconnected(id: int) -> void:
    print("PLAYER DISCONNECTED: ", id)

    connected_players.erase(id)
    server_players.erase(id)

    if multiplayer.is_server():
        player_network.broadcast_player_list()


# --------------------------------------------------
# CLIENT
# --------------------------------------------------

func start_client(address: String) -> void:
    peer = ENetMultiplayerPeer.new()

    var error := peer.create_client(address, PORT)

    if error != OK:
        push_error("Client startup failed: %s" % error)
        return

    multiplayer.connected_to_server.connect(_on_connected)
    multiplayer.connection_failed.connect(_on_connection_failed)
    multiplayer.server_disconnected.connect(_on_server_disconnected)

    multiplayer.multiplayer_peer = peer

    print("CONNECTING TO SERVER: ", address)


func _on_connected() -> void:
    print("CONNECTED TO SERVER")
    connection_network.on_client_connected()


func _on_connection_failed() -> void:
    print("CONNECTION FAILED")


func _on_server_disconnected() -> void:
    print("SERVER DISCONNECTED")

func create_server_player(id: int) -> void:
    if not multiplayer.is_server():
        return

    if server_players.has(id):
        return

    var planet := get_tree().get_first_node_in_group("planet") as Planet

    if planet == null:
        push_error("Planet not found on server!")
        return

    var center := planet.to_global(planet.get_planet_center())
    var spawn_direction := Vector3.UP

    var spawn_position := center + spawn_direction * (planet.RADIUS + 3.0)

    var server_player := ServerPlayer.new(id, spawn_position)

    server_players[id] = server_player

    print(
        "SERVER PLAYER CREATED | ID: ",
        id,
        " | POSITION: ",
        spawn_position
    )