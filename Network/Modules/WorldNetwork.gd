extends Node
class_name WorldNetwork

# Передача состояния разрушенных блоков новому клиенту.
# Снимок отправляется постепенно, небольшими надёжными партиями.

const BATCHES_PER_FRAME: int = 2

var pending_players: Dictionary = {}
var next_sync_id: int = 0

var client_sync_id: int = -1
var client_expected_batches: int = -1
var client_received_batches: int = 0


func _process(_delta: float) -> void:
	if not multiplayer.is_server():
		return

	for peer_id_variant in pending_players.keys():
		var peer_id: int = int(peer_id_variant)
		if not pending_players.has(peer_id):
			continue

		var pending: Dictionary = pending_players[peer_id]
		if (
			not bool(pending.get("snapshot_started", false))
			or bool(pending.get("snapshot_send_complete", false))
		):
			continue

		var section_keys: Array = pending.get("section_keys", [])
		var total_batches: int = int(pending.get("total_batches", 0))
		var next_batch: int = int(pending.get("next_batch", 0))
		var sync_id: int = int(pending.get("sync_id", -1))
		var snapshot: Dictionary = pending.get("snapshot", {})

		var sent_this_frame := 0
		while next_batch < total_batches and sent_this_frame < BATCHES_PER_FRAME:
			var batch: Dictionary = {}
			var first_index := next_batch * NetworkProtocol.WORLD_SYNC_SECTIONS_PER_BATCH
			var last_index := mini(
				first_index + NetworkProtocol.WORLD_SYNC_SECTIONS_PER_BATCH,
				section_keys.size()
			)

			for index in range(first_index, last_index):
				var section_key: Vector3i = section_keys[index]
				var delta: PackedByteArray = snapshot[section_key]
				batch[section_key] = delta.duplicate()

			world_sync_batch.rpc_id(
				peer_id,
				sync_id,
				next_batch,
				total_batches,
				batch
			)

			next_batch += 1
			sent_this_frame += 1

		pending["next_batch"] = next_batch

		if next_batch >= total_batches:
			pending["snapshot_send_complete"] = true
			world_sync_complete.rpc_id(peer_id, sync_id, total_batches)

		pending_players[peer_id] = pending


func begin_player_sync(peer_id: int, player_name: String) -> bool:
	if peer_id <= 0 or pending_players.has(peer_id):
		return false

	next_sync_id += 1
	pending_players[peer_id] = {
		"name": player_name,
		"sync_id": next_sync_id,
		"snapshot_started": false,
		"snapshot_send_complete": false,
		"mined_after_snapshot": []
	}

	return true


func get_player_sync_id(peer_id: int) -> int:
	if not pending_players.has(peer_id):
		return -1

	return int(pending_players[peer_id].get("sync_id", -1))


func cancel_pending_player(peer_id: int) -> void:
	pending_players.erase(peer_id)


func queue_mined_cell(cell: Vector3i) -> void:
	# Изменения после фиксации снимка будут доставлены после него.
	for peer_id in pending_players:
		var pending: Dictionary = pending_players[peer_id]

		if not bool(pending.get("snapshot_started", false)):
			continue

		var queued_cells: Array = pending.get("mined_after_snapshot", [])
		queued_cells.append(cell)
		pending["mined_after_snapshot"] = queued_cells
		pending_players[peer_id] = pending


func reset_client_sync(sync_id: int) -> void:
	client_sync_id = sync_id
	client_expected_batches = -1
	client_received_batches = 0


func reset_client_state() -> void:
	# Инвалидируем любые запоздавшие сообщения предыдущего соединения.
	client_sync_id = -1
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
func request_world_sync(sync_id: int) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()

	if not pending_players.has(sender_id):
		return

	var pending: Dictionary = pending_players[sender_id]

	if (
		int(pending.get("sync_id", -1)) != sync_id
		or bool(pending.get("snapshot_started", false))
	):
		return

	var current_planet := Network._get_planet()
	if current_planet == null:
		push_error("Cannot sync world: server planet not found!")
		return

	# Снимок фиксируется один раз. Последующая добыча попадёт в отдельную очередь.
	var snapshot: Dictionary = current_planet.section_deltas.duplicate(true)
	var section_keys: Array = snapshot.keys()
	section_keys.sort_custom(Callable(self, "_sort_section_keys"))

	var batch_size: int = NetworkProtocol.WORLD_SYNC_SECTIONS_PER_BATCH
	var total_batches: int = int(ceili(float(section_keys.size()) / float(batch_size)))

	pending["snapshot_started"] = true
	pending["snapshot_send_complete"] = false
	pending["snapshot"] = snapshot
	pending["section_keys"] = section_keys
	pending["total_batches"] = total_batches
	pending["next_batch"] = 0
	pending["mined_after_snapshot"] = []
	pending_players[sender_id] = pending

	# Пустой снимок тоже корректно завершится в _process.
	if total_batches == 0:
		return


# Сервер -> клиент: одна партия изменённых секций.
@rpc("authority", "call_remote", "reliable", 0)
func world_sync_batch(
	sync_id: int,
	batch_index: int,
	total_batches: int,
	deltas: Dictionary
) -> void:
	if multiplayer.is_server() or sync_id != client_sync_id:
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

	# Сначала проверяем всю партию, чтобы не применить её частично.
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

	for section_key_variant in deltas:
		var section_key: Vector3i = section_key_variant
		var delta: PackedByteArray = deltas[section_key_variant]
		current_planet.section_deltas[section_key] = delta.duplicate()

	client_received_batches += 1


# Сервер сообщает, что все партии отправлены.
@rpc("authority", "call_remote", "reliable", 0)
func world_sync_complete(sync_id: int, total_batches: int) -> void:
	if multiplayer.is_server() or sync_id != client_sync_id:
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

	confirm_world_sync.rpc_id(1, sync_id)


# Клиент -> сервер: снимок применён.
@rpc("any_peer", "call_remote", "reliable", 0)
func confirm_world_sync(sync_id: int) -> void:
	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()
	if not pending_players.has(sender_id):
		return

	var pending: Dictionary = pending_players[sender_id]
	if (
		int(pending.get("sync_id", -1)) != sync_id
		or not bool(pending.get("snapshot_send_complete", false))
	):
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
	var spawn_slot: int = int(Network.spawn_slots.get(sender_id, 1))
	world_sync_accepted.rpc_id(sender_id, sync_id, spawn_slot)

	# Сервер подтверждает завершение синхронизации.
@rpc("authority", "call_remote", "reliable", 0)
func world_sync_accepted(sync_id: int, spawn_slot: int) -> void:
	if multiplayer.is_server() or sync_id != client_sync_id:
		return

	Network.local_spawn_slot = maxi(spawn_slot, 0)
	Network.connection_network.connected = true

			