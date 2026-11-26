
extends Node

# ============================================================
# NETWORK
# Серверная авторитетная симуляция + клиентское предсказание.
# ============================================================

var connection_network: ConnectionNetwork


# Параметры движения.
var settings: GameSettings:
    get:
        return GameConfig.SETTINGS



var player_template: CharacterBody3D

# Удалённые экземпляры игроков.
var remote_players: Dictionary = {}

# История состояний удалённых игроков.
var remote_snapshots: Dictionary = {}

var peer: ENetMultiplayerPeer

var player_name: String = "Player"

var connected_players: Dictionary = {}
var server_players: Dictionary = {}

# Локальный персонаж клиента.
var local_player: CharacterBody3D

# Последовательность клиентских вводов.
var input_sequence: int = 0

# История вводов, которые ещё не подтверждены сервером.
var pending_inputs: Array[Dictionary] = []

# Состояние локального предсказания.
var local_velocity: Vector3 = Vector3.ZERO
var local_previous_buttons: int = 0
var local_grounded: bool = false

# Последний полученный серверный тик.
var last_received_server_tick: int = -1

# Номер физического тика сервера.
var server_physics_tick: int = 0

# Счётчик отправки снимков.
var snapshot_counter: int = 0

# Сглаживание визуальной коррекции.
var correction_offset: Vector3 = Vector3.ZERO

# Ссылка на планету.
var planet: Planet


# ============================================================
# INITIALIZATION
# ============================================================

func _create_modules() -> void:
    connection_network = ConnectionNetwork.new()
    connection_network.name = "ConnectionNetwork"
    add_child(connection_network)

func _ready() -> void:
    _create_modules()

    var args := OS.get_cmdline_user_args()

    if "--server" in args:
        start_server()
    else:
        start_client("127.0.0.1")


func _physics_process(delta: float) -> void:
    if not multiplayer.has_multiplayer_peer():
        return

    if multiplayer.is_server():
        _server_physics_process(delta)

    _update_remote_players()


func _get_planet() -> Planet:
    if is_instance_valid(planet):
        return planet

    planet = get_tree().get_first_node_in_group("planet") as Planet
    return planet


# ============================================================
# SERVER
# ============================================================

func start_server() -> void:
    peer = ENetMultiplayerPeer.new()

    var error := peer.create_server(settings.port, settings.max_clients)

    if error != OK:
        push_error("Server startup failed: %s" % error)
        return

    multiplayer.peer_connected.connect(_on_peer_connected)
    multiplayer.peer_disconnected.connect(_on_peer_disconnected)

    multiplayer.multiplayer_peer = peer

    print("SERVER STARTED ON PORT ", settings.port)

func _on_peer_connected(id: int) -> void:
    print("PLAYER CONNECTED: ", id, " — WAITING FOR HELLO")


func _on_peer_disconnected(id: int) -> void:
    print("PLAYER DISCONNECTED: ", id)

    connected_players.erase(id)
    server_players.erase(id)

    if multiplayer.is_server():
        _broadcast_player_list()


func create_server_player(id: int) -> void:
    if not multiplayer.is_server():
        return

    if server_players.has(id):
        return

    var current_planet := _get_planet()

    if current_planet == null:
        push_error("Planet not found on server!")
        return

    var center := current_planet.to_global(
        current_planet.get_planet_center()
    )

    var spawn_direction := Vector3.UP
    var spawn_position := center + spawn_direction * (
        current_planet.RADIUS + 3.0
    )

    var server_player := ServerPlayer.new(id, spawn_position)

    server_players[id] = server_player

    print(
        "SERVER PLAYER CREATED | ID: ",
        id,
        " | POSITION: ",
        spawn_position
    )


func _server_physics_process(delta: float) -> void:
    var current_planet := _get_planet()

    if current_planet == null:
        return

    server_physics_tick += 1
    snapshot_counter += 1

    # Симулируем каждого зарегистрированного игрока.
    for id in server_players:
        var server_player: ServerPlayer = server_players[id]

        _simulate_server_player(
            server_player,
            current_planet,
            delta
        )

    # Отправляем состояния 20 раз в секунду.
    if snapshot_counter >= settings.snapshot_interval:
        snapshot_counter = 0
        _broadcast_player_states()


