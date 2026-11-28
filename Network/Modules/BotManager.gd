extends RefCounted
class_name BotManager

# Создание ботов и управление жизненным циклом их независимых агентов.

const BOT_ID_START: int = -1000000
const MAX_CONFIGURED_BOTS: int = 32

var network: Node
var agents: Dictionary = {}
var next_agent_index: int = 0
var next_action_agent_index: int = 0
var active_action_bot_id: int = 0
var active_action_end_tick: int = 0

const GLOBAL_SEARCH_CELLS_PER_TICK: int = 320
const BOT_ACTION_DURATION_SECONDS: float = 0.5
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

	# Каждый ServerPlayer получает отдельный объект поведения и своё состояние.
	agents[bot_id] = BotAgent.new(bot, network)

	network.connected_players[bot_id] = {
		"name": bot_name,
		"is_bot": true
	}

	print("BOT PLAYER CREATED | ID: %d | NAME: %s" % [bot_id, bot_name])
	network._broadcast_player_list()
	return bot_id


func update_agents(current_planet: Planet) -> void:
	if agents.is_empty() or current_planet == null:
		return

	var agent_ids: Array = agents.keys()
	agent_ids.sort()

	var agent_count: int = agent_ids.size()
	var shared_budget_per_agent: int = maxi(
		1,
		floori(float(GLOBAL_SEARCH_CELLS_PER_TICK) / float(agent_count))
	)
	var per_agent_budget: int = mini(
		BotAgent.SEARCH_CELLS_PER_TICK,
		shared_budget_per_agent
	)

	# Сначала каждый агент продолжает собственный поиск.
	var start_index: int = posmod(next_agent_index, agent_count)
	next_agent_index = (start_index + 1) % agent_count

	for offset in range(agent_count):
		var index: int = (start_index + offset) % agent_count
		var bot_id: int = int(agent_ids[index])
		if not network.server_players.has(bot_id):
			agents.erase(bot_id)
			continue

		var agent: BotAgent = agents[bot_id]
		agent.update_search(current_planet, per_agent_budget)

	# Если действие уже выполняется, никто другой не может начать своё.
	# Результат добычи применяется только после полного времени выполнения.
	if active_action_bot_id != 0:
		if not agents.has(active_action_bot_id):
			active_action_bot_id = 0
			active_action_end_tick = 0
			return

		var active_agent: BotAgent = agents[active_action_bot_id]
		if not network.server_players.has(active_action_bot_id):
			active_agent.cancel_action()
			active_action_bot_id = 0
			active_action_end_tick = 0
			return

		if network.server_physics_tick < active_action_end_tick:
			return

		active_agent.complete_action(current_planet)
		active_action_bot_id = 0
		active_action_end_tick = 0
		return

	var remaining_agent_ids: Array = agents.keys()
	remaining_agent_ids.sort()
	var remaining_count: int = remaining_agent_ids.size()
	if remaining_count == 0:
		return

	var action_start: int = posmod(next_action_agent_index, remaining_count)
	var action_duration_ticks: int = maxi(
		1,
		ceili(BOT_ACTION_DURATION_SECONDS * Engine.physics_ticks_per_second)
	)
	for offset in range(remaining_count):
		var index: int = (action_start + offset) % remaining_count
		var bot_id: int = int(remaining_agent_ids[index])
		if not network.server_players.has(bot_id):
			continue

		var agent: BotAgent = agents[bot_id]
		if not agent.has_pending_action():
			continue

		if agent.begin_action():
			active_action_bot_id = bot_id
			active_action_end_tick = network.server_physics_tick + action_duration_ticks
			next_action_agent_index = (index + 1) % remaining_count
			return


func remove_agent(player_id: int) -> void:
	agents.erase(player_id)


func spawn_configured_bots_if_needed() -> void:
	if configured_bots_spawned:
		return
	configured_bots_spawned = true

	for index in range(configured_bot_count):
		create_bot_player("Bot %d" % (index + 1))

	if configured_bot_count > 0:
		print("BOT PLAYERS READY | COUNT: %d" % configured_bot_count)
