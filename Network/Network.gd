
extends Node

# ============================================================
# NETWORK
# Серверная авторитетная симуляция + клиентское предсказание.
# ============================================================

var connection_network: ConnectionNetwork
var world_network: WorldNetwork


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

# Боты используют зарезервированные отрицательные ID, не пересекающиеся с ENet peer ID.
const BOT_ID_START: int = -1000000
const MAX_CONFIGURED_BOTS: int = 32
var next_bot_id: int = BOT_ID_START
var configured_bot_count: int = 0
var configured_bots_spawned: bool = false
var bot_counter: int = 0

var connected_players: Dictionary = {}
var server_players: Dictionary = {}
var spawn_slots: Dictionary = {}
var local_spawn_slot: int = 0

# Локальный персонаж клиента.
var local_player: CharacterBody3D

# Последовательность клиентских вводов.
var input_sequence: int = 0

# История вводов, которые ещё не подтверждены сервером.
var pending_inputs: Array[Dictionary] = []

# Локально найденная цель удара. На состояние мира не влияет.
# Vector2i(input_sequence, request_index) -> {cell}
var pending_mining_predictions: Dictionary = {}

const INVALID_MINED_CELL := Vector3i(-1, -1, -1)

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

# Фиксированный шаг сервера согласован с physics_ticks_per_second в project.godot.
const SERVER_TICK_DELTA: float = 1.0 / 60.0
const INPUT_TIMEOUT_TICKS: int = 30
const MAX_SERVER_INPUT_QUEUE: int = 12
const MAX_INPUT_SEQUENCE_GAP: int = 120
const INPUT_RATE_WINDOW_TICKS: int = 60
const MAX_INPUT_RPCS_PER_WINDOW: int = 90

# Защита от неограниченного ускорения падения и роста очереди ввода.
const MAX_FALL_SPEED: float = 30.0
const MAX_PENDING_INPUTS: int = 240

# ============================================================
# INITIALIZATION
# ============================================================

func _create_modules() -> void:
	connection_network = ConnectionNetwork.new()
	connection_network.name = "ConnectionNetwork"
	add_child(connection_network)

	world_network = WorldNetwork.new()
	world_network.name = "WorldNetwork"
	add_child(world_network)

func _ready() -> void:
	_create_modules()

	var args := OS.get_cmdline_user_args()

	if "--server" in args:
		configured_bot_count = _get_configured_bot_count(args)
		start_server()
	else:
		start_client("127.0.0.1")


func _get_configured_bot_count(args: PackedStringArray) -> int:
	for index in range(args.size()):
		var argument: String = args[index]

		if argument.begins_with("--bots="):
			return clampi(argument.trim_prefix("--bots=").to_int(), 0, MAX_CONFIGURED_BOTS)

		if argument == "--bots" and index + 1 < args.size():
			return clampi(args[index + 1].to_int(), 0, MAX_CONFIGURED_BOTS)

	return 0


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

	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
	if not multiplayer.peer_disconnected.is_connected(_on_peer_disconnected):
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)

	multiplayer.multiplayer_peer = peer


func _on_peer_connected(_id: int) -> void:
	pass


func _on_peer_disconnected(id: int) -> void:
	connected_players.erase(id)
	server_players.erase(id)
	spawn_slots.erase(id)

	if is_instance_valid(world_network):
		world_network.cancel_pending_player(id)

	if multiplayer.is_server():
		_broadcast_player_list()

# Все участники используют одну детерминированную раскладку спавнов.
# Золотая спираль размещает игроков компактной группой вокруг северного полюса.
const SPAWN_SPACING: float = 1.25
const SPAWN_GOLDEN_ANGLE: float = 2.399963229728653
const SPAWN_SEARCH_RADIUS: int = 24
const SPAWN_SEARCH_DEPTH: int = 12


