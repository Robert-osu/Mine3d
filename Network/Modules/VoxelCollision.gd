
extends RefCounted
class_name VoxelCollision

# отвечает за:
# Проверку пересечения капсулы с блоками.
# Определение опоры под ногами.
# Проверку возможности перемещения.
# Обработку столкновений со стенами и потолком.


const COLLISION_RADIUS: float = 0.35
const COLLISION_HEIGHT: float = 1.4
const MAX_MOVE_STEPS: int = 16

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
# Перемещает капсулу с обработкой столкновений и скольжения.
static func move_capsule(
    planet: Planet,
    world_position: Vector3,
    displacement: Vector3
) -> Vector3:

    if planet == null or displacement.length_squared() < 0.000001:
        return world_position

    var planet_center := planet.to_global(
        planet.get_planet_center()
    )

    var current_position := world_position

    # Если персонаж уже находится внутри блока,
    # сначала пытаемся устранить проникновение.
    var initial_up := (
        current_position - planet_center
    ).normalized()

    var initial_collision := get_capsule_collision(
        planet,
        current_position,
        initial_up,
        &"move_initial"
    )

    if initial_collision.collided:
        current_position = resolve_capsule_collision(
            planet,
            current_position,
            initial_up,
            initial_collision
        )

    # Ограничиваем размер шага и общее число шагов.
    # Это защищает от аномально большого перемещения за один вызов.
    var max_step := COLLISION_RADIUS * 0.5
    var max_distance := max_step * MAX_MOVE_STEPS
    var distance := displacement.length()

    if distance > max_distance:
        displacement = displacement * (max_distance / distance)
        distance = max_distance

    var steps := mini(
        MAX_MOVE_STEPS,
        maxi(1, ceili(distance / max_step))
    )

    var step_vector := displacement / float(steps)

    for i in range(steps):

        var remaining := step_vector

        # Несколько столкновений за один шаг:
        # например, при движении в угол.
        for j in range(3):

            if remaining.length_squared() < 0.000001:
                break

            var candidate := current_position + remaining

            var candidate_up := (
                candidate - planet_center
            ).normalized()

            var collision := get_capsule_collision(
                planet,
                candidate,
                candidate_up,
                &"move_candidate"
            )

            # Препятствий нет — принимаем перемещение.
            if not collision.collided:
                current_position = candidate
                break

            # Ищем последнюю позицию, в которой
            # капсула ещё не пересекается с блоками.
            var low := 0.0
            var high := 1.0

            for k in range(6):

                var middle := (low + high) * 0.5

                var test_position := (
                    current_position + remaining * middle
                )

                var test_up := (
                    test_position - planet_center
                ).normalized()

                var test_collision := get_capsule_collision(
                    planet,
                    test_position,
                    test_up,
                    &"move_binary"
                )

                if test_collision.collided:
                    high = middle
                else:
                    low = middle

            # Перемещаемся до найденной безопасной позиции.
            current_position += remaining * low

            # Оставшаяся часть движения.
            remaining *= 1.0 - low

            # Если нормаль некорректна, прекращаем этот шаг.
            if collision.normal.length_squared() < 0.0001:
                break

            # Убираем только движение внутрь препятствия.
            var into_surface := remaining.dot(collision.normal)

            if into_surface < 0.0:
                remaining -= collision.normal * into_surface
            else:
                break

    return current_position

# Проверяет расстояние между отрезком и AABB.
static func _segment_intersects_box(
    point_a: Vector3,
    point_b: Vector3,
    box_min: Vector3,
    box_max: Vector3,
    radius: float
) -> bool:

    var closest_point: Vector3 = _closest_segment_point_to_box(
        point_a,
        point_b,
        box_min,
        box_max
    )

    var distance_squared: float = _point_box_distance_squared(
        closest_point, box_min, box_max
    )

    return distance_squared <= radius * radius


# Находит точку отрезка с минимальным расстоянием до AABB.
# Квадрат расстояния кусочно-квадратичен: его формула меняется
# только там, где координата отрезка пересекает грань коробки.
# Поэтому минимум можно найти точно, без 24 итераций тернарного поиска.
static func _closest_segment_point_to_box(
    point_a: Vector3,
    point_b: Vector3,
    box_min: Vector3,
    box_max: Vector3
) -> Vector3:

    var direction: Vector3 = point_b - point_a
    var breakpoints: Array[float] = [0.0, 1.0]

    for axis in range(3):
        var start_value: float = point_a[axis]
        var axis_delta: float = direction[axis]

        if absf(axis_delta) < 0.0000001:
            continue

        var min_t: float = (box_min[axis] - start_value) / axis_delta
        var max_t: float = (box_max[axis] - start_value) / axis_delta

        if min_t > 0.0 and min_t < 1.0:
            breakpoints.append(min_t)
        if max_t > 0.0 and max_t < 1.0:
            breakpoints.append(max_t)

    breakpoints.sort()

    var best_t: float = 0.0
    var best_distance_squared: float = _point_box_distance_squared(
        point_a,
        box_min,
        box_max
    )

    for i in range(breakpoints.size() - 1):
        var interval_start: float = breakpoints[i]
        var interval_end: float = breakpoints[i + 1]
        var midpoint: float = (interval_start + interval_end) * 0.5
        var midpoint_point: Vector3 = point_a + direction * midpoint

        var quadratic_a: float = 0.0
        var quadratic_b: float = 0.0

        for axis in range(3):
            var boundary: float
            var outside: bool = false

            if midpoint_point[axis] < box_min[axis]:
                boundary = box_min[axis]
                outside = true
            elif midpoint_point[axis] > box_max[axis]:
                boundary = box_max[axis]
                outside = true

            if outside:
                var offset: float = point_a[axis] - boundary
                var slope: float = direction[axis]
                quadratic_a += slope * slope
                quadratic_b += offset * slope

        var candidate_t: float = interval_start
        if quadratic_a > 0.0000001:
            candidate_t = clampf(
                -quadratic_b / quadratic_a,
                interval_start,
                interval_end
            )

        var candidate_point: Vector3 = point_a + direction * candidate_t
        var candidate_distance_squared: float = _point_box_distance_squared(
            candidate_point,
            box_min,
            box_max
        )

        if candidate_distance_squared < best_distance_squared:
            best_distance_squared = candidate_distance_squared
            best_t = candidate_t

    return point_a + direction * best_t


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
    world_up: Vector3,
    diagnostic_phase: StringName = &"collision_other"
) -> CollisionResult:

    var started_usec: int = Time.get_ticks_usec()
    var tested_cells: int = 0
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
                tested_cells += 1

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

    planet.record_collision_diagnostic(
        diagnostic_phase,
        tested_cells,
        Time.get_ticks_usec() - started_usec
    )
    return result

