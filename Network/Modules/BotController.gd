extends RefCounted
class_name BotController

# Логика поведения серверных ботов.
# Network передаёт сюда ServerPlayer и Planet, а физику по-прежнему
# выполняет общий серверный симулятор.

const INVALID_MINED_CELL := Vector3i(-1, -1, -1)

var network: Node


const BOT_ID_START: int = -1000000
const MAX_CONFIGURED_BOTS: int = 32

var next_bot_id: int = BOT_ID_START
var configured_bot_count: int = 0
var configured_bots_spawned: bool = false
var bot_counter: int = 0


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


func spawn_configured_bots_if_needed() -> void:
	if configured_bots_spawned:
		return
	configured_bots_spawned = true

	for index in range(configured_bot_count):
		create_bot_player("Bot %d" % (index + 1))

	if configured_bot_count > 0:
		print("BOT PLAYERS READY | COUNT: %d" % configured_bot_count)


func capture_orientation(bot: ServerPlayer, current_planet: Planet) -> Dictionary:
	return {
		"heading": bot.heading,
		"up": surface_up(bot, current_planet)
	}


func restore_orientation(
	bot: ServerPlayer,
	current_planet: Planet,
	previous_orientation: Dictionary
) -> void:
	var up_after := surface_up(bot, current_planet)
	bot.heading = network._transport_tangent_heading(
		previous_orientation["heading"],
		previous_orientation["up"],
		up_after
	)


func setup(network_node: Node) -> void:
	network = network_node


# Первая проверка — один ряд. После него бот останавливается,
# чтобы можно было проверить базовые действия до реализации квадрата.
const BOT_TEST_ROW_LENGTH: int = 32
const BOT_ACTION_INTERVAL_TICKS: int = 60
const BOT_STEP_DISTANCE: float = 0.85
const BOT_STEP_TIMEOUT_TICKS: int = 120

const BOT_PHASE_MINE_BELOW: int = 0
const BOT_PHASE_MINE_FORWARD: int = 1
const BOT_PHASE_STEP_FORWARD: int = 2
const BOT_PHASE_DONE: int = 3


func surface_up(bot: ServerPlayer, current_planet: Planet) -> Vector3:
	var center := current_planet.to_global(current_planet.get_planet_center())
	return (bot.position - center).normalized()


# Действие: посмотреть под ноги.
func _bot_look_down(bot: ServerPlayer, current_planet: Planet) -> void:
	bot.look_direction = -surface_up(bot, current_planet)


# Действие: посмотреть на блок впереди, немного опустив луч к его центру.
func _bot_look_forward(bot: ServerPlayer, current_planet: Planet) -> void:
	var up := surface_up(bot, current_planet)
	var forward := bot.heading.slide(up).normalized()
	if forward.length_squared() < 0.0001:
		forward = network._get_tangent_fallback(up)
	bot.heading = forward
	bot.look_direction = (forward - up * 0.65).normalized()


# Действия: повернуться на 90 градусов относительно локальной поверхности.
func _bot_turn_right(bot: ServerPlayer, current_planet: Planet) -> void:
	var up := surface_up(bot, current_planet)
	var forward := bot.heading.slide(up).normalized()
	if forward.length_squared() < 0.0001:
		forward = network._get_tangent_fallback(up)
	bot.heading = forward.rotated(up, -PI * 0.5).normalized()
	bot.look_direction = bot.heading


func _bot_turn_left(bot: ServerPlayer, current_planet: Planet) -> void:
	var up := surface_up(bot, current_planet)
	var forward := bot.heading.slide(up).normalized()
	if forward.length_squared() < 0.0001:
		forward = network._get_tangent_fallback(up)
	bot.heading = forward.rotated(up, PI * 0.5).normalized()
	bot.look_direction = bot.heading


# Проверяет состояние конкретной ячейки после попытки добычи.
# Проверка идёт по данным мира, а не только по результату destroy_block().
func _bot_is_block_mined(current_planet: Planet, cell: Vector3i) -> bool:
	return not current_planet.is_solid(cell.x, cell.y, cell.z)


# Проверяет, что координаты игрока действительно изменились.
func _bot_position_changed(
	start_position: Vector3,
	current_position: Vector3,
	min_distance: float = 0.05
) -> bool:
	return start_position.distance_squared_to(current_position) >= min_distance * min_distance


# Проверяет завершение шага по фактическому перемещению вдоль заданного направления.
func _bot_has_completed_step(bot: ServerPlayer) -> bool:
	if not _bot_position_changed(
		bot.bot_step_start_position,
		bot.position
	):
		return false

	var travelled := (bot.position - bot.bot_step_start_position).dot(
		bot.bot_step_forward
	)
	return travelled >= BOT_STEP_DISTANCE