func get_player_spawn_surface_point(
	current_planet: Planet,
	spawn_slot: int
) -> Vector3:

	if current_planet == null:
		return Vector3.ZERO

	var slot := maxi(spawn_slot, 0)
	var distance := SPAWN_SPACING * sqrt(float(slot))
	var angle := float(slot) * SPAWN_GOLDEN_ANGLE

	var local_direction := Vector3(
		cos(angle) * distance,
		current_planet.RADIUS,
		sin(angle) * distance
	).normalized()

	var center := current_planet.get_planet_center()
	var target_surface := center + local_direction * current_planet.RADIUS
	var target_cell := current_planet.get_cell(
		current_planet.to_global(target_surface)
	)

	var half_size := float(current_planet.SIZE) * 0.5
	var radius_squared := current_planet.RADIUS * current_planet.RADIUS

	# Ищем ближайшую неповреждённую верхнюю ячейку.
	# Кольца обходятся в фиксированном порядке, поэтому сервер и клиенты
	# при одинаковом снимке разрушений выберут одну и ту же точку.
	for ring in range(SPAWN_SEARCH_RADIUS + 1):
		for offset_z in range(-ring, ring + 1):
			for offset_x in range(-ring, ring + 1):
				if (
					ring > 0
					and maxi(absi(offset_x), absi(offset_z)) != ring
				):
					continue

				var cell_x := target_cell.x + offset_x
				var cell_z := target_cell.z + offset_z

				var dx := float(cell_x) + 0.5 - half_size
				var dz := float(cell_z) + 0.5 - half_size
				var remaining_radius := radius_squared - dx * dx - dz * dz

				if remaining_radius < 0.0:
					continue

				# Верхний геометрически возможный блок на этой колонке.
				var surface_y := half_size + sqrt(remaining_radius)
				var top_cell_y := floori(surface_y - 0.5)

				# Если верхний блок выкопан, пробуем блоки непосредственно под ним.
				for depth in range(SPAWN_SEARCH_DEPTH + 1):
					var candidate_cell := Vector3i(
						cell_x,
						top_cell_y - depth,
						cell_z
					)

					if candidate_cell.y < 0:
						break

					if current_planet.is_block_visible(candidate_cell):
						var cell_center := Vector3(candidate_cell) + Vector3(0.5, 0.5, 0.5)
						return current_planet.to_global(cell_center)

	# Если вокруг всей области нет подходящего блока, оставляем исходную точку:
	# обычный таймаут спавна покажет проблему, не скрывая её.
	return current_planet.to_global(target_surface)


func get_player_spawn_position(
	current_planet: Planet,
	spawn_slot: int
) -> Vector3:

	if current_planet == null:
		return Vector3.ZERO

	var surface_point := get_player_spawn_surface_point(
		current_planet,
		spawn_slot
	)
	var center := current_planet.get_planet_center()
	var surface_local := current_planet.to_local(surface_point)
	var spawn_direction := (surface_local - center).normalized()

	return current_planet.to_global(
		center + spawn_direction * (current_planet.RADIUS + 3.0)
	)

func create_server_player(id: int) -> void:
	if not multiplayer.is_server():
		return

	if server_players.has(id):
		return

	var current_planet := _get_planet()

	if current_planet == null:
		push_error("Planet not found on server!")
		return

	# Слот выделяется сервером, поэтому случайный ENet ID
	# не влияет на расстояние от общей точки появления.
	var spawn_slot := 1
	while spawn_slots.values().has(spawn_slot):
		spawn_slot += 1

	spawn_slots[id] = spawn_slot

	var spawn_position := get_player_spawn_position(
		current_planet,
		spawn_slot
	)

	var server_player := ServerPlayer.new(id, spawn_position)
	server_player.last_input_server_tick = server_physics_tick

	server_players[id] = server_player


# Создаёт серверного бота. Его ID отрицательный, поэтому он не может
# совпасть с реальным ENet peer ID. Бот реплицируется как обычный игрок.
func create_bot_player(requested_name: String = "") -> int:
	if not multiplayer.is_server():
		push_warning("Only the server can create bot players.")
		return 0

	var current_planet := _get_planet()
	if current_planet == null:
		push_error("Cannot create bot: planet not found.")
		return 0

	while server_players.has(next_bot_id) or connected_players.has(next_bot_id):
		next_bot_id -= 1

	var bot_id := next_bot_id
	next_bot_id -= 1

	create_server_player(bot_id)
	if not server_players.has(bot_id):
		return 0

	var bot_name := requested_name.strip_edges()
	if bot_name.is_empty():
		bot_counter += 1
		bot_name = "Bot %d" % bot_counter
	bot_name = bot_name.left(NetworkProtocol.MAX_PLAYER_NAME_LENGTH)

	var bot: ServerPlayer = server_players[bot_id]
	bot.is_bot = true
	bot.look_direction = bot.heading

	connected_players[bot_id] = {
		"name": bot_name,
		"is_bot": true
	}

	print("BOT PLAYER CREATED | ID: %d | NAME: %s" % [bot_id, bot_name])
	_broadcast_player_list()
	return bot_id


