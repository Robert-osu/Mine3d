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
		"look_direction": bot.look_direction,
		"up": surface_up(bot, current_planet)
	}


func restore_orientation(
	bot: ServerPlayer,
	current_planet: Planet,
	previous_orientation: Dictionary
) -> void:
	var previous_up: Vector3 = previous_orientation["up"]
	var up_after := surface_up(bot, current_planet)

	bot.heading = network._transport_tangent_heading(
		previous_orientation["heading"],
		previous_up,
		up_after
	)

	# Переносим и взгляд по поверхности: сохраняем его наклон относительно
	# локального горизонта, чтобы направление движения не дрейфовало на сфере.
	var previous_look: Vector3 = previous_orientation["look_direction"]
	var look_tangent := previous_look.slide(previous_up)
	var look_vertical := previous_look.dot(previous_up)
	var transported_look: Vector3 = network._transport_tangent_heading(
		look_tangent,
		previous_up,
		up_after
	)
	bot.look_direction = (
		transported_look + up_after * look_vertical
	).normalized()


func setup(network_node: Node) -> void:
	network = network_node


# Полный алгоритм: 32 шага на ряд, возврат к началу,
# переход на следующий ряд и бесконечное расширение квадратами 32x32.
const BOT_ROW_LENGTH: int = 32
const BOT_SQUARE_SIZE: int = 32
const BOT_STEP_DISTANCE: float = 0.85
const BOT_RETURN_TOLERANCE: float = 0.45
const BOT_MIN_MINE_INTERVAL_TICKS: int = 60

const BOT_PHASE_INITIAL_MINE: int = 0
const BOT_PHASE_MINE_FORWARD: int = 1
const BOT_PHASE_STEP_FORWARD: int = 2
const BOT_PHASE_RETURN_TO_ROW_START: int = 3
const BOT_PHASE_STEP_TO_NEXT_ROW: int = 4
const BOT_PHASE_DONE: int = 5
const BOT_PHASE_WAIT_INITIAL_MINE: int = 6
const BOT_PHASE_WAIT_FORWARD_MINE: int = 7
const BOT_PHASE_WAIT_NEXT_ROW_MINE: int = 8


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


func _bot_turn_around(bot: ServerPlayer, current_planet: Planet) -> void:
	var up := surface_up(bot, current_planet)
	var forward := bot.heading.slide(up).normalized()
	if forward.length_squared() < 0.0001:
		forward = network._get_tangent_fallback(up)
	bot.heading = forward.rotated(up, PI).normalized()
	bot.look_direction = bot.heading


# Проверяет, что конкретная ячейка действительно стала пустой.
func _bot_is_block_mined(current_planet: Planet, cell: Vector3i) -> bool:
	return not current_planet.is_solid(cell.x, cell.y, cell.z)


# Возвращает ровно одну соседнюю клетку по направлению движения.
# Не ищет блоки дальше через пустые клетки: каждая пустая клетка
# всё равно должна быть пройдена отдельным физическим шагом.
func _bot_get_forward_cell(
	bot: ServerPlayer,
	current_planet: Planet
) -> Vector3i:
	if bot.bot_mining_y < 0:
		return INVALID_MINED_CELL

	var local_position: Vector3 = current_planet.to_local(bot.position)
	var local_forward: Vector3 = (
		current_planet.to_local(bot.position + bot.heading.normalized())
		- local_position
	).normalized()

	var cell := Vector3i(
		floori(local_position.x),
		bot.bot_mining_y,
		floori(local_position.z)
	)

	# Ряды участка строятся по горизонтальным осям X/Z.
	# Выбираем только одну соседнюю клетку, по доминирующей оси.
	if absf(local_forward.x) >= absf(local_forward.z):
		if is_zero_approx(local_forward.x):
			return INVALID_MINED_CELL
		cell.x += 1 if local_forward.x > 0.0 else -1
	else:
		cell.z += 1 if local_forward.z > 0.0 else -1

	return cell


# Проверяет только непосредственную соседнюю клетку на зафиксированном Y.
func _bot_has_block_ahead(bot: ServerPlayer, current_planet: Planet) -> bool:
	var target_cell := _bot_get_forward_cell(bot, current_planet)
	return (
		target_cell != INVALID_MINED_CELL
		and current_planet.is_solid(
			target_cell.x,
			target_cell.y,
			target_cell.z
		)
	)