func _simulate_server_player(
    server_player: ServerPlayer,
    current_planet: Planet,
    _delta: float
) -> void:

    while not server_player.input_queue.is_empty():

        var frame := server_player.take_next_input()

        var result := _simulate_movement(
            current_planet,
            server_player.position,
            server_player.velocity,
            frame["move_input"],
            frame["look_direction"],
            int(frame["buttons"]),
            server_player.previous_buttons,
            float(frame["delta"])
        )

        server_player.position = result["position"]
        server_player.velocity = result["velocity"]
        server_player.heading = result["heading"]
        server_player.grounded = result["grounded"]

        server_player.finish_tick()

    # Выполняем отложенную добычу после обработки движения.
    if server_player.mine_requested:
        server_player.mine_requested = false
        _server_mine_block(server_player, current_planet)

# ============================================================
# CLIENT CONNECTION
# ============================================================

func start_client(address: String) -> void:
    peer = ENetMultiplayerPeer.new()

    var error := peer.create_client(address, settings.port)

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

    # Сохраняем существующий handshake.
    if has_node("ConnectionNetwork"):
        get_node("ConnectionNetwork").on_client_connected()


func _on_connection_failed() -> void:
    print("CONNECTION FAILED")
    multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()


func _on_server_disconnected() -> void:
    print("SERVER DISCONNECTED")

    pending_inputs.clear()
    input_sequence = 0
    local_velocity = Vector3.ZERO
    local_previous_buttons = 0


# ============================================================
# LOCAL PLAYER REGISTRATION
# ============================================================

func register_local_player(player: CharacterBody3D) -> void:
    local_player = player

    # Создаём отдельную копию для будущих удалённых игроков.
    if is_instance_valid(player_template):
        player_template.free()

    player_template = player.duplicate() as CharacterBody3D
    player_template.name = "PlayerTemplate"

    local_velocity = player.velocity

    pending_inputs.clear()
    input_sequence = 0
    local_previous_buttons = 0

    print("LOCAL PLAYER REGISTERED")

    # Создаём удалённых игроков, snapshots которых уже пришли.
    for peer_id in remote_snapshots.keys():
        if peer_id == multiplayer.get_unique_id():
            continue

        _ensure_remote_player(peer_id)


# ============================================================
# CLIENT INPUT AND PREDICTION
# ============================================================

func process_local_player(
    player: CharacterBody3D,
    delta: float,
    move_input: Vector2,
    look_direction: Vector3,
    buttons: int
) -> void:

    if player == null:
        return

    if not player.is_inside_tree():
        return

    var current_planet := _get_planet()

    if current_planet == null:
        return

    # Если это сервер, используем серверную симуляцию.
    if multiplayer.is_server():
        return

    if not Network.connection_network.connected:
        return

    # Создаём новый порядковый номер ввода.
    input_sequence += 1

    var frame := {
        "sequence": input_sequence,
        "move_input": move_input,
        "look_direction": look_direction,
        "buttons": buttons,
        "delta": delta
    }

    # Сохраняем ввод до подтверждения сервером.
    pending_inputs.append(frame)

    # Сразу выполняем локальное предсказание.
    var result := _simulate_movement(
        current_planet,
        player.global_position,
        local_velocity,
        move_input,
        look_direction,
        buttons,
        local_previous_buttons,
        delta
    )

    player.global_position = result["position"]
    local_velocity = result["velocity"]
    local_grounded = result["grounded"]

    local_previous_buttons = buttons

    player.velocity = local_velocity

    # Отправляем ввод серверу.
    submit_input.rpc_id(
        1,
        input_sequence,
        move_input,
        look_direction,
        buttons,
        delta
    )

    # Обновляем загрузку чанков.
    current_planet.update_streaming(player.global_position)


# ============================================================
# CLIENT -> SERVER INPUT RPC
# ============================================================

@rpc("any_peer", "call_remote", "reliable", 0)
func submit_input(
    sequence: int,
    move_input: Vector2,
    look_direction: Vector3,
    buttons: int,
    delta: float
) -> void:

    if not multiplayer.is_server():
        return

    var sender_id := multiplayer.get_remote_sender_id()

    if not connected_players.has(sender_id):
        return

    if not server_players.has(sender_id):
        return

    if not is_finite(delta) or delta <= 0.0 or delta > 0.1:
        return

    var server_player: ServerPlayer = server_players[sender_id]

    # Проверяем порядковый номер.
    if sequence <= server_player.last_received_input_sequence:
        return

    if sequence < 0:
        return

    # Проверяем входные значения.
    if move_input.length() > 1.01:
        return

    if look_direction.length_squared() < 0.0001:
        return

    if not _is_finite_vector2(move_input):
        return

    if not _is_finite_vector3(look_direction):
        return

    # Защита от некорректной маски кнопок.
    var allowed_buttons := NetworkProtocol.Buttons.JUMP

    if (buttons & ~allowed_buttons) != 0:
        return

    server_player.set_input(
        sequence,
        move_input,
        look_direction,
        buttons,
        delta
    )