func _spawn_configured_bots() -> void:
	configured_bots_spawned = true

	for index in range(configured_bot_count):
		create_bot_player("Bot %d" % (index + 1))

	if configured_bot_count > 0:
		print("BOT PLAYERS READY | COUNT: %d" % server_players.size())


func _server_physics_process(_delta: float) -> void:
	var current_planet := _get_planet()

	if current_planet == null:
		return

	if not configured_bots_spawned:
		_spawn_configured_bots()

	server_physics_tick += 1
	snapshot_counter += 1

	# Симулируем каждого зарегистрированного игрока.
	for id in server_players:
		var server_player: ServerPlayer = server_players[id]

		_simulate_server_player(
			server_player,
			current_planet,
			SERVER_TICK_DELTA
		)

	# Отправляем состояния 20 раз в секунду.
	if snapshot_counter >= settings.snapshot_interval:
		snapshot_counter = 0
		_broadcast_player_states()



func _simulate_server_player(
	server_player: ServerPlayer,
	current_planet: Planet,
	delta: float
) -> void:

	# За один физический тик применяем не более одного нового input.
	# События добычи обрабатываются вместе с тем input, к которому относятся.
	var input_frame: Dictionary = {}
	if not server_player.input_queue.is_empty():
		input_frame = server_player.take_next_input()

	# При отсутствии новых пакетов не продолжаем бесконечно применять старое движение.
	if (
		input_frame.is_empty()
		and not server_player.is_bot
		and server_physics_tick - server_player.last_input_server_tick
			> INPUT_TIMEOUT_TICKS
	):
		# Клиент пропал или перестал присылать вводы.
		# Не продолжаем бесконечно ронять его персонажа под действием гравитации.
		server_player.move_input = Vector2.ZERO
		server_player.buttons = 0
		server_player.previous_buttons = 0
		server_player.velocity = Vector3.ZERO
		server_player.input_queue.clear()
		return

	# Время симуляции задаёт серверный physics tick, а не клиентский пакет.
	var result := _simulate_movement(
		current_planet,
		server_player.position,
		server_player.velocity,
		server_player.move_input,
		server_player.look_direction,
		server_player.buttons,
		server_player.previous_buttons,
		delta
	)

	server_player.position = result["position"]
	server_player.velocity = result["velocity"]
	server_player.heading = result["heading"]
	server_player.grounded = result["grounded"]

	server_player.finish_tick()

	# Добываем после применения состояния из input, содержащего удар.
	var mine_requests: int = int(input_frame.get("mine_requests", 0))
	var sequence: int = int(input_frame.get("sequence", -1))

	for request_index in range(mine_requests):
		var mined_cell := _server_mine_block(
			server_player,
			current_planet
		)
		mining_result.rpc_id(
			server_player.peer_id,
			sequence,
			request_index,
			mined_cell
		)

# ============================================================
# CLIENT CONNECTION
# ============================================================

func start_client(address: String) -> void:
	peer = ENetMultiplayerPeer.new()

	var error := peer.create_client(address, settings.port)

	if error != OK:
		push_error("Client startup failed: %s" % error)
		return

	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
	if not multiplayer.connection_failed.is_connected(_on_connection_failed):
		multiplayer.connection_failed.connect(_on_connection_failed)
	if not multiplayer.server_disconnected.is_connected(_on_server_disconnected):
		multiplayer.server_disconnected.connect(_on_server_disconnected)

	multiplayer.multiplayer_peer = peer



func _on_connected() -> void:

	# Сохраняем существующий handshake.
	if has_node("ConnectionNetwork"):
		get_node("ConnectionNetwork").on_client_connected()


func _on_connection_failed() -> void:
	push_warning("Connection to server failed.")
	_cleanup_client_connection()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	peer = null