func _bot_mine_cooldown_elapsed(bot: ServerPlayer) -> bool:
	return (
		network.server_physics_tick - bot.bot_last_mine_tick
			>= BOT_MIN_MINE_INTERVAL_TICKS
	)


# Проверяет, что координаты игрока действительно изменились.
func _bot_position_changed(
	start_position: Vector3,
	current_position: Vector3,
	min_distance: float = 0.05
) -> bool:
	return start_position.distance_squared_to(current_position) >= min_distance * min_distance


# Проверяет завершение обычного шага по фактическому перемещению.
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


# Добывает блок перед ботом и подтверждает изменение состояния мира.
func _bot_mine_looked_at(
	bot: ServerPlayer,
	current_planet: Planet,
	target_cell: Vector3i = INVALID_MINED_CELL
) -> bool:
	# Добыча доступна только стоя на земле и не чаще одного раза в секунду.
	if not bot.grounded or not _bot_mine_cooldown_elapsed(bot):
		return false

	var mined_cell := target_cell
	var ray_direction := bot.look_direction.normalized()
	if mined_cell == INVALID_MINED_CELL:
		var up := surface_up(bot, current_planet)
		var ray_origin := bot.position + up * 0.15
		mined_cell = current_planet.get_mined_cell(
			ray_origin,
			ray_direction,
			network.settings.mining_distance
		)

	if mined_cell == INVALID_MINED_CELL:
		print("BOT ACTION | MINE MISS | ID: %d | LOOK: %s" % [
			bot.peer_id, ray_direction
		])
		return false

	# Первый добытый блок задаёт постоянную высоту всей раскопки.
	# Дальше блоки с другой координатой Y не трогаем.
	if (
		bot.bot_mining_y >= 0
		and mined_cell.y != bot.bot_mining_y
	):
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

	if bot.bot_mining_y < 0:
		bot.bot_mining_y = mined_cell.y
		print("BOT ROW | MINING LEVEL LOCKED | ID: %d | Y: %d" % [
			bot.peer_id, bot.bot_mining_y
		])

	bot.bot_last_mine_tick = network.server_physics_tick
	print("BOT ACTION | MINE VERIFIED | ID: %d | CELL: %s | TICK: %d" % [
		bot.peer_id, mined_cell, bot.bot_last_mine_tick
	])
	return true


func _bot_stop(bot: ServerPlayer, reason: String) -> void:
	bot.move_input = Vector2.ZERO
	bot.bot_action_phase = BOT_PHASE_DONE
	push_warning("BOT STOPPED | ID: %d | REASON: %s" % [
		bot.peer_id, reason
	])


# Начинает один физический шаг в текущем направлении взгляда/движения.
func _bot_begin_step(bot: ServerPlayer, phase: int) -> void:
	bot.bot_step_forward = bot.heading.normalized()
	bot.bot_step_start_position = bot.position
	bot.bot_step_ticks = 0
	bot.bot_action_phase = phase
	_bot_step_forward(bot)


func _bot_step_forward(bot: ServerPlayer) -> void:
	bot.move_input = Vector2(0.0, -1.0)


# После добычи блока под ногами проверяет проход и начинает первый шаг.
# Если впереди пусто, добыча не требуется.
func _bot_start_first_row(bot: ServerPlayer, current_planet: Planet) -> void:
	bot.bot_row_start_position = bot.position
	_bot_look_forward(bot, current_planet)

	if _bot_has_block_ahead(bot, current_planet):
		if not _bot_mine_looked_at(bot, current_planet):
			_bot_stop(bot, "FIRST FORWARD BLOCK COULD NOT BE MINED")
			return

	bot.bot_steps_completed = 0
	_bot_begin_step(bot, BOT_PHASE_STEP_FORWARD)


