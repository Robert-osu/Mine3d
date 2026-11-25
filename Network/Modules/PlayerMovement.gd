
extends RefCounted
class_name PlayerMovement


const MOVE_SPEED: float = 50.0
const ACCELERATION: float = 20.0
const GRAVITY: float = 6.6
const JUMP_FORCE: float = 10.5

const MIN_DIRECTION_LENGTH: float = 0.001


# Выполняет один физический шаг симуляции.
# Вызывается как сервером, так и клиентом.
static func simulate(
    planet: Planet,
    position: Vector3,
    velocity: Vector3,
    move_input: Vector2,
    look_direction: Vector3,
    buttons: int,
    previous_buttons: int,
    delta: float
) -> Dictionary:

    if planet == null:
        return {
            "position": position,
            "velocity": velocity,
            "heading": Vector3.FORWARD,
            "grounded": false
        }

    var center := planet.to_global(planet.get_planet_center())
    var up := (position - center).normalized()

    # Направление взгляда проецируем на касательную плоскость.
    var forward := look_direction.slide(up).normalized()

    if forward.length_squared() < MIN_DIRECTION_LENGTH:
        forward = Vector3.FORWARD.slide(up).normalized()

    var right := forward.cross(up).normalized()

    # Рассчитываем направление движения.
    var move_direction := (
        right * move_input.x
        + forward * -move_input.y
    )

    move_direction = move_direction.limit_length(1.0)

    # Разделяем горизонтальную и вертикальную скорость.
    var horizontal_velocity := velocity.slide(up)
    var vertical_speed := velocity.dot(up)

    # Ускорение и торможение.
    if move_direction.length_squared() > MIN_DIRECTION_LENGTH:
        horizontal_velocity = horizontal_velocity.move_toward(
            move_direction * MOVE_SPEED,
            ACCELERATION * delta
        )
    else:
        horizontal_velocity = horizontal_velocity.move_toward(
            Vector3.ZERO,
            ACCELERATION * delta
        )

    # Проверяем контакт с поверхностью небольшим смещением вниз.
    var ground_collision := VoxelCollision.get_capsule_collision(
        planet,
        position - up * 0.08,
        up
    )

    var grounded := (
        ground_collision.collided
        and ground_collision.normal.dot(up) > 0.5
    )

    # Определяем новое нажатие прыжка.
    var jump_pressed := (
        (buttons & NetworkProtocol.Buttons.JUMP) != 0
        and (previous_buttons & NetworkProtocol.Buttons.JUMP) == 0
    )

    if jump_pressed and grounded:
        vertical_speed = JUMP_FORCE
        grounded = false
    elif grounded and vertical_speed < 0.0:
        vertical_speed = 0.0
    else:
        vertical_speed -= GRAVITY * delta

    # Объединяем скорость.
    var new_velocity := horizontal_velocity + up * vertical_speed

    # Перемещаем капсулу с проверкой воксельных столкновений.
    var new_position := VoxelCollision.move_capsule(
        planet,
        position,
        new_velocity * delta
    )

    # Проверяем столкновение после перемещения.
    var collision := VoxelCollision.get_capsule_collision(
        planet,
        new_position,
        up
    )

    if collision.collided:
        # Убираем скорость, направленную внутрь препятствия.
        new_velocity = new_velocity.slide(collision.normal)

    # Обновляем направление персонажа.
    var new_up := (new_position - center).normalized()
    var new_heading := forward.slide(new_up).normalized()

    return {
        "position": new_position,
        "velocity": new_velocity,
        "heading": new_heading,
        "grounded": grounded
    }