func _on_server_disconnected() -> void:
	push_warning("Server disconnected.")
	_cleanup_client_connection()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	peer = null


func _cleanup_client_connection() -> void:
	# Сначала возвращаем локально предсказанные блоки, пока Planet ещё доступна.
	_rollback_pending_mining_predictions()

	pending_inputs.clear()
	input_sequence = 0
	local_velocity = Vector3.ZERO
	local_previous_buttons = 0
	local_grounded = false
	last_received_server_tick = -1
	correction_offset = Vector3.ZERO

	# Старые состояния игроков не должны пережить разрыв соединения.
	for player_id in remote_players.keys():
		_remove_remote_player(int(player_id))

	remote_players.clear()
	remote_snapshots.clear()
	connected_players.clear()
	local_spawn_slot = 0

	if is_instance_valid(connection_network):
		connection_network.connected = false

	if is_instance_valid(world_network):
		world_network.reset_client_state()


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
	_rollback_pending_mining_predictions()
	input_sequence = 0
	local_previous_buttons = 0


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
	buttons: int,
	mine_requests: int = 0
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
		"mine_requests": mine_requests,
		"delta": delta
	}

	# Сохраняем ввод до подтверждения сервером.
	pending_inputs.append(frame)
	if pending_inputs.size() > MAX_PENDING_INPUTS:
		pending_inputs.pop_front()

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

	# Локально определяем предполагаемую цель удара для сопоставления
	# с ответом сервера. Не вызываем destroy_block(): коллизии и данные
	# мира на клиенте меняются только после авторитетного RPC от сервера.
	for request_index in range(mine_requests):
		var predicted_cell := INVALID_MINED_CELL

		if (
			move_input.length_squared() <= 0.05
			and bool(result["grounded"])
		):
			var center := current_planet.to_global(
				current_planet.get_planet_center()
			)
			var up := (player.global_position - center).normalized()
			var ray_origin := player.global_position + up * 0.8
			var predicted_look := look_direction.normalized()

			predicted_cell = current_planet.get_mined_cell(
				ray_origin,
				predicted_look,
				settings.mining_distance
			)

		pending_mining_predictions[Vector2i(
			input_sequence,
			request_index
		)] = {
			"cell": predicted_cell
		}

	# Отправляем ввод серверу.
	submit_input.rpc_id(
		1,
		input_sequence,
		move_input,
		look_direction,
		buttons,
		delta,
		mine_requests
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
	_client_delta: float,
	mine_requests: int
) -> void:

	if not multiplayer.is_server():
		return

	var sender_id := multiplayer.get_remote_sender_id()

	if not connected_players.has(sender_id):
		return

	if not server_players.has(sender_id):
		return

	var server_player: ServerPlayer = server_players[sender_id]

	# Частота RPC ограничивается серверными тиками, не временем клиента.
	if not _allow_input_rpc(server_player):
		_reject_input(sender_id, sequence, mine_requests)
		return

	# Проверяем порядковый номер и чрезмерные скачки sequence.
	if sequence < 0 or sequence <= server_player.last_received_input_sequence:
		_reject_input(sender_id, sequence, mine_requests)
		return

	if (
		server_player.last_received_input_sequence >= 0
		and sequence - server_player.last_received_input_sequence
			> MAX_INPUT_SEQUENCE_GAP
	):
		_reject_input(sender_id, sequence, mine_requests)
		return

	# Проверяем входные значения.
	if mine_requests < 0 or mine_requests > 8:
		_reject_input(sender_id, sequence, 0)
		return

	if (
		not _is_finite_vector2(move_input)
		or move_input.length() > 1.01
		or not _is_finite_vector3(look_direction)
		or look_direction.length_squared() < 0.0001
	):
		_reject_input(sender_id, sequence, mine_requests)
		return

	# Защита от некорректной маски кнопок.
	var allowed_buttons := NetworkProtocol.Buttons.JUMP

	if (buttons & ~allowed_buttons) != 0:
		_reject_input(sender_id, sequence, mine_requests)
		return

	# Если очередь переполнена, явно отклоняем связанные с input удары,
	# чтобы клиент мог отменить локальное предсказание.
	if server_player.input_queue.size() >= MAX_SERVER_INPUT_QUEUE:
		_reject_input(sender_id, sequence, mine_requests)
		return

	server_player.set_input(
		sequence,
		move_input,
		look_direction,
		buttons,
		mine_requests,
		server_physics_tick
	)