func _bot_begin_return(bot: ServerPlayer, current_planet: Planet) -> void:
	bot.move_input = Vector2.ZERO
	_bot_turn_around(bot, current_planet)
	bot.bot_step_start_position = bot.position
	bot.bot_step_ticks = 0
	bot.bot_action_phase = BOT_PHASE_RETURN_TO_ROW_START
	_bot_step_forward(bot)
	print("BOT ROW | RETURNING | ID: %d | SQUARE: %d | ROW: %d" % [
		bot.peer_id,
		bot.bot_square_index + 1,
		bot.bot_square_row_index + 1
	])


# После возвращения в начало ряда робот поворачивает направо,
# выкапывает соседний блок, занимает его место и поворачивает налево.
func _bot_begin_next_row(
	bot: ServerPlayer,
	current_planet: Planet
) -> void:
	bot.move_input = Vector2.ZERO
	_bot_turn_around(bot, current_planet)
	_bot_turn_right(bot, current_planet)
	_bot_look_forward(bot, current_planet)
	# Поворот выполняем сразу, но добычу откладываем до cooldown и grounded.
	bot.bot_steps_completed = 0
	bot.bot_action_phase = BOT_PHASE_WAIT_NEXT_ROW_MINE


func _bot_finish_step(
	bot: ServerPlayer,
	current_planet: Planet
) -> void:
	bot.move_input = Vector2.ZERO

	if not bot.grounded:
		return

	if bot.bot_action_phase == BOT_PHASE_STEP_TO_NEXT_ROW:
		# Переход на соседний ряд завершён. Возвращаем исходное направление.
		_bot_turn_left(bot, current_planet)
		bot.bot_square_row_index += 1

		if bot.bot_square_row_index >= BOT_SQUARE_SIZE:
			bot.bot_square_index += 1
			bot.bot_square_row_index = 0
			print("BOT SQUARE COMPLETE | ID: %d | COMPLETED: %d | NEXT: %d | LEFT WALL: READY" % [
				bot.peer_id,
				bot.bot_square_index,
				bot.bot_square_index + 1
			])

		bot.bot_row_start_position = bot.position
		# Боковой шаг уже занял первый блок нового ряда.
		bot.bot_steps_completed = 1
		_bot_look_forward(bot, current_planet)
		bot.bot_action_phase = BOT_PHASE_WAIT_FORWARD_MINE
		bot.move_input = Vector2.ZERO
		print("BOT ROW | STARTED | ID: %d | SQUARE: %d | ROW: %d" % [
			bot.peer_id,
			bot.bot_square_index + 1,
			bot.bot_square_row_index + 1
		])
		return

	bot.bot_steps_completed += 1
	print("BOT ACTION | STEP VERIFIED | ID: %d | STEP: %d/%d" % [
		bot.peer_id,
		bot.bot_steps_completed,
		BOT_ROW_LENGTH
	])

	if bot.bot_steps_completed >= BOT_ROW_LENGTH:
		_bot_begin_return(bot, current_planet)
		return

	# Следующий блок добывается после секунды cooldown и подтверждения grounded.
	bot.bot_action_phase = BOT_PHASE_WAIT_FORWARD_MINE
	bot.move_input = Vector2.ZERO


func _bot_steer_toward_row_start(
	bot: ServerPlayer,
	current_planet: Planet
) -> void:
	var up := surface_up(bot, current_planet)
	var target_direction := (
		bot.bot_row_start_position - bot.position
	).slide(up).normalized()

	if target_direction.length_squared() < 0.0001:
		bot.move_input = Vector2.ZERO
		return

	# Серверная физика использует look_direction для расчёта forward.
	# Поэтому обновляем и heading, и look_direction каждый тик возврата.
	bot.heading = target_direction
	bot.look_direction = target_direction
	_bot_step_forward(bot)


func prepare_input(bot: ServerPlayer, current_planet: Planet) -> void:
	bot.buttons = 0
	bot.previous_buttons = 0

	var up := surface_up(bot, current_planet)
	var forward := bot.heading.slide(up).normalized()
	if forward.length_squared() < 0.0001:
		forward = network._get_tangent_fallback(up)
	bot.heading = forward

	if bot.bot_action_phase == BOT_PHASE_RETURN_TO_ROW_START:
		_bot_steer_toward_row_start(bot, current_planet)
	elif (
		bot.bot_action_phase == BOT_PHASE_STEP_FORWARD
		or bot.bot_action_phase == BOT_PHASE_STEP_TO_NEXT_ROW
	):
		_bot_step_forward(bot)
	else:
		bot.move_input = Vector2.ZERO


