extends Node
class_name WorldNetwork

# Передача состояния разрушенных блоков новому клиенту.
# Снимок отправляется небольшими надёжными пакетами по секциям.

var pending_players: Dictionary = {}

var client_expected_batches: int = -1
var client_received_batches: int = 0


func begin_player_sync(peer_id: int, player_name: String) -> bool:
    if peer_id <= 0 or pending_players.has(peer_id):
        return false

    pending_players[peer_id] = {
        "name": player_name,
        "snapshot_started": false,
        "mined_after_snapshot": []
    }

    return true


func cancel_pending_player(peer_id: int) -> void:
    pending_players.erase(peer_id)


func queue_mined_cell(cell: Vector3i) -> void:
    # Эти изменения произошли уже после снимка и должны быть
    # доставлены клиенту отдельно после подтверждения снимка.
    for peer_id in pending_players:
        var pending: Dictionary = pending_players[peer_id]

        if not bool(pending.get("snapshot_started", false)):
            continue

        var queued_cells: Array = pending.get("mined_after_snapshot", [])
        queued_cells.append(cell)
        pending["mined_after_snapshot"] = queued_cells
        pending_players[peer_id] = pending


func reset_client_sync() -> void:
    client_expected_batches = -1
    client_received_batches = 0


func _sort_section_keys(a: Vector3i, b: Vector3i) -> bool:
    if a.x != b.x:
        return a.x < b.x
    if a.y != b.y:
        return a.y < b.y
    return a.z < b.z


# Клиент запрашивает снимок после применения серверной конфигурации планеты.
@rpc("any_peer", "call_remote", "reliable", 0)
func request_world_sync() -> void:
    if not multiplayer.is_server():
        return

    var sender_id := multiplayer.get_remote_sender_id()

    if not pending_players.has(sender_id):
        return

    var pending: Dictionary = pending_players[sender_id]

    # Повторный запрос не должен запускать второй снимок.
    if bool(pending.get("snapshot_started", false)):
        return

    var current_planet := Network._get_planet()

    if current_planet == null:
        push_error("Cannot sync world: server planet not found!")
        return

    # Снимок фиксируется до отправки первой партии.
    # Все последующие добытые блоки попадут в отдельную очередь.
    var snapshot: Dictionary = current_planet.section_deltas.duplicate(true)

    pending["snapshot_started"] = true
    pending["mined_after_snapshot"] = []
    pending_players[sender_id] = pending

    var section_keys: Array = snapshot.keys()
    section_keys.sort_custom(_sort_section_keys)

    var batch_size: int = NetworkProtocol.WORLD_SYNC_SECTIONS_PER_BATCH
    var total_batches: int = int(ceili(float(section_keys.size()) / float(batch_size)))

    for batch_index in range(total_batches):
        var batch: Dictionary = {}
        var first_index := batch_index * batch_size
        var last_index := mini(first_index + batch_size, section_keys.size())

        for index in range(first_index, last_index):
            var section_key: Vector3i = section_keys[index]
            var delta: PackedByteArray = snapshot[section_key]
            batch[section_key] = delta.duplicate()

        world_sync_batch.rpc_id(
            sender_id,
            batch_index,
            total_batches,
            batch
        )

    world_sync_complete.rpc_id(sender_id, total_batches)

    print(
        "WORLD SYNC SENT | PLAYER: ",
        sender_id,
        " | SECTIONS: ",
        section_keys.size(),
        " | BATCHES: ",
        total_batches
    )


# Сервер -> клиент: одна партия изменённых секций.
@rpc("authority", "call_remote", "reliable", 0)
func world_sync_batch(
    batch_index: int,
    total_batches: int,
    deltas: Dictionary
) -> void:
    if multiplayer.is_server():
        return

    if total_batches < 0 or batch_index < 0 or batch_index >= total_batches:
        push_error("Invalid world sync batch header!")
        return

    if client_expected_batches == -1:
        client_expected_batches = total_batches

    if total_batches != client_expected_batches:
        push_error("World sync batch count changed during transfer!")
        return

    if batch_index != client_received_batches:
        push_error(
            "World sync batch out of order. Expected: ",
            client_received_batches,
            " Received: ",
            batch_index
        )
        return

    var current_planet := Network._get_planet()

    if current_planet == null:
        push_error("Cannot apply world sync: local planet not found!")
        return

    for section_key_variant in deltas:
        if typeof(section_key_variant) != TYPE_VECTOR3I:
            push_error("World sync contains an invalid section key!")
            return

        var delta_value: Variant = deltas[section_key_variant]

        if typeof(delta_value) != TYPE_PACKED_BYTE_ARRAY:
            push_error("World sync contains an invalid section delta!")
            return

        var delta: PackedByteArray = delta_value

        if delta.size() != Planet.SECTION_SIZE * Planet.SECTION_SIZE * Planet.SECTION_SIZE:
            push_error("World sync section has an invalid byte count!")
            return

        var section_key: Vector3i = section_key_variant
        current_planet.section_deltas[section_key] = delta.duplicate()

    client_received_batches += 1


# Сервер сообщает, что все партии отправлены.
@rpc("authority", "call_remote", "reliable", 0)
func world_sync_complete(total_batches: int) -> void:
    if multiplayer.is_server():
        return

    if client_expected_batches == -1:
        client_expected_batches = total_batches

    if (
        total_batches != client_expected_batches
        or client_received_batches != total_batches
    ):
        push_error(
            "World sync incomplete. Received: ",
            client_received_batches,
            " Expected: ",
            total_batches
        )
        return

    # Клиент подтверждает снимок. Сервер сначала доставит изменения,
    # случившиеся во время передачи, и только затем зарегистрирует игрока.
    confirm_world_sync.rpc_id(1)


# Клиент -> сервер: снимок применён.
@rpc("any_peer", "call_remote", "reliable", 0)
func confirm_world_sync() -> void:
    if not multiplayer.is_server():
        return

    var sender_id := multiplayer.get_remote_sender_id()

    if not pending_players.has(sender_id):
        return

    var pending: Dictionary = pending_players[sender_id]

    if not bool(pending.get("snapshot_started", false)):
        return

    # Сначала доставляем все изменения, произошедшие после снимка.
    var queued_cells: Array = pending.get("mined_after_snapshot", [])

    for cell_variant in queued_cells:
        var cell: Vector3i = cell_variant
        Network.receive_block_destroyed.rpc_id(sender_id, cell)

    # Только теперь игрок становится полноценным участником мира.
    Network.create_server_player(sender_id)

    Network.connected_players[sender_id] = {
        "name": str(pending.get("name", "Player"))
    }

    pending_players.erase(sender_id)

    Network._broadcast_player_list()
    world_sync_accepted.rpc_id(sender_id)

    print("PLAYER WORLD SYNC COMPLETE: ", sender_id)


# Сервер подтверждает завершение синхронизации.
@rpc("authority", "call_remote", "reliable", 0)
func world_sync_accepted() -> void:
    if multiplayer.is_server():
        return

    Network.connection_network.connected = true

    print("JOIN ACCEPTED")
    print("MY NETWORK ID: ", multiplayer.get_unique_id())
    print("CONNECTED TO SERVER WORLD")