func _allow_input_rpc(server_player: ServerPlayer) -> bool:
	if (
		server_physics_tick - server_player.input_rate_window_start_tick
		>= INPUT_RATE_WINDOW_TICKS
	):
		server_player.input_rate_window_start_tick = server_physics_tick
		server_player.input_rate_window_count = 0

	server_player.input_rate_window_count += 1
	return server_player.input_rate_window_count <= MAX_INPUT_RPCS_PER_WINDOW


func _reject_input(sender_id: int, sequence: int, mine_requests: int) -> void:
	if mine_requests >= 0 and mine_requests <= 8 and sequence >= 0:
		for request_index in range(mine_requests):
			mining_result.rpc_id(
				sender_id,
				sequence,
				request_index,
				INVALID_MINED_CELL
			)

	input_rejected.rpc_id(sender_id, sequence)


@rpc("authority", "call_remote", "reliable", 0)
func input_rejected(sequence: int) -> void:
	if multiplayer.is_server():
		return

	var remaining_inputs: Array[Dictionary] = []
	for frame in pending_inputs:
		if int(frame["sequence"]) != sequence:
			remaining_inputs.append(frame)
	pending_inputs = remaining_inputs

	for prediction_key in pending_mining_predictions.keys():
		if prediction_key.x == sequence:
			pending_mining_predictions.erase(prediction_key)


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
			"previous_buttons": server_player.previous_buttons,
			"grounded": server_player.grounded
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

	var local_id := multiplayer.get_unique_id()

	for id in states:
		var player_id := int(id)
		var state: Dictionary = states[id]

		# Снимки идут по отдельному unreliable-каналу и могут
		# прийти уже после обновления списка игроков. Не доверяем
		# одному лишь наличию ID в пакете состояния.
		if player_id != local_id and not _is_peer_connected(player_id):
			continue

		# Нашего персонажа корректируем через reconciliation.
		if player_id == local_id:
			_reconcile_player(
				state["position"],
				state["velocity"],
				state["heading"],
				state["acknowledged_input"],
				state["previous_buttons"],
				state["grounded"]
			)
			continue

		# Остальных игроков добавляем в историю снимков.
		_add_remote_snapshot(player_id, state, server_tick)

# ============================================================
# CLIENT RECONCILIATION
# ============================================================