func _is_finite_vector2(value: Vector2) -> bool:
    return (
        is_finite(value.x)
        and is_finite(value.y)
    )


func _is_finite_vector3(value: Vector3) -> bool:
    return (
        is_finite(value.x)
        and is_finite(value.y)
        and is_finite(value.z)
    )


# ============================================================
# SERVER -> CLIENT STATE
# ============================================================

# ============================================================
# SERVER -> ALL CLIENTS
# ============================================================

func _broadcast_player_states() -> void:
    if not multiplayer.is_server():
        return

    var states: Dictionary = {}

    for id in server_players:
        var server_player: ServerPlayer = server_players[id]

        states[id] = {
            "position": server_player.position,
            "velocity": server_player.velocity,
            "heading": server_player.heading,
            "acknowledged_input": server_player.last_input_sequence,
            "previous_buttons": server_player.previous_buttons
        }

    # Один общий снимок для всех клиентов.
    receive_world_snapshot.rpc(states, server_physics_tick)


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func receive_world_snapshot(
    states: Dictionary,
    server_tick: int
) -> void:

    if multiplayer.is_server():
        return

    if server_tick <= last_received_server_tick:
        return

    last_received_server_tick = server_tick

    var present_players: Dictionary = {}
    var local_id := multiplayer.get_unique_id()

    for id in states:
        var player_id := int(id)
        var state: Dictionary = states[id]

        present_players[player_id] = true

        # Нашего персонажа корректируем через reconciliation.
        if player_id == local_id:
            _reconcile_player(
                state["position"],
                state["velocity"],
                state["heading"],
                state["acknowledged_input"],
                state["previous_buttons"]
            )
            continue

        # Остальных игроков добавляем в историю снимков.
        _add_remote_snapshot(player_id, state)

    # Удаляем персонажей, которых больше нет на сервере.
    for id in remote_players.keys():
        if not present_players.has(id):
            _remove_remote_player(id)

# ============================================================
# CLIENT RECONCILIATION
# ============================================================

func _reconcile_player(
    server_position: Vector3,
    server_velocity: Vector3,
    server_heading: Vector3,
    acknowledged_input: int,
    acknowledged_buttons: int
) -> void:

    if local_player == null:
        return

    var current_planet := _get_planet()

    if current_planet == null:
        return

    # Удаляем вводы, которые сервер уже обработал.
    var remaining_inputs: Array[Dictionary] = []

    for frame in pending_inputs:
        if int(frame["sequence"]) > acknowledged_input:
            remaining_inputs.append(frame)

    pending_inputs = remaining_inputs

    # Сохраняем локальную позицию до коррекции.
    var old_position := local_player.global_position

    # Восстанавливаем авторитетное состояние сервера.
    var corrected_position := server_position
    var corrected_velocity := server_velocity

    var previous_buttons := acknowledged_buttons

    # Повторно проигрываем вводы, которые сервер ещё не подтвердил.
    for frame in pending_inputs:
        var result := _simulate_movement(
            current_planet,
            corrected_position,
            corrected_velocity,
            frame["move_input"],
            frame["look_direction"],
            int(frame["buttons"]),
            previous_buttons,
            float(frame["delta"])
        )

        corrected_position = result["position"]
        corrected_velocity = result["velocity"]

        previous_buttons = int(frame["buttons"])

    local_previous_buttons = previous_buttons

    # Устанавливаем восстановленное положение.
    local_player.global_position = corrected_position

    local_player.call(
        "apply_reconciliation_correction",
        old_position
    )

    local_velocity = corrected_velocity
    local_player.velocity = corrected_velocity

    # Разница нужна для диагностики.
    var error_distance := old_position.distance_to(corrected_position)

    if error_distance > settings.reconciliation_epsilon:
        print(
            "PLAYER RECONCILIATION | ERROR: ",
            error_distance,
            " | PENDING INPUTS: ",
            pending_inputs.size()
        )


