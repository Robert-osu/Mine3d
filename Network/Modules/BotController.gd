extends RefCounted
class_name BotController

# Логика поведения серверных ботов.
# Network передаёт сюда ServerPlayer и Planet, а физику по-прежнему
# выполняет общий серверный симулятор.

const INVALID_MINED_CELL := Vector3i(-1, -1, -1)

var network: Node


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
	print("BOT ACTION | MINE | ID: %d | CELL: %s" % [bot.peer_id, mined_cell])
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
		if travelled >= BOT_STEP_DISTANCE:
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
