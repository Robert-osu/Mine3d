
extends RefCounted
class_name VoxelCollision

# отвечает за:
# Проверку пересечения капсулы с блоками.
# Определение опоры под ногами.
# Проверку возможности перемещения.
# Обработку столкновений со стенами и потолком.


const COLLISION_RADIUS: float = 0.35
const COLLISION_HEIGHT: float = 1.4

class CollisionResult:
    var collided: bool = false
    var normal: Vector3 = Vector3.ZERO
    var penetration: float = 0.0

class ContactResult:
    var normal: Vector3 = Vector3.ZERO
    var penetration: float = 0.0

# Проверяет, пересекается ли капсула с твёрдыми блоками планеты.
static func is_capsule_blocked(
    planet: Planet,
    world_position: Vector3,
    world_up: Vector3
) -> bool:

    if planet == null:
        return false

    # Переводим положение капсулы в локальные координаты планеты.
    var local_position: Vector3 = planet.to_local(world_position)

    # Переводим направление оси капсулы в локальное пространство.
    var local_up: Vector3 = (
        planet.global_transform.basis.inverse() * world_up
    ).normalized()

    # Половина длины прямой части капсулы.
    var half_segment: float = (
        COLLISION_HEIGHT * 0.5 - COLLISION_RADIUS
    )

    # Два конца центрального отрезка капсулы.
    var point_a: Vector3 = local_position - local_up * half_segment
    var point_b: Vector3 = local_position + local_up * half_segment

    # Границы объёма, внутри которого могут находиться пересекаемые блоки.
    var margin := Vector3.ONE * COLLISION_RADIUS

    var bounds_min: Vector3 = Vector3(
        minf(point_a.x, point_b.x),
        minf(point_a.y, point_b.y),
        minf(point_a.z, point_b.z)
    ) - margin

    var bounds_max: Vector3 = Vector3(
        maxf(point_a.x, point_b.x),
        maxf(point_a.y, point_b.y),
        maxf(point_a.z, point_b.z)
    ) + margin

    var min_cell := Vector3i(
        floori(bounds_min.x / planet.BLOCK_SIZE),
        floori(bounds_min.y / planet.BLOCK_SIZE),
        floori(bounds_min.z / planet.BLOCK_SIZE)
    )

    var max_cell := Vector3i(
        floori(bounds_max.x / planet.BLOCK_SIZE),
        floori(bounds_max.y / planet.BLOCK_SIZE),
        floori(bounds_max.z / planet.BLOCK_SIZE)
    )

    # Проверяем только блоки в ограничивающем объёме капсулы.
    for x in range(min_cell.x, max_cell.x + 1):
        for y in range(min_cell.y, max_cell.y + 1):
            for z in range(min_cell.z, max_cell.z + 1):

                if not planet.is_solid(x, y, z):
                    continue

                var block_min := Vector3(x, y, z) * planet.BLOCK_SIZE
                var block_max := block_min + Vector3.ONE * planet.BLOCK_SIZE

                if _segment_intersects_box(
                    point_a,
                    point_b,
                    block_min,
                    block_max,
                    COLLISION_RADIUS
                ):
                    return true

    return false

# Перемещает капсулу на заданное расстояние.
# Если встречает блок, останавливается перед ним.
static func move_capsule(
    planet: Planet,
    world_position: Vector3,
    displacement: Vector3
) -> Vector3:

    if planet == null or displacement.length_squared() < 0.000001:
        return world_position

    var distance := displacement.length()

    # Размер шага ограничиваем половиной радиуса капсулы.
    var max_step := COLLISION_RADIUS * 0.5
    var steps := maxi(1, ceili(distance / max_step))

    var step_vector := displacement / float(steps)
    var current_position := world_position

    for i in range(steps):

        var remaining := step_vector

        # Несколько попыток позволяют скользить по нескольким поверхностям.
        for j in range(3):

            if remaining.length_squared() < 0.000001:
                break

            var candidate := current_position + remaining

            var planet_center := planet.to_global(
                planet.get_planet_center()
            )

            var world_up := (
                candidate - planet_center
            ).normalized()

            var collision := get_capsule_collision(
                planet,
                candidate,
                world_up
            )

            # Свободное перемещение.
            if not collision.collided:
                current_position = candidate
                break

            # Устраняем проникновение в блок.
            current_position = resolve_capsule_collision(
                planet,
                candidate,
                world_up
            )

            # Оставляем только составляющую движения,
            # направленную вдоль поверхности препятствия.
            remaining = remaining.slide(collision.normal)

    return current_position


# Проверяет расстояние между отрезком и AABB.
static func _segment_intersects_box(
    point_a: Vector3,
    point_b: Vector3,
    box_min: Vector3,
    box_max: Vector3,
    radius: float
) -> bool:

    var direction: Vector3 = point_b - point_a

    # Ищем минимальное расстояние от отрезка до AABB.
    # Функция расстояния выпуклая, поэтому используем
    # двоичное приближение через тернарный поиск.
    var left: float = 0.0
    var right: float = 1.0

    for i in range(24):
        var t1: float = left + (right - left) / 3.0
        var t2: float = right - (right - left) / 3.0

        var p1: Vector3 = point_a + direction * t1
        var p2: Vector3 = point_a + direction * t2

        var d1: float = _point_box_distance_squared(
            p1, box_min, box_max
        )

        var d2: float = _point_box_distance_squared(
            p2, box_min, box_max
        )

        if d1 < d2:
            right = t2
        else:
            left = t1

    var closest_t: float = (left + right) * 0.5
    var closest_point: Vector3 = point_a + direction * closest_t

    var distance_squared: float = _point_box_distance_squared(
        closest_point, box_min, box_max
    )

    return distance_squared <= radius * radius


