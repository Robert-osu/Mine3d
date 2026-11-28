extends RefCounted
class_name BotController

# Управление созданием серверных игроков-ботов.
# Поведение и автоматическое движение ботов намеренно отсутствуют.

const BOT_ID_START: int = -1000000
const MAX_CONFIGURED_BOTS: int = 32

var network: Node
var next_bot_id: int = BOT_ID_START
var configured_bot_count: int = 0
var configured_bots_spawned: bool = false
var bot_counter: int = 0


func setup(network_node: Node) -> void:
	network = network_node


func configure_from_args(args: PackedStringArray) -> void:
	configured_bot_count = 0
	for index in range(args.size()):
		var argument: String = args[index]
		if argument.begins_with("--bots="):
			configured_bot_count = clampi(
				argument.trim_prefix("--bots=").to_int(),
				0,
				MAX_CONFIGURED_BOTS
			)
			return
		if argument == "--bots" and index + 1 < args.size():
			configured_bot_count = clampi(
				args[index + 1].to_int(),
				0,
				MAX_CONFIGURED_BOTS
			)
			return


func create_bot_player(requested_name: String = "") -> int:
	if not network.multiplayer.is_server():
		push_warning("Only the server can create bot players.")
		return 0

	if network._get_planet() == null:
		push_error("Cannot create bot: planet not found.")
		return 0

	var active_bot_count := 0
	for player_variant in network.server_players.values():
		var existing_player: ServerPlayer = player_variant
		if existing_player.is_bot:
			active_bot_count += 1

	if active_bot_count >= MAX_CONFIGURED_BOTS:
		push_warning("Bot limit reached: %d" % MAX_CONFIGURED_BOTS)
		return 0

	while network.server_players.has(next_bot_id) or network.connected_players.has(next_bot_id):
		next_bot_id -= 1

	var bot_id := next_bot_id
	next_bot_id -= 1

	network.create_server_player(bot_id)
	if not network.server_players.has(bot_id):
		return 0

	bot_counter += 1
	var bot_name := requested_name.strip_edges()
	if bot_name.is_empty():
		bot_name = "Bot %d" % bot_counter
	bot_name = bot_name.left(NetworkProtocol.MAX_PLAYER_NAME_LENGTH)

	var bot: ServerPlayer = network.server_players[bot_id]
	bot.is_bot = true
	bot.look_direction = bot.heading

	network.connected_players[bot_id] = {
		"name": bot_name,
		"is_bot": true
	}

	print("BOT PLAYER CREATED | ID: %d | NAME: %s" % [bot_id, bot_name])
	network._broadcast_player_list()
	return bot_id


# Поиск распределяется по физическим тикам; добыча — не чаще раза в секунду.
# При радиусе 10 сканируется 21^3 = 9261 клетка, по 160 клеток за тик.
# Бот не задаёт движение и не меняет направление взгляда.
const BOT_MINE_INTERVAL_SECONDS: float = 1.0
const BOT_SEARCH_CELLS_PER_TICK: int = 160


func update_actions(bot: ServerPlayer, current_planet: Planet) -> void:
	bot.move_input = Vector2.ZERO
	bot.buttons = 0

	if not bot.bot_search_active and not bot.bot_search_complete:
		_start_block_search(bot, current_planet)

	if bot.bot_search_active:
		_process_block_search(bot, current_planet)

	if not bot.bot_search_complete:
		return

	var mine_interval_ticks: int = ceili(
		BOT_MINE_INTERVAL_SECONDS * Engine.physics_ticks_per_second
	)
	if network.server_physics_tick - bot.bot_last_mine_tick < mine_interval_ticks:
		return

	# Даже если блок не найден или уже разрушен другим ботом,
	# следующая добыча будет разрешена только через секунду.
	var target_cell: Vector3i = bot.bot_search_nearest_cell
	bot.bot_last_mine_tick = network.server_physics_tick
	bot.bot_search_complete = false

	if target_cell.x < 0:
		return
	if not current_planet.destroy_block(target_cell):
		return

	if is_instance_valid(network.world_network):
		network.world_network.queue_mined_cell(target_cell)

	network.receive_block_destroyed.rpc(target_cell)
	print("BOT MINED BLOCK | ID: %d | CELL: %s" % [bot.peer_id, target_cell])


func _start_block_search(bot: ServerPlayer, current_planet: Planet) -> void:
	var mining_distance: float = float(network.settings.mining_distance)
	var local_position: Vector3 = current_planet.to_local(bot.position)

	bot.bot_search_local_position = local_position
	bot.bot_search_radius = ceili(mining_distance)
	bot.bot_search_center_cell = Vector3i(
		floori(local_position.x / current_planet.BLOCK_SIZE),
		floori(local_position.y / current_planet.BLOCK_SIZE),
		floori(local_position.z / current_planet.BLOCK_SIZE)
	)
	bot.bot_search_max_distance_squared = mining_distance * mining_distance
	bot.bot_search_nearest_distance_squared = bot.bot_search_max_distance_squared
	bot.bot_search_nearest_cell = Vector3i(-1, -1, -1)
	bot.bot_search_cursor = 0
	bot.bot_search_active = true


func _process_block_search(bot: ServerPlayer, current_planet: Planet) -> void:
	var side: int = bot.bot_search_radius * 2 + 1
	var total_cells: int = side * side * side
	var processed: int = 0
	var center: Vector3i = bot.bot_search_center_cell
	var origin: Vector3 = bot.bot_search_local_position
	var block_size: float = current_planet.BLOCK_SIZE

	while (
		bot.bot_search_cursor < total_cells
		and processed < BOT_SEARCH_CELLS_PER_TICK
	):
		var cursor: int = bot.bot_search_cursor
		bot.bot_search_cursor += 1
		processed += 1

		var x_offset: int = posmod(cursor, side)
		var y_offset: int = posmod(floori(float(cursor) / float(side)), side)
		var z_offset: int = floori(float(cursor) / float(side * side))

		var cell := Vector3i(
			center.x + x_offset - bot.bot_search_radius,
			center.y + y_offset - bot.bot_search_radius,
			center.z + z_offset - bot.bot_search_radius
		)
		var block_center: Vector3 = (
			Vector3(cell) + Vector3(0.5, 0.5, 0.5)
		) * block_size
		var distance_squared: float = origin.distance_squared_to(block_center)

		if distance_squared >= bot.bot_search_nearest_distance_squared:
			continue
		if not current_planet.is_block_visible(cell):
			continue

		bot.bot_search_nearest_distance_squared = distance_squared
		bot.bot_search_nearest_cell = cell

	if bot.bot_search_cursor >= total_cells:
		bot.bot_search_active = false
		bot.bot_search_complete = true


func spawn_configured_bots_if_needed() -> void:
	if configured_bots_spawned:
		return
	configured_bots_spawned = true

	for index in range(configured_bot_count):
		create_bot_player("Bot %d" % (index + 1))

	if configured_bot_count > 0:
		print("BOT PLAYERS READY | COUNT: %d" % configured_bot_count)
