
extends RefCounted
class_name ServerPlayer

# отвечает за скорость, ускорение, гравитацию и прыжки

const BLOCK_SIZE: float = 1.0

const COLLISION_RADIUS: float = VoxelCollision.COLLISION_RADIUS
const COLLISION_HEIGHT: float = VoxelCollision.COLLISION_HEIGHT


# Идентификатор сетевого соединения.
var peer_id: int

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

# Порядковый номер последнего ввода.
var last_input_sequence := -1


# Параметры движения.
const MOVE_SPEED := 50.0
const ACCELERATION := 20.0
const GRAVITY := 6.6
const JUMP_FORCE := 10.5


func _init(id: int, spawn_position: Vector3) -> void:
    peer_id = id
    position = spawn_position


# Сохраняем полученное управление.
func set_input(
    sequence: int,
    new_move_input: Vector2,
    new_look_direction: Vector3,
    new_buttons: int
) -> void:
    if sequence <= last_input_sequence:
        return

    last_input_sequence = sequence

    move_input = new_move_input.limit_length(1.0)
    look_direction = new_look_direction.normalized()
    buttons = new_buttons


# Проверяем, было ли только что нажато действие.
func is_button_just_pressed(button: int) -> bool:
    return (
        (buttons & button) != 0
        and (previous_buttons & button) == 0
    )


# Завершаем обработку текущего физического шага.
func finish_tick() -> void:
    previous_buttons = buttons

func test_move(planet: Planet, delta: float) -> void:
    var movement := heading * MOVE_SPEED * delta

    position = VoxelCollision.move_capsule(
        planet,
        position,
        movement
    )

    

var grounded: bool = false