# ============================================================
# SHARED MOVEMENT SIMULATION
# ============================================================

func _simulate_movement(
    current_planet: Planet,
    current_position: Vector3,
    current_velocity: Vector3,
    move_input: Vector2,
    look_direction: Vector3,
    buttons: int,
    previous_buttons: int,
    delta: float
) -> Dictionary:

    var center := current_planet.to_global(
        current_planet.get_planet_center()
    )

    var up := (current_position - center).normalized()

    # Направление взгляда проецируем на поверхность планеты.
    var forward := look_direction.slide(up).normalized()

    if forward.length_squared() < 0.001:
        forward = Vector3.FORWARD.slide(up).normalized()

    var right := forward.cross(up).normalized()

    # Рассчитываем направление движения.
    var move_direction := (
        right * move_input.x
        + forward * -move_input.y
    ).limit_length(1.0)

    # Разделяем горизонтальную и вертикальную скорость.
    var horizontal_velocity := current_velocity.slide(up)
    var vertical_speed := current_velocity.dot(up)

    # Ускорение и торможение.
    if move_direction.length_squared() > 0.001:
        horizontal_velocity = horizontal_velocity.move_toward(
            move_direction * settings.move_speed,
            settings.acceleration * delta
        )
    else:
        horizontal_velocity = horizontal_velocity.move_toward(
            Vector3.ZERO,
            settings.acceleration * delta
        )

    # Проверяем контакт с поверхностью.
    var ground_collision := VoxelCollision.get_capsule_collision(
        current_planet,
        current_position - up * 0.08,
        up
    )

    var grounded := (
        ground_collision.collided
        and ground_collision.normal.dot(up) > 0.5
    )

    # Проверяем нажатие прыжка.
    var jump_pressed := (
        (buttons & NetworkProtocol.Buttons.JUMP) != 0
        and (previous_buttons & NetworkProtocol.Buttons.JUMP) == 0
    )

    if jump_pressed and grounded:
        vertical_speed = settings.jump_force
        grounded = false
    elif grounded and vertical_speed < 0.0:
        vertical_speed = 0.0
    else:
        vertical_speed -= settings.gravity * delta

    var new_velocity := (
        horizontal_velocity
        + up * vertical_speed
    )

    # Выполняем перемещение с проверкой воксельных столкновений.
    var new_position := VoxelCollision.move_capsule(
        current_planet,
        current_position,
        new_velocity * delta
    )

    # Проверяем столкновение после перемещения.
    var collision := VoxelCollision.get_capsule_collision(
        current_planet,
        new_position,
        up
    )

    # Если капсула уже выталкивается из стены,
    # проверяем пространство непосредственно перед ней.
    if (
        not collision.collided
        and horizontal_velocity.length_squared() > 0.0001
    ):
        var probe_position := (
            new_position
            + horizontal_velocity.normalized() * 0.02
        )

        var probe_up := (probe_position - center).normalized()

        collision = VoxelCollision.get_capsule_collision(
            current_planet,
            probe_position,
            probe_up
        )

    # Убираем скорость, направленную внутрь препятствия.
    if collision.collided:
        var velocity_into_wall := new_velocity.dot(collision.normal)

        if velocity_into_wall < 0.0:
            new_velocity = new_velocity.slide(collision.normal)

    # Определяем новое направление относительно поверхности.
    var new_up := (new_position - center).normalized()

    var new_heading := forward.slide(new_up).normalized()

    return {
        "position": new_position,
        "velocity": new_velocity,
        "heading": new_heading,
        "grounded": grounded
    }


# ============================================================
# PLAYER LIST
# ============================================================

func _broadcast_player_list() -> void:
    if not multiplayer.is_server():
        return

    sync_player_list.rpc(connected_players)


@rpc("authority", "call_remote", "reliable", 0)
func sync_player_list(players: Dictionary) -> void:
    connected_players = players.duplicate(true)

    print("========== PLAYERS ONLINE ==========")

    for id in connected_players:
        var player_data: Dictionary = connected_players[id]

        print(
            "ID: ", id,
            " | NAME: ", player_data["name"]
        )

    print("====================================")

# ============================================================
# REMOTE PLAYERS
# ============================================================

func _add_remote_snapshot(
    player_id: int,
    state: Dictionary
) -> void:

    _ensure_remote_player(player_id)

    var history: Array = remote_snapshots.get(player_id, [])

    history.append({
        "time": Time.get_ticks_msec() / 1000.0,
        "position": state["position"],
        "velocity": state["velocity"],
        "heading": state["heading"]
    })

    while history.size() > settings.max_remote_snapshots:
        history.pop_front()

    remote_snapshots[player_id] = history


