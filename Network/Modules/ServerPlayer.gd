
extends RefCounted
class_name ServerPlayer

# отвечает за скорость, ускорение, гравитацию и прыжки

const BLOCK_SIZE: float = 1.0

const COLLISION_RADIUS: float = VoxelCollision.COLLISION_RADIUS
const COLLISION_HEIGHT: float = VoxelCollision.COLLISION_HEIGHT


# Идентификатор сетевого соединения или зарезервированный ID бота.
var peer_id: int

# Боты управляются сервером и не отключаются по таймауту клиентского ввода.
var is_bot: bool = false

# Положение и скорость персонажа.
var position := Vector3.ZERO
var velocity := Vector3.ZERO

# Направление движения по поверхности.
var heading := Vector3.FORWARD

# Последнее направление взгляда.
var look_direction := Vector3.FORWARD

# Полученное от клиента управление.
var move_input := Vector2.ZERO
var buttons := 0
var previous_buttons := 0

# Последний фактически обработанный инпут.
var last_input_sequence: int = -1

# Последний принятый от клиента инпут.
var last_received_input_sequence: int = -1

# Серверные тики: время последнего принятого ввода и окно ограничения RPC.
var last_input_server_tick: int = 0
var input_rate_window_start_tick: int = 0
var input_rate_window_count: int = 0

# Очередь входящих инпутов.
var input_queue: Array[Dictionary] = []

var grounded: bool = false

# Состояние простого контроллера действий бота.
var bot_action_phase: int = 0
var bot_action_next_tick: int = 0
var bot_step_start_position: Vector3 = Vector3.ZERO
var bot_step_forward: Vector3 = Vector3.FORWARD
var bot_step_ticks: int = 0
var bot_steps_completed: int = 0
var bot_row_start_position: Vector3 = Vector3.ZERO
# Зафиксированный уровень добычи в координатах вокселей планеты.
var bot_mining_y: int = -1
var bot_square_row_index: int = 0
var bot_square_index: int = 0
# Серверный тик последнего успешно разрушенного ботом блока.
var bot_last_mine_tick: int = -1000000

# Параметры движения.
const MOVE_SPEED := 50.0
const ACCELERATION := 20.0
const GRAVITY := 6.6
const JUMP_FORCE := 10.5


func _init(id: int, spawn_position: Vector3) -> void:
    peer_id = id
    position = spawn_position

# Проверяем, было ли только что нажато действие.
func is_button_just_pressed(button: int) -> bool:
    return (
        (buttons & button) != 0
        and (previous_buttons & button) == 0
    )

func test_move(planet: Planet, delta: float) -> void:
    var movement := heading * MOVE_SPEED * delta

    position = VoxelCollision.move_capsule(
        planet,
        position,
        movement
    )

    

# Добавляем полученный инпут в очередь.
func set_input(
    sequence: int,
    new_move_input: Vector2,
    new_look_direction: Vector3,
    new_buttons: int,
    new_mine_requests: int,
    server_tick: int
) -> void:

    if sequence <= last_received_input_sequence:
        return

    last_received_input_sequence = sequence
    last_input_server_tick = server_tick

    input_queue.append({
        "sequence": sequence,
        "move_input": new_move_input.limit_length(1.0),
        "look_direction": new_look_direction.normalized(),
        "buttons": new_buttons,
        "mine_requests": new_mine_requests
    })

# Применяем следующий инпут из очереди.
func take_next_input() -> Dictionary:
    if input_queue.is_empty():
        return {}

    var frame: Dictionary = input_queue.pop_front()

    move_input = frame["move_input"]
    look_direction = frame["look_direction"]
    buttons = frame["buttons"]

    last_input_sequence = frame["sequence"]

    return frame

# Завершаем физический шаг.
func finish_tick() -> void:
    previous_buttons = buttons