func _reconcile_player(
	server_position: Vector3,
	server_velocity: Vector3,
	server_heading: Vector3,
	acknowledged_input: int,
	acknowledged_buttons: int,
	server_grounded: bool
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
	var corrected_heading := server_heading
	var corrected_grounded := server_grounded

	var previous_buttons := acknowledged_buttons

	# Повторно проигрываем ВСЕ вводы, которые сервер ещё не подтвердил.
	# Пропуск старых кадров даже при большом backlog приводит к потере
	# предсказанного движения и повторяющимся ошибкам reconciliation.
	for replay_index in range(pending_inputs.size()):
		var frame: Dictionary = pending_inputs[replay_index]
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
		corrected_heading = result["heading"]
		corrected_grounded = result["grounded"]

		previous_buttons = int(frame["buttons"])

	local_previous_buttons = previous_buttons
	local_velocity = corrected_velocity
	local_grounded = corrected_grounded

	# Восстанавливаем положение и ориентацию из одного состояния.
	local_player.global_position = corrected_position
	local_player.velocity = corrected_velocity

	var center := current_planet.to_global(
		current_planet.get_planet_center()
	)
	var corrected_up := (corrected_position - center).normalized()

	local_player.set(
		"heading",
		corrected_heading.slide(corrected_up).normalized()
	)
	local_player.up_direction = corrected_up
	local_player.call("update_orientation", corrected_up)

	# Смещаем только визуальную часть, сохраняя плавную коррекцию.
	local_player.call(
		"apply_reconciliation_correction",
		old_position
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
		forward = _get_tangent_fallback(up)

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

	# Общий кэш действует только в рамках этой симуляции одного тика.
	# Проверки опоры и столкновений повторно используют уже прочитанные клетки.
	var solid_cache: Dictionary = {}

	# Проверяем опору по всем контактам капсулы.
	# Самый глубокий контакт может оказаться боковой гранью блока,
	# даже если другая часть капсулы уже опирается на поверхность.
	var grounded := VoxelCollision.has_capsule_support(
		current_planet,
		current_position - up * 0.08,
		up,
		solid_cache
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
		vertical_speed = maxf(
			vertical_speed - settings.gravity * delta,
			-MAX_FALL_SPEED
		)

	var new_velocity := (
		horizontal_velocity
		+ up * vertical_speed
	)

	# Выполняем перемещение с проверкой воксельных столкновений.
	var new_position := VoxelCollision.move_capsule(
		current_planet,
		current_position,
		new_velocity * delta,
		solid_cache
	)

	# Проверяем столкновение после перемещения.
	var collision := VoxelCollision.get_capsule_collision(
		current_planet,
		new_position,
		up,
		solid_cache
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
			probe_up,
			solid_cache
		)

	# Убираем скорость, направленную внутрь препятствия.
	if collision.collided:
		var velocity_into_wall := new_velocity.dot(collision.normal)

		if velocity_into_wall < 0.0:
			new_velocity = new_velocity.slide(collision.normal)

	# Повторно проверяем опору уже в конечной позиции.
	# Это фиксирует приземление в текущем тике и не даёт гравитации
	# каждый следующий тик вдавливать капсулу в край блока.
	var new_up := (new_position - center).normalized()
	grounded = VoxelCollision.has_capsule_support(
		current_planet,
		new_position - new_up * 0.08,
		new_up,
		solid_cache
	)

	if grounded:
		var velocity_into_ground := new_velocity.dot(new_up)
		if velocity_into_ground < 0.0:
			new_velocity -= new_up * velocity_into_ground

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
	var updated_players: Dictionary = players.duplicate(true)

	# Удаляем модели и историю снимков сразу после получения
	# авторитетного списка подключённых игроков.
	for player_id in remote_players.keys():
		if not _player_list_has_id(updated_players, int(player_id)):
			_remove_remote_player(int(player_id))

	# История может существовать даже если шаблон игрока ещё
	# не был зарегистрирован и модель не успела создаться.
	for player_id in remote_snapshots.keys():
		if not _player_list_has_id(updated_players, int(player_id)):
			remote_snapshots.erase(player_id)

	connected_players = updated_players



func _player_list_has_id(player_list: Dictionary, player_id: int) -> bool:
	# Поддерживаем как integer, так и string ключи на случай
	# сериализации списка через сторонний транспорт.
	return player_list.has(player_id) or player_list.has(str(player_id))


func _is_peer_connected(player_id: int) -> bool:
	return _player_list_has_id(connected_players, player_id)

# ============================================================
# REMOTE PLAYERS
# ============================================================

func _add_remote_snapshot(
	player_id: int,
	state: Dictionary,
	server_tick: int
) -> void:

	# Повторная защита на уровне добавления снимка: даже если
	# функция будет вызвана из другого места, отключённый игрок
	# не получит новую историю или модель.
	if player_id == multiplayer.get_unique_id() or not _is_peer_connected(player_id):
		return

	var history: Array = remote_snapshots.get(player_id, [])

	# Не допускаем дубликаты и откат истории назад по серверному времени.
	if not history.is_empty():
		var latest_tick: int = int(history[-1]["server_tick"])
		if server_tick <= latest_tick:
			return

	history.append({
		"server_tick": server_tick,
		"received_at": Time.get_ticks_msec() / 1000.0,
		"position": state["position"],
		"velocity": state["velocity"],
		"heading": state["heading"]
	})

	var history_limit: int = maxi(settings.max_remote_snapshots, 2)
	while history.size() > history_limit:
		history.pop_front()

	remote_snapshots[player_id] = history

	# Создаём модель только после проверки принадлежности ID
	# актуальному списку и проверки самого снимка.
	_ensure_remote_player(player_id)


func _transport_tangent_heading(
	heading: Vector3,
	from_up: Vector3,
	to_up: Vector3
) -> Vector3:
	var source_up := from_up.normalized()
	var target_up := to_up.normalized()
	var tangent_heading := heading.slide(source_up).normalized()

	if tangent_heading.length_squared() < 0.0001:
		tangent_heading = _get_tangent_fallback(source_up)

	# Параллельно переносим направление кратчайшим поворотом между нормалями.
	var transport_rotation := Quaternion(source_up, target_up)
	var transported := (transport_rotation * tangent_heading).slide(target_up).normalized()

	if transported.length_squared() < 0.0001:
		transported = _get_tangent_fallback(target_up)

	return transported


# Выбираем мировую ось, наименее параллельную нормали поверхности.
# Поэтому проекция не вырождается ни на одном из полюсов.
func _get_tangent_fallback(up: Vector3) -> Vector3:
	var surface_up := up.normalized()
	var fallback_axis := Vector3.RIGHT
	var alignment := absf(surface_up.dot(fallback_axis))

	if absf(surface_up.dot(Vector3.UP)) < alignment:
		fallback_axis = Vector3.UP
		alignment = absf(surface_up.dot(fallback_axis))

	if absf(surface_up.dot(Vector3.FORWARD)) < alignment:
		fallback_axis = Vector3.FORWARD

	return fallback_axis.slide(surface_up).normalized()


func _interpolate_spherical_position(
	first_position: Vector3,
	second_position: Vector3,
	center: Vector3,
	weight: float
) -> Vector3:
	var first_offset := first_position - center
	var second_offset := second_position - center
	var first_radius := first_offset.length()
	var second_radius := second_offset.length()

	if first_radius < 0.0001 or second_radius < 0.0001:
		return first_position.lerp(second_position, weight)

	var first_up := first_offset / first_radius
	var second_up := second_offset / second_radius
	var interpolated_up := first_up.slerp(second_up, weight).normalized()
	var interpolated_radius := lerpf(first_radius, second_radius, weight)

	return center + interpolated_up * interpolated_radius


func _interpolate_tangent_heading(
	first_heading: Vector3,
	first_up: Vector3,
	second_heading: Vector3,
	second_up: Vector3,
	target_up: Vector3,
	weight: float
) -> Vector3:
	var first_transported := _transport_tangent_heading(
		first_heading,
		first_up,
		target_up
	)
	var second_transported := _transport_tangent_heading(
		second_heading,
		second_up,
		target_up
	)

	var angle := first_transported.signed_angle_to(
		second_transported,
		target_up
	)
	return first_transported.rotated(
		target_up,
		angle * weight
	).slide(target_up).normalized()


func _ensure_remote_player(peer_id: int) -> void:
	# Не создаём собственного или уже отключённого персонажа.
	if peer_id == multiplayer.get_unique_id() or not _is_peer_connected(peer_id):
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

func _remove_remote_player(player_id: int) -> void:
	if remote_players.has(player_id):
		var remote_player: Node = remote_players[player_id]

		if is_instance_valid(remote_player):
			remote_player.queue_free()

		remote_players.erase(player_id)

	remote_snapshots.erase(player_id)

# Максимальное время движения без свежего снимка.
const MAX_REMOTE_EXTRAPOLATION: float = 0.12


func _update_remote_players() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var interpolation_delay_ticks := (
		settings.interpolation_delay / SERVER_TICK_DELTA
	)

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

		var latest: Dictionary = history[-1]
		var latest_tick: int = int(latest["server_tick"])
		var latest_received_at: float = float(latest["received_at"])

		# Оцениваем текущий серверный тик по времени, прошедшему
		# с получения последнего снимка. Часы клиента и сервера
		# не сравниваются напрямую.
		var estimated_server_tick := (
			float(latest_tick)
			+ maxf(now - latest_received_at, 0.0) / SERVER_TICK_DELTA
		)
		var render_tick := estimated_server_tick - interpolation_delay_ticks

		# Оставляем снимок до render_tick и следующий за ним.
		while history.size() > 2:
			if float(history[1]["server_tick"]) <= render_tick:
				history.pop_front()
			else:
				break

		var first: Dictionary = history[0]
		var first_tick: float = float(first["server_tick"])

		# Для интерполяции берём ближайший снимок ПОСЛЕ render_tick,
		# а не самый новый снимок из всей истории.
		var second: Dictionary = first
		if history.size() > 1:
			second = history[1]
		var second_tick: float = float(second["server_tick"])

		var position: Vector3
		var heading: Vector3
		var up: Vector3

		if render_tick > second_tick:
			# Нет снимка для целевого тика: кратковременно прогнозируем
			# положение по последней серверной скорости.
			var extrapolation_time := minf(
				(render_tick - second_tick) * SERVER_TICK_DELTA,
				MAX_REMOTE_EXTRAPOLATION
			)
			var latest_position: Vector3 = latest["position"]
			var latest_velocity: Vector3 = latest["velocity"]
			position = latest_position + latest_velocity * extrapolation_time
			up = (position - center).normalized()

			var latest_up := (latest_position - center).normalized()
			heading = _transport_tangent_heading(
				latest["heading"],
				latest_up,
				up
			)
		else:
			var weight := 0.0

			if second_tick > first_tick:
				weight = clampf(
					(render_tick - first_tick) / (second_tick - first_tick),
					0.0,
					1.0
				)

			position = _interpolate_spherical_position(
				first["position"],
				second["position"],
				center,
				weight
			)
			up = (position - center).normalized()

			var first_up: Vector3 = (first["position"] as Vector3 - center).normalized()
			var second_up: Vector3 = (second["position"] as Vector3 - center).normalized()
			heading = _interpolate_tangent_heading(
				first["heading"],
				first_up,
				second["heading"],
				second_up,
				up,
				weight
			)

		# Обновляем базис каждый кадр из нормали и касательного heading.
		# update_orientation сам ортонормализует итоговую ориентацию.
		remote_player.global_position = position
		remote_player.up_direction = up
		remote_player.set("heading", heading)
		remote_player.call("update_orientation", up)


@rpc("authority", "call_remote", "reliable")
func receive_block_destroyed(cell: Vector3i) -> void:
	if multiplayer.is_server():
		return

	var current_planet := _get_planet()

	if current_planet == null:
		return

	if not current_planet.is_block_destroyed(cell):
		current_planet.destroy_block(cell)


@rpc("authority", "call_remote", "reliable")
func mining_result(
	sequence: int,
	request_index: int,
	server_cell: Vector3i
) -> void:
	if multiplayer.is_server():
		return

	var current_planet := _get_planet()
	if current_planet == null:
		return

	var prediction_key := Vector2i(sequence, request_index)
	pending_mining_predictions.erase(prediction_key)

	# Только сервер определяет, какой блок действительно добыт.
	# Если receive_block_destroyed ещё не пришёл, применяем результат здесь.
	if (
		server_cell != INVALID_MINED_CELL
		and not current_planet.is_block_destroyed(server_cell)
	):
		current_planet.destroy_block(server_cell)


func _rollback_pending_mining_predictions() -> void:
	# Локальные цели ударов не меняют мир, поэтому при disconnect
	# достаточно очистить ожидающие запросы.
	pending_mining_predictions.clear()


func _server_mine_block(
	server_player: ServerPlayer,
	current_planet: Planet
) -> Vector3i:

	var center := current_planet.to_global(
		current_planet.get_planet_center()
	)

	var up := (
		server_player.position - center
	).normalized()

	# Запрещаем добычу при активном движении по поверхности
	# и в воздухе. Остаточная скорость при опоре не блокирует удар.
	if server_player.move_input.length_squared() > 0.05:
		return INVALID_MINED_CELL

	if not server_player.grounded:
		return INVALID_MINED_CELL

	var ray_origin := server_player.position + up * 0.8
	var ray_direction := server_player.look_direction.normalized()

	var cell := current_planet.get_mined_cell(
		ray_origin,
		ray_direction,
		settings.mining_distance
	)

	if cell == INVALID_MINED_CELL:
		return INVALID_MINED_CELL

	if not current_planet.destroy_block(cell):
		return INVALID_MINED_CELL

	# Клиенты, которые ещё получают снимок мира, получат это изменение
	# отдельным событием после завершения передачи снимка.
	if is_instance_valid(world_network):
		world_network.queue_mined_cell(cell)

	receive_block_destroyed.rpc(cell)
	return cell