func _ensure_remote_player(peer_id: int) -> void:
    # Не создаём собственного удалённого персонажа.
    if peer_id == multiplayer.get_unique_id():
        return

    # Проверяем существующего персонажа.
    if remote_players.has(peer_id):
        if is_instance_valid(remote_players[peer_id]):
            return

        remote_players.erase(peer_id)

    # Шаблон должен существовать и быть действительным.
    if not is_instance_valid(player_template):
        return

    var current_planet := _get_planet()

    if current_planet == null:
        return

    var remote_player := player_template.duplicate() as CharacterBody3D

    if remote_player == null:
        push_error("Failed to duplicate Player!")
        return

    remote_player.name = "RemotePlayer_%d" % peer_id
    remote_player.set("is_remote", true)
    remote_player.set("planet", current_planet)

    get_tree().current_scene.add_child(remote_player)

    remote_players[peer_id] = remote_player

    print("REMOTE PLAYER CREATED: ", peer_id)

func _remove_remote_player(player_id: int) -> void:
    if remote_players.has(player_id):
        var remote_player: Node = remote_players[player_id]

        if is_instance_valid(remote_player):
            remote_player.queue_free()

        remote_players.erase(player_id)

    remote_snapshots.erase(player_id)

    print("REMOTE PLAYER REMOVED: ", player_id)

func _update_remote_players() -> void:
    var now := Time.get_ticks_msec() / 1000.0
    var render_time := now - settings.interpolation_delay

    var center_planet := _get_planet()

    if center_planet == null:
        return

    var center := center_planet.to_global(
        center_planet.get_planet_center()
    )

    for player_id in remote_snapshots:
        if not remote_players.has(player_id):
            continue

        var remote_player: CharacterBody3D = remote_players[player_id]

        if not is_instance_valid(remote_player):
            continue

        var history: Array = remote_snapshots[player_id]

        if history.is_empty():
            continue

        # Удаляем старые снимки, оставляя два необходимых.
        while history.size() > 2:
            if history[1]["time"] <= render_time:
                history.pop_front()
            else:
                break

        var first: Dictionary = history[0]
        var second: Dictionary = history[-1]

        var first_time: float = first["time"]
        var second_time: float = second["time"]

        var weight := 0.0

        if second_time > first_time:
            weight = clampf(
                (render_time - first_time) / (second_time - first_time),
                0.0,
                1.0
            )

        var position: Vector3 = first["position"].lerp(
            second["position"],
            weight
        )

        var heading: Vector3 = first["heading"].slerp(
            second["heading"],
            weight
        ).normalized()

        var up := (position - center).normalized()

        # Применяем положение и ориентацию.
        remote_player.global_position = position
        remote_player.set("heading", heading)
        remote_player.call("update_orientation", up)

@rpc("any_peer", "call_remote", "reliable")
func request_mine() -> void:

    if not multiplayer.is_server():
        return

    var sender_id := multiplayer.get_remote_sender_id()

    if not connected_players.has(sender_id):
        return

    if not server_players.has(sender_id):
        return

    var server_player: ServerPlayer = server_players[sender_id]

    server_player.mine_requested = true

@rpc("authority", "call_remote", "reliable")
func receive_block_destroyed(cell: Vector3i) -> void:
    if multiplayer.is_server():
        return

    var current_planet := _get_planet()

    if current_planet == null:
        return

    current_planet.destroy_block(cell)


func _server_mine_block(
    server_player: ServerPlayer,
    current_planet: Planet
) -> void:
    

    var center := current_planet.to_global(
        current_planet.get_planet_center()
    )

    var up := (
        server_player.position - center
    ).normalized()

    var ray_origin := server_player.position + up * 0.8

    var ray_direction := server_player.look_direction.normalized()

    var cell := current_planet.get_mined_cell(
        ray_origin,
        ray_direction,
        settings.mining_distance
    )

    if cell == Vector3i(-1, -1, -1):
        return

    if not current_planet.destroy_block(cell):
        return

    receive_block_destroyed.rpc(cell)

    print(
        "SERVER MINE | POSITION: ",
        server_player.position,
        " | LOOK: ",
        server_player.look_direction,
        " | CELL: ",
        cell
    )