func update_actions(bot: ServerPlayer, current_planet: Planet) -> void:
	if bot.bot_action_phase == BOT_PHASE_DONE:
		return

	if not bot.grounded:
		if (
			bot.bot_action_phase == BOT_PHASE_STEP_FORWARD
			or bot.bot_action_phase == BOT_PHASE_STEP_TO_NEXT_ROW
			or bot.bot_action_phase == BOT_PHASE_RETURN_TO_ROW_START
		):
			bot.bot_step_ticks += 1
		return

	match bot.bot_action_phase:
		BOT_PHASE_INITIAL_MINE:
			_bot_look_down(bot, current_planet)
			if not _bot_mine_looked_at(bot, current_planet):
				_bot_stop(bot, "BLOCK BELOW WAS NOT MINED")
				return
			print("BOT ACTION | BELOW BLOCK VERIFIED | ID: %d" % bot.peer_id)
			bot.bot_action_phase = BOT_PHASE_WAIT_INITIAL_MINE
			bot.move_input = Vector2.ZERO

		BOT_PHASE_WAIT_INITIAL_MINE:
			if bot.grounded and _bot_mine_cooldown_elapsed(bot):
				_bot_start_first_row(bot, current_planet)

		BOT_PHASE_WAIT_FORWARD_MINE:
			if bot.grounded:
				_bot_look_forward(bot, current_planet)
				if not _bot_has_block_ahead(bot, current_planet):
					# Перед ботом уже пусто — пропускаем добычу и шагаем.
					_bot_begin_step(bot, BOT_PHASE_STEP_FORWARD)
				elif _bot_mine_cooldown_elapsed(bot):
					var target_cell := _bot_get_forward_cell(bot, current_planet)
					if not _bot_mine_looked_at(bot, current_planet, target_cell):
						_bot_stop(bot, "FORWARD BLOCK COULD NOT BE MINED")
						return
					_bot_begin_step(bot, BOT_PHASE_STEP_FORWARD)

		BOT_PHASE_WAIT_NEXT_ROW_MINE:
			if bot.grounded:
				_bot_look_forward(bot, current_planet)
				if not _bot_has_block_ahead(bot, current_planet):
					# Соседняя клетка свободна — переходим в неё без добычи.
					_bot_begin_step(bot, BOT_PHASE_STEP_TO_NEXT_ROW)
				elif _bot_mine_cooldown_elapsed(bot):
					var target_cell := _bot_get_forward_cell(bot, current_planet)
					if not _bot_mine_looked_at(bot, current_planet, target_cell):
						_bot_stop(bot, "NEXT ROW BLOCK COULD NOT BE MINED")
						return
					_bot_begin_step(bot, BOT_PHASE_STEP_TO_NEXT_ROW)

		BOT_PHASE_MINE_FORWARD:
			_bot_look_forward(bot, current_planet)
			if _bot_has_block_ahead(bot, current_planet):
				var target_cell := _bot_get_forward_cell(bot, current_planet)
				if not _bot_mine_looked_at(bot, current_planet, target_cell):
					_bot_stop(bot, "FORWARD BLOCK COULD NOT BE MINED")
					return
			_bot_begin_step(bot, BOT_PHASE_STEP_FORWARD)

		BOT_PHASE_STEP_FORWARD, BOT_PHASE_STEP_TO_NEXT_ROW:
			bot.bot_step_ticks += 1
			if _bot_has_completed_step(bot):
				_bot_finish_step(bot, current_planet)

		BOT_PHASE_RETURN_TO_ROW_START:
			bot.bot_step_ticks += 1
			var distance_to_row_start := bot.position.distance_to(
				bot.bot_row_start_position
			)
			if distance_to_row_start <= BOT_RETURN_TOLERANCE:
				bot.move_input = Vector2.ZERO
				print("BOT ROW | RETURN COMPLETE | ID: %d | DISTANCE: %.3f | TICKS: %d" % [
					bot.peer_id,
					distance_to_row_start,
					bot.bot_step_ticks
				])
				_bot_begin_next_row(bot, current_planet)

# ============================================================