# Квадрат расстояния от точки до AABB.
static func _point_box_distance_squared(
    point: Vector3,
    box_min: Vector3,
    box_max: Vector3
) -> float:

    var closest: Vector3 = point.clamp(box_min, box_max)

    return point.distance_squared_to(closest)

static func get_capsule_collision(
    planet: Planet,
    world_position: Vector3,
    world_up: Vector3
) -> CollisionResult:

    var result := CollisionResult.new()

    if planet == null:
        return result

    var local_position := planet.to_local(world_position)
    var local_up := (
        planet.global_transform.basis.inverse() * world_up
    ).normalized()

    var half_segment := COLLISION_HEIGHT * 0.5 - COLLISION_RADIUS

    var point_a := local_position - local_up * half_segment
    var point_b := local_position + local_up * half_segment

    var margin := Vector3.ONE * COLLISION_RADIUS

    var bounds_min := Vector3(
        minf(point_a.x, point_b.x),
        minf(point_a.y, point_b.y),
        minf(point_a.z, point_b.z)
    ) - margin

    var bounds_max := Vector3(
        maxf(point_a.x, point_b.x),
        maxf(point_a.y, point_b.y),
        maxf(point_a.z, point_b.z)
    ) + margin

    var min_cell := Vector3i(
        floori(bounds_min.x / planet.BLOCK_SIZE),
        floori(bounds_min.y / planet.BLOCK_SIZE),
        floori(bounds_min.z / planet.BLOCK_SIZE)
    )

    var max_cell := Vector3i(
        floori(bounds_max.x / planet.BLOCK_SIZE),
        floori(bounds_max.y / planet.BLOCK_SIZE),
        floori(bounds_max.z / planet.BLOCK_SIZE)
    )

    var best_penetration := 0.0
    var best_normal := Vector3.ZERO

    for x in range(min_cell.x, max_cell.x + 1):
        for y in range(min_cell.y, max_cell.y + 1):
            for z in range(min_cell.z, max_cell.z + 1):

                if not planet.is_solid(x, y, z):
                    continue

                var box_min := Vector3(x, y, z) * planet.BLOCK_SIZE
                var box_max := box_min + Vector3.ONE * planet.BLOCK_SIZE

                var contact := _get_segment_box_contact(
                    point_a,
                    point_b,
                    box_min,
                    box_max,
                    COLLISION_RADIUS
                )

                if contact.penetration > best_penetration:
                    best_penetration = contact.penetration
                    best_normal = contact.normal

    if best_penetration > 0.0:
        result.collided = true
        result.normal = (
            planet.global_transform.basis * best_normal
        ).normalized()
        result.penetration = best_penetration

    return result

static func _get_segment_box_contact(
    point_a: Vector3,
    point_b: Vector3,
    box_min: Vector3,
    box_max: Vector3,
    radius: float
) -> ContactResult:

    var result := ContactResult.new()

    var direction := point_b - point_a

    # Ищем ближайшую точку отрезка к AABB.
    var left := 0.0
    var right := 1.0

    for i in range(24):
        var t1 := left + (right - left) / 3.0
        var t2 := right - (right - left) / 3.0

        var p1 := point_a + direction * t1
        var p2 := point_a + direction * t2

        var d1 := _point_box_distance_squared(
            p1, box_min, box_max
        )
        var d2 := _point_box_distance_squared(
            p2, box_min, box_max
        )

        if d1 < d2:
            right = t2
        else:
            left = t1

    var t := (left + right) * 0.5
    var segment_point := point_a + direction * t

    var box_point := segment_point.clamp(box_min, box_max)

    var difference := segment_point - box_point
    var distance_squared := difference.length_squared()

    # Обычное пересечение: ось капсулы снаружи блока.
    if distance_squared > 0.000001:
        var distance := sqrt(distance_squared)

        if distance >= radius:
            return result

        result.normal = difference / distance
        result.penetration = radius - distance

        return result

    # Ось капсулы оказалась внутри блока.
    # Выбираем ближайшую грань блока.
    var distances := [
        segment_point.x - box_min.x,
        box_max.x - segment_point.x,
        segment_point.y - box_min.y,
        box_max.y - segment_point.y,
        segment_point.z - box_min.z,
        box_max.z - segment_point.z
    ]

    var normals := [
        Vector3.LEFT,
        Vector3.RIGHT,
        Vector3.DOWN,
        Vector3.UP,
        Vector3.BACK,
        Vector3.FORWARD
    ]

    var nearest_index := 0

    for i in range(1, distances.size()):
        if distances[i] < distances[nearest_index]:
            nearest_index = i

    result.normal = normals[nearest_index]
    result.penetration = radius + distances[nearest_index]

    return result

static func resolve_capsule_collision(
    planet: Planet,
    world_position: Vector3,
    world_up: Vector3
) -> Vector3:

    var position := world_position

    # Несколько проходов нужны, чтобы обработать углы,
    # где капсула одновременно касается нескольких блоков.
    for i in range(4):

        var collision := get_capsule_collision(
            planet,
            position,
            world_up
        )

        if not collision.collided:
            break

        position += collision.normal * (
            collision.penetration + 0.001
        )

    return position