# Действие: разрушить блок, на который сейчас направлен взгляд.
# Используется тот же DDA и тот же путь репликации, что и у игрока.
func _bot_mine_looked_at(bot: ServerPlayer, current_planet: Planet) -> bool:
	if not bot.grounded:
		return false

	var up := surface_up(bot, current_planet)
	var ray_origin := bot.position + up * 0.15
	var ray_direction := bot.look_direction.normalized()
	var mined_cell := current_planet.get_mined_cell(
		ray_origin,
		ray_direction,
		network.settings.mining_distance
	)

	if mined_cell == INVALID_MINED_CELL:
		print("BOT ACTION | MINE MISS | ID: %d | LOOK: %s" % [
			bot.peer_id, ray_direction
		])
		return false

	if not current_planet.destroy_block(mined_cell):
		return false

	if is_instance_valid(network.world_network):
		network.world_network.queue_mined_cell(mined_cell)
	network.receive_block_destroyed.rpc(mined_cell)

	if not _bot_is_block_mined(current_planet, mined_cell):
		push_warning("BOT MINE VERIFY FAILED | ID: %d | CELL: %s" % [
			bot.peer_id, mined_cell
		])
		return false

	print("BOT ACTION | MINE VERIFIED | ID: %d | CELL: %s" % [bot.peer_id, mined_cell])
	return true


# Действие: идти вперёд. Перемещение выполняется общей физикой ниже,
# а не изменением позиции напрямую.
func _bot_step_forward(bot: ServerPlayer) -> void:
	bot.move_input = Vector2(0.0, -1.0)


func prepare_input(bot: ServerPlayer, current_planet: Planet) -> void:
	bot.buttons = 0
	bot.previous_buttons = 0

	var up := surface_up(bot, current_planet)
	var forward := bot.heading.slide(up).normalized()
	if forward.length_squared() < 0.0001:
		forward = network._get_tangent_fallback(up)
	bot.heading = forward

	if bot.bot_action_phase == BOT_PHASE_STEP_FORWARD:
		_bot_step_forward(bot)
	else:
		bot.move_input = Vector2.ZERO


func update_actions(bot: ServerPlayer, current_planet: Planet) -> void:
	if bot.bot_action_phase == BOT_PHASE_DONE:
		return

	if bot.bot_action_phase == BOT_PHASE_STEP_FORWARD:
		bot.bot_step_ticks += 1
		var travelled := (bot.position - bot.bot_step_start_position).dot(
			bot.bot_step_forward
		)
		if _bot_has_completed_step(bot):
			bot.move_input = Vector2.ZERO
			bot.bot_steps_completed += 1
			print("BOT ACTION | STEP COMPLETE | ID: %d | STEP: %d" % [
				bot.peer_id, bot.bot_steps_completed
			])
			if bot.bot_steps_completed >= BOT_TEST_ROW_LENGTH:
				bot.bot_action_phase = BOT_PHASE_DONE
				print("BOT TEST ROW COMPLETE | ID: %d | STEPS: %d" % [
					bot.peer_id, bot.bot_steps_completed
				])
			else:
				bot.bot_action_phase = BOT_PHASE_MINE_BELOW
				bot.bot_action_next_tick = network.server_physics_tick + BOT_ACTION_INTERVAL_TICKS
		elif bot.bot_step_ticks >= BOT_STEP_TIMEOUT_TICKS:
			bot.move_input = Vector2.ZERO
			bot.bot_action_phase = BOT_PHASE_DONE
			push_warning("BOT STEP TIMEOUT | ID: %d | DISTANCE: %.3f" % [
				bot.peer_id, travelled
			])
		return

	if not bot.grounded or network.server_physics_tick < bot.bot_action_next_tick:
		return

	bot.bot_action_next_tick = network.server_physics_tick + BOT_ACTION_INTERVAL_TICKS

	match bot.bot_action_phase:
		BOT_PHASE_MINE_BELOW:
			_bot_look_down(bot, current_planet)
			_bot_mine_looked_at(bot, current_planet)
			bot.bot_action_phase = BOT_PHASE_MINE_FORWARD

		BOT_PHASE_MINE_FORWARD:
			_bot_look_forward(bot, current_planet)
			_bot_mine_looked_at(bot, current_planet)
			var up := surface_up(bot, current_planet)
			bot.bot_step_forward = bot.heading.slide(up).normalized()
			bot.bot_step_start_position = bot.position
			bot.bot_step_ticks = 0
			bot.bot_action_phase = BOT_PHASE_STEP_FORWARD
			_bot_step_forward(bot)

# ============================================================
