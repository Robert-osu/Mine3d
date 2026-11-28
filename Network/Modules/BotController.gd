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


# Один раз в секунду ищет ближайший открытый блок вокруг бота и добывает его.
# Бот не задаёт движение и не меняет направление взгляда.
const BOT_MINE_INTERVAL_TICKS: int = 60


func update_actions(bot: ServerPlayer, current_planet: Planet) -> void:
	bot.move_input = Vector2.ZERO
	bot.buttons = 0

	if network.server_physics_tick - bot.bot_last_mine_tick < BOT_MINE_INTERVAL_TICKS:
		return

	# Ограничиваем частоту и поиска, даже если поблизости нет блоков.
	bot.bot_last_mine_tick = network.server_physics_tick

	var target_cell := _find_nearest_block(bot, current_planet)
	if target_cell.x < 0:
		return

	if not current_planet.destroy_block(target_cell):
		return

	if is_instance_valid(network.world_network):
		network.world_network.queue_mined_cell(target_cell)

	network.receive_block_destroyed.rpc(target_cell)
	print("BOT MINED BLOCK | ID: %d | CELL: %s" % [bot.peer_id, target_cell])


func _find_nearest_block(
	bot: ServerPlayer,
	current_planet: Planet
) -> Vector3i:
	var search_radius := int(ceil(network.settings.mining_distance))
	var local_position := current_planet.to_local(bot.position)
	var center_cell := Vector3i(
		floori(local_position.x / current_planet.BLOCK_SIZE),
		floori(local_position.y / current_planet.BLOCK_SIZE),
		floori(local_position.z / current_planet.BLOCK_SIZE)
	)

	var max_distance_squared := (
		network.settings.mining_distance
		* network.settings.mining_distance
	)
	var nearest_cell := Vector3i(-1, -1, -1)
	var nearest_distance_squared := max_distance_squared

	for z in range(center_cell.z - search_radius, center_cell.z + search_radius + 1):
		for y in range(center_cell.y - search_radius, center_cell.y + search_radius + 1):
			for x in range(center_cell.x - search_radius, center_cell.x + search_radius + 1):
				var cell := Vector3i(x, y, z)
				if not current_planet.is_block_visible(cell):
					continue

				var block_center := Vector3(cell) + Vector3(0.5, 0.5, 0.5)
				var distance_squared := local_position.distance_squared_to(block_center)
				if distance_squared >= nearest_distance_squared:
					continue

				nearest_distance_squared = distance_squared
				nearest_cell = cell

	return nearest_cell


func spawn_configured_bots_if_needed() -> void:
	if configured_bots_spawned:
		return
	configured_bots_spawned = true

	for index in range(configured_bot_count):
		create_bot_player("Bot %d" % (index + 1))

	if configured_bot_count > 0:
		print("BOT PLAYERS READY | COUNT: %d" % configured_bot_count)