# Проверяет опору независимо от того, какой контакт оказался самым глубоким.
# Учитываются все блоки в области капсулы; достаточно любого контакта,
# нормаль которого направлена преимущественно против силы тяжести.
static func has_capsule_support(
    planet: Planet,
    world_position: Vector3,
    world_up: Vector3,
    diagnostic_phase: StringName = &"support_other"
) -> bool:

    var started_usec: int = Time.get_ticks_usec()
    var tested_cells: int = 0

    if planet == null:
        return false

    var up: Vector3 = world_up.normalized()
    var local_position: Vector3 = planet.to_local(world_position)
    var local_up: Vector3 = (
        planet.global_transform.basis.inverse() * up
    ).normalized()

    # Для проверки опоры достаточно нижней части капсулы.
    # Полный отрезок проверяет также область туловища и головы,
    # хотя опорой может быть только контакт под ногами.
    var half_segment: float = COLLISION_HEIGHT * 0.5 - COLLISION_RADIUS
    var point_a: Vector3 = local_position - local_up * half_segment
    var point_b: Vector3 = point_a + local_up * COLLISION_RADIUS
    var margin: Vector3 = Vector3.ONE * COLLISION_RADIUS

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

    var min_cell: Vector3i = Vector3i(
        floori(bounds_min.x / planet.BLOCK_SIZE),
        floori(bounds_min.y / planet.BLOCK_SIZE),
        floori(bounds_min.z / planet.BLOCK_SIZE)
    )

    var max_cell: Vector3i = Vector3i(
        floori(bounds_max.x / planet.BLOCK_SIZE),
        floori(bounds_max.y / planet.BLOCK_SIZE),
        floori(bounds_max.z / planet.BLOCK_SIZE)
    )

    for x in range(min_cell.x, max_cell.x + 1):
        for y in range(min_cell.y, max_cell.y + 1):
            for z in range(min_cell.z, max_cell.z + 1):
                tested_cells += 1

                if not planet.is_solid(x, y, z):
                    continue

                var box_min: Vector3 = Vector3(x, y, z) * planet.BLOCK_SIZE
                var box_max: Vector3 = box_min + Vector3.ONE * planet.BLOCK_SIZE
                var contact: ContactResult = _get_segment_box_contact(
                    point_a,
                    point_b,
                    box_min,
                    box_max,
                    COLLISION_RADIUS
                )

                if contact.penetration <= 0.0:
                    continue

                var world_normal: Vector3 = (
                    planet.global_transform.basis * contact.normal
                ).normalized()

                if world_normal.dot(up) > 0.5:
                    planet.record_collision_diagnostic(
                        diagnostic_phase,
                        tested_cells,
                        Time.get_ticks_usec() - started_usec
                    )
                    return true

    planet.record_collision_diagnostic(
        diagnostic_phase,
        tested_cells,
        Time.get_ticks_usec() - started_usec
    )
    return false


static func _get_segment_box_contact(
    point_a: Vector3,
    point_b: Vector3,
    box_min: Vector3,
    box_max: Vector3,
    radius: float
) -> ContactResult:

    var result := ContactResult.new()

    var segment_point: Vector3 = _closest_segment_point_to_box(
        point_a,
        point_b,
        box_min,
        box_max
    )

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
    world_up: Vector3,
    initial_collision: CollisionResult = null
) -> Vector3:

    var position := world_position

    # Первый контакт уже был рассчитан вызывающей функцией.
    # Используем его, чтобы не сканировать ту же позицию повторно.
    var collision: CollisionResult = initial_collision

    # Несколько проходов нужны, чтобы обработать углы,
    # где капсула одновременно касается нескольких блоков.
    for i in range(4):

        if collision == null:
            collision = get_capsule_collision(
                planet,
                position,
                world_up,
                &"move_resolve"
            )

        if not collision.collided:
            break

        position += collision.normal * (
            collision.penetration + 0.001
        )
        collision = null

    return position


