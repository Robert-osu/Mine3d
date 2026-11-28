extends RefCounted
class_name BotAgent

# Независимое состояние и поведение одного бота.
# Физика и репликация остаются в Network/ServerPlayer.

const MINE_INTERVAL_SECONDS: float = 1.0
const SEARCH_CELLS_PER_TICK: int = 160

var network: Node
var player: ServerPlayer

var last_mine_tick: int = -60
var search_active: bool = false
var search_complete: bool = false
var search_cursor: int = 0
var search_center_cell: Vector3i = Vector3i.ZERO
var search_local_position: Vector3 = Vector3.ZERO
var search_radius: int = 0
var search_max_distance_squared: float = 0.0
var search_nearest_cell: Vector3i = Vector3i(-1, -1, -1)
var search_nearest_distance_squared: float = 0.0


func _init(bot_player: ServerPlayer, network_node: Node) -> void:
	player = bot_player
	network = network_node


func update(current_planet: Planet) -> void:
	if not is_instance_valid(player) or current_planet == null:
		return

	player.move_input = Vector2.ZERO
	player.buttons = 0

	if not search_active and not search_complete:
		_start_block_search(current_planet)

	if search_active:
		_process_block_search(current_planet)

	if not search_complete:
		return

	var mine_interval_ticks: int = ceili(
		MINE_INTERVAL_SECONDS * Engine.physics_ticks_per_second
	)
	if network.server_physics_tick - last_mine_tick < mine_interval_ticks:
		return

	# Следующая попытка добычи разрешается не раньше чем через секунду,
	# даже если цель уже разрушена или не найдена.
	var target_cell: Vector3i = search_nearest_cell
	last_mine_tick = network.server_physics_tick
	search_complete = false

	if target_cell.x < 0:
		return
	if not current_planet.destroy_block(target_cell):
		return

	if is_instance_valid(network.world_network):
		network.world_network.queue_mined_cell(target_cell)

	network.receive_block_destroyed.rpc(target_cell)
	print("BOT MINED BLOCK | ID: %d | CELL: %s" % [player.peer_id, target_cell])


func _start_block_search(current_planet: Planet) -> void:
	var mining_distance: float = float(network.settings.mining_distance)
	var local_position: Vector3 = current_planet.to_local(player.position)

	search_local_position = local_position
	search_radius = ceili(mining_distance)
	search_center_cell = Vector3i(
		floori(local_position.x / current_planet.BLOCK_SIZE),
		floori(local_position.y / current_planet.BLOCK_SIZE),
		floori(local_position.z / current_planet.BLOCK_SIZE)
	)
	search_max_distance_squared = mining_distance * mining_distance
	search_nearest_distance_squared = search_max_distance_squared
	search_nearest_cell = Vector3i(-1, -1, -1)
	search_cursor = 0
	search_active = true


func _process_block_search(current_planet: Planet) -> void:
	var side: int = search_radius * 2 + 1
	var total_cells: int = side * side * side
	var processed: int = 0
	var center: Vector3i = search_center_cell
	var origin: Vector3 = search_local_position
	var block_size: float = current_planet.BLOCK_SIZE

	while (
		search_cursor < total_cells
		and processed < SEARCH_CELLS_PER_TICK
	):
		var cursor: int = search_cursor
		search_cursor += 1
		processed += 1

		var x_offset: int = posmod(cursor, side)
		var y_offset: int = posmod(floori(float(cursor) / float(side)), side)
		var z_offset: int = floori(float(cursor) / float(side * side))

		var cell := Vector3i(
			center.x + x_offset - search_radius,
			center.y + y_offset - search_radius,
			center.z + z_offset - search_radius
		)
		var block_center: Vector3 = (
			Vector3(cell) + Vector3(0.5, 0.5, 0.5)
		) * block_size
		var distance_squared: float = origin.distance_squared_to(block_center)

		if distance_squared >= search_nearest_distance_squared:
			continue
		if not current_planet.is_block_visible(cell):
			continue

		search_nearest_distance_squared = distance_squared
		search_nearest_cell = cell

	if search_cursor >= total_cells:
		search_active = false
		search_complete = true
