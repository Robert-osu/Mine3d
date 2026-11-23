extends StaticBody3D
class_name Planet

@export_group("Planet")
@export_range(1, 1000) var planet_scale: int = 5

@export_group("Chunks")
@export_range(1, 4) var load_radius: int = 1
@export_range(1, 6) var unload_radius: int = 3
@export_range(96, 2048) var blocks_per_frame: int = 512

@export_group("Visual")
@export var terrain_color: Color = Color("#8b765e")

const CHUNK_SIZE: int = 32
const BLOCK_SIZE: float = 1.0

const DIRECTIONS: Array[Vector3i] = [
    Vector3i(1, 0, 0),
    Vector3i(-1, 0, 0),
    Vector3i(0, 1, 0),
    Vector3i(0, -1, 0),
    Vector3i(0, 0, 1),
    Vector3i(0, 0, -1)
]

const FACE_VERTICES: Array = [
    [Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)],
    [Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0), Vector3(0, 0, 0)],
    [Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0), Vector3(0, 1, 0)],
    [Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)],
    [Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1), Vector3(0, 0, 1)],
    [Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 0, 0)]
]

const FACE_NORMALS: Array[Vector3] = [
    Vector3.RIGHT,
    Vector3.LEFT,
    Vector3.UP,
    Vector3.DOWN,
    Vector3.BACK,
    Vector3.FORWARD
]

var SIZE: int = 0
var RADIUS: float = 0.0

# chunks[key] = { root, blocks, request_id, pending_cells, build_cursor }
# blocks[cell] = StaticBody3D for a currently visible block.
var chunks: Dictionary = {}
var destroyed_blocks: Dictionary = {}

var terrain_material: StandardMaterial3D
var shared_block_shape: BoxShape3D
var last_center_chunk := Vector3i(-999999, -999999, -999999)

var chunk_queue: Array[Vector3i] = []
var active_chunk_requests: Dictionary = {}
var completed_chunk_data: Dictionary = {}
var completed_mutex := Mutex.new()
var worker_task_ids: Dictionary = {}
var next_request_id: int = 0

const MAX_PARALLEL_CHUNKS: int = 2
const MAX_CHUNKS_PER_FRAME: int = 1


func _ready() -> void:
    SIZE = 32 * planet_scale
    RADIUS = 14.0 * planet_scale

    terrain_material = StandardMaterial3D.new()
    terrain_material.albedo_color = terrain_color
    terrain_material.roughness = 1.0
    terrain_material.cull_mode = BaseMaterial3D.CULL_DISABLED

    shared_block_shape = BoxShape3D.new()
    shared_block_shape.size = Vector3.ONE * BLOCK_SIZE

    print("Planet initialized. Size: ", SIZE, " Radius: ", RADIUS)


func _process(_delta: float) -> void:
    collect_finished_worker_tasks()
    start_chunk_jobs()
    apply_completed_chunk_data()
    process_pending_block_creation()


func _exit_tree() -> void:
    # Не позволяем фоновым задачам обращаться к объекту после его удаления.
    for task_id_variant in worker_task_ids.keys():
        var task_id: int = int(task_id_variant)
        WorkerThreadPool.wait_for_task_completion(task_id)
    worker_task_ids.clear()


func collect_finished_worker_tasks() -> void:
    var finished_ids: Array[int] = []

    for task_id_variant in worker_task_ids.keys():
        var task_id: int = int(task_id_variant)
        if WorkerThreadPool.is_task_completed(task_id):
            WorkerThreadPool.wait_for_task_completion(task_id)
            finished_ids.append(task_id)

    for task_id in finished_ids:
        worker_task_ids.erase(task_id)


# -----------------------------------------------------------------------------
# BACKGROUND CHUNK SCAN
# В фоне вычисляется только список видимых блоков. SceneTree и физика не трогаются.
# -----------------------------------------------------------------------------

func start_chunk_jobs() -> void:
    var started: int = 0

    while (
        started < MAX_CHUNKS_PER_FRAME
        and active_chunk_requests.size() < MAX_PARALLEL_CHUNKS
        and not chunk_queue.is_empty()
    ):
        # Сначала генерируем чанк, ближайший к игроку.
        var key: Vector3i = pop_nearest_queued_chunk()

        if not chunks.has(key):
            continue
        if active_chunk_requests.has(key):
            continue

        next_request_id += 1
        var request_id: int = next_request_id
        var chunk_data: Dictionary = chunks[key]
        chunk_data["request_id"] = request_id

        # Снимок нужен только для первоначального сканирования загружаемого чанка.
        var destroyed_snapshot: Dictionary = destroyed_blocks.duplicate()
        active_chunk_requests[key] = request_id

        var task_id: int = WorkerThreadPool.add_task(
            _build_visible_cells.bind(key, destroyed_snapshot, request_id),
            false,
            "Scan visible voxel blocks"
        )
        worker_task_ids[task_id] = true
        started += 1


func _build_visible_cells(
    key: Vector3i,
    destroyed_snapshot: Dictionary,
    request_id: int
) -> void:
    var visible_cells: Array[Vector3i] = []
    var center: Vector3 = Vector3(SIZE, SIZE, SIZE) * 0.5

    for z in range(CHUNK_SIZE):
        for y in range(CHUNK_SIZE):
            for x in range(CHUNK_SIZE):
                var cell := Vector3i(
                    key.x * CHUNK_SIZE + x,
                    key.y * CHUNK_SIZE + y,
                    key.z * CHUNK_SIZE + z
                )

                if not _is_solid_snapshot(cell, center, destroyed_snapshot):
                    continue

                var exposed: bool = false
                for direction: Vector3i in DIRECTIONS:
                    if not _is_solid_snapshot(cell + direction, center, destroyed_snapshot):
                        exposed = true
                        break

                if exposed:
                    visible_cells.append(cell)

    completed_mutex.lock()
    completed_chunk_data[request_id] = {
        "key": key,
        "request_id": request_id,
        "visible_cells": visible_cells
    }
    completed_mutex.unlock()


func _is_solid_snapshot(
    cell: Vector3i,
    center: Vector3,
    destroyed_snapshot: Dictionary
) -> bool:
    if cell.x < 0 or cell.x >= SIZE:
        return false
    if cell.y < 0 or cell.y >= SIZE:
        return false
    if cell.z < 0 or cell.z >= SIZE:
        return false
    if destroyed_snapshot.has(cell):
        return false

    var block_center: Vector3 = Vector3(cell) + Vector3.ONE * 0.5
    return block_center.distance_squared_to(center) <= RADIUS * RADIUS


func apply_completed_chunk_data() -> void:
    completed_mutex.lock()
    if completed_chunk_data.is_empty():
        completed_mutex.unlock()
        return

    var result_ids: Array = completed_chunk_data.keys()
    var result_id: int = int(result_ids[0])
    var result: Dictionary = completed_chunk_data[result_id]
    completed_chunk_data.erase(result_id)
    completed_mutex.unlock()

    var key: Vector3i = result["key"]
    var request_id: int = int(result["request_id"])

    if active_chunk_requests.get(key, -1) == request_id:
        active_chunk_requests.erase(key)

    if not chunks.has(key):
        return

    var chunk_data: Dictionary = chunks[key]
    if int(chunk_data["request_id"]) != request_id:
        return

    chunk_data["pending_cells"] = result["visible_cells"]
    chunk_data["build_cursor"] = 0


# Создание узлов и коллизий выполняется постепенно в главном потоке.
func process_pending_block_creation() -> void:
    var budget: int = blocks_per_frame
    var chunk_keys: Array = chunks.keys()
    chunk_keys.sort_custom(_sort_chunk_keys_near_player)

    for key_variant in chunk_keys:
        if budget <= 0:
            break

        var key: Vector3i = key_variant
        if not chunks.has(key):
            continue

        var chunk_data: Dictionary = chunks[key]
        if not chunk_data.has("pending_cells"):
            continue

        var pending_cells: Array = chunk_data["pending_cells"]
        var cursor: int = int(chunk_data["build_cursor"])

        while cursor < pending_cells.size() and budget > 0:
            var cell: Vector3i = pending_cells[cursor]
            cursor += 1
            budget -= 1

            # Состояние могло измениться после фонового сканирования.
            create_block_visual(cell)

        chunk_data["build_cursor"] = cursor
        if cursor >= pending_cells.size():
            chunk_data.erase("pending_cells")
            chunk_data.erase("build_cursor")
            chunk_data["generated"] = true


# -----------------------------------------------------------------------------
# BLOCK VISUALS AND COLLISION
# -----------------------------------------------------------------------------

func is_block_visible(cell: Vector3i) -> bool:
    if not is_solid(cell.x, cell.y, cell.z):
        return false

    for direction: Vector3i in DIRECTIONS:
        if not is_solid(
            cell.x + direction.x,
            cell.y + direction.y,
            cell.z + direction.z
        ):
            return true

    return false


func create_block_visual(cell: Vector3i) -> void:
    if not is_block_visible(cell):
        return

    var chunk_key: Vector3i = index_to_chunk(cell)
    if not chunks.has(chunk_key):
        return

    var chunk_data: Dictionary = chunks[chunk_key]
    var block_map: Dictionary = chunk_data["blocks"]
    if block_map.has(cell):
        return

    var block_mesh: ArrayMesh = build_block_mesh(cell)
    if block_mesh.get_surface_count() == 0:
        return

    var body := StaticBody3D.new()
    body.name = "Block_%d_%d_%d" % [cell.x, cell.y, cell.z]

    body.collision_layer = 1
    body.collision_mask = 1

    var chunk_origin := Vector3(
        chunk_key.x * CHUNK_SIZE,
        chunk_key.y * CHUNK_SIZE,
        chunk_key.z * CHUNK_SIZE
    )
    body.position = Vector3(cell) - chunk_origin + Vector3.ONE * 0.5

    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "MeshInstance3D"
    mesh_instance.mesh = block_mesh
    body.add_child(mesh_instance)

    var collision := CollisionShape3D.new()
    collision.name = "CollisionShape3D"
    collision.shape = shared_block_shape
    collision.disabled = false

    body.add_child(collision)

    chunk_data["root"].add_child(body)
    block_map[cell] = body


func build_block_mesh(cell: Vector3i) -> ArrayMesh:
    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()
    var half: Vector3 = Vector3.ONE * 0.5

    for face_index in range(6):
        var direction: Vector3i = DIRECTIONS[face_index]
        var neighbor: Vector3i = cell + direction

        # Грань создаётся только тогда, когда снаружи нет твёрдого блока.
        if is_solid(neighbor.x, neighbor.y, neighbor.z):
            continue

        var face: Array = FACE_VERTICES[face_index]
        var a: Vector3 = face[0] - half
        var b: Vector3 = face[1] - half
        var c: Vector3 = face[2] - half
        var d: Vector3 = face[3] - half

        vertices.append_array([a, c, b, a, d, c])
        for _i in range(6):
            normals.append(FACE_NORMALS[face_index])

    var mesh := ArrayMesh.new()
    if vertices.is_empty():
        return mesh

    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)
    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals
    mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
    mesh.surface_set_material(0, terrain_material)
    return mesh


func remove_block_visual(cell: Vector3i) -> void:
    var chunk_key: Vector3i = index_to_chunk(cell)
    if not chunks.has(chunk_key):
        return

    var chunk_data: Dictionary = chunks[chunk_key]
    var block_map: Dictionary = chunk_data["blocks"]
    if not block_map.has(cell):
        return

    var body: StaticBody3D = block_map[cell]
    body.collision_layer = 0
    body.collision_mask = 0
    body.visible = false
    body.queue_free()
    block_map.erase(cell)


func refresh_block_visual(cell: Vector3i) -> void:
    var chunk_key: Vector3i = index_to_chunk(cell)
    if not chunks.has(chunk_key):
        return

    if not is_block_visible(cell):
        remove_block_visual(cell)
        return

    var chunk_data: Dictionary = chunks[chunk_key]
    var block_map: Dictionary = chunk_data["blocks"]

    if not block_map.has(cell):
        create_block_visual(cell)
        return

    var body: StaticBody3D = block_map[cell]
    var mesh_instance: MeshInstance3D = body.get_node("MeshInstance3D")
    mesh_instance.mesh = build_block_mesh(cell)


# -----------------------------------------------------------------------------
# BLOCK STORAGE AND MINING
# -----------------------------------------------------------------------------

func get_planet_center() -> Vector3:
    return Vector3(SIZE, SIZE, SIZE) * 0.5


func is_solid(x: int, y: int, z: int) -> bool:
    if x < 0 or x >= SIZE:
        return false
    if y < 0 or y >= SIZE:
        return false
    if z < 0 or z >= SIZE:
        return false

    var cell := Vector3i(x, y, z)
    if destroyed_blocks.has(cell):
        return false

    var block_center: Vector3 = Vector3(x, y, z) + Vector3.ONE * 0.5
    return block_center.distance_squared_to(get_planet_center()) <= RADIUS * RADIUS


func destroy_block(cell: Vector3i) -> bool:
    if not is_solid(cell.x, cell.y, cell.z):
        return false

    # Сначала мгновенно меняем логическое состояние блока.
    destroyed_blocks[cell] = true
    remove_block_visual(cell)

    # Только шесть соседей могут стать видимыми из-за этого разрушения.
    for direction: Vector3i in DIRECTIONS:
        refresh_block_visual(cell + direction)

    return true


func index_to_chunk(cell: Vector3i) -> Vector3i:
    return Vector3i(
        floori(float(cell.x) / CHUNK_SIZE),
        floori(float(cell.y) / CHUNK_SIZE),
        floori(float(cell.z) / CHUNK_SIZE)
    )


func get_cell(world_position: Vector3) -> Vector3i:
    var local_position: Vector3 = to_local(world_position)
    return Vector3i(
        floori(local_position.x / BLOCK_SIZE),
        floori(local_position.y / BLOCK_SIZE),
        floori(local_position.z / BLOCK_SIZE)
    )


func mine(
    ray_origin: Vector3,
    ray_direction: Vector3,
    max_distance: float = 100.0
) -> bool:
    var origin: Vector3 = to_local(ray_origin)
    var direction: Vector3 = (
        to_local(ray_origin + ray_direction.normalized()) - origin
    ).normalized()

    var cell := Vector3i(
        floori(origin.x),
        floori(origin.y),
        floori(origin.z)
    )

    var step := Vector3i(
        1 if direction.x > 0.0 else (-1 if direction.x < 0.0 else 0),
        1 if direction.y > 0.0 else (-1 if direction.y < 0.0 else 0),
        1 if direction.z > 0.0 else (-1 if direction.z < 0.0 else 0)
    )

    var t_delta := Vector3(
        INF if direction.x == 0.0 else abs(1.0 / direction.x),
        INF if direction.y == 0.0 else abs(1.0 / direction.y),
        INF if direction.z == 0.0 else abs(1.0 / direction.z)
    )

    var t_max := Vector3(
        INF if direction.x == 0.0 else (cell.x + (1 if step.x > 0 else 0) - origin.x) / direction.x,
        INF if direction.y == 0.0 else (cell.y + (1 if step.y > 0 else 0) - origin.y) / direction.y,
        INF if direction.z == 0.0 else (cell.z + (1 if step.z > 0 else 0) - origin.z) / direction.z
    )

    var distance: float = 0.0
    while distance <= max_distance:
        if is_solid(cell.x, cell.y, cell.z):
            return destroy_block(cell)

        if t_max.x < t_max.y and t_max.x < t_max.z:
            distance = t_max.x
            t_max.x += t_delta.x
            cell.x += step.x
        elif t_max.y < t_max.z:
            distance = t_max.y
            t_max.y += t_delta.y
            cell.y += step.y
        else:
            distance = t_max.z
            t_max.z += t_delta.z
            cell.z += step.z

    return false


func has_collision_at(world_position: Vector3) -> bool:
    var cell: Vector3i = get_cell(world_position)
    var chunk_key: Vector3i = index_to_chunk(cell)
    if not chunks.has(chunk_key):
        return false

    var chunk_data: Dictionary = chunks[chunk_key]
    var block_map: Dictionary = chunk_data["blocks"]
    return block_map.has(cell)


# -----------------------------------------------------------------------------
# CHUNK STREAMING
# -----------------------------------------------------------------------------

func update_streaming(world_position: Vector3) -> void:
    var local_position: Vector3 = to_local(world_position)

    var center_chunk := Vector3i(
        floori(local_position.x / CHUNK_SIZE),
        floori(local_position.y / CHUNK_SIZE),
        floori(local_position.z / CHUNK_SIZE)
    )

    if center_chunk == last_center_chunk:
        return

    last_center_chunk = center_chunk

    var retained_chunks: Dictionary = {}

    # Загружаем новые чанки в основном радиусе.
    for z in range(-load_radius, load_radius + 1):
        for y in range(-load_radius, load_radius + 1):
            for x in range(-load_radius, load_radius + 1):
                var key := center_chunk + Vector3i(x, y, z)

                if not is_valid_chunk(key):
                    continue

                if not chunk_intersects_planet(key):
                    continue

                retained_chunks[key] = true

                if not chunks.has(key):
                    create_chunk(key)

    # Сохраняем старые чанки в дополнительном радиусе.
    for z in range(-unload_radius, unload_radius + 1):
        for y in range(-unload_radius, unload_radius + 1):
            for x in range(-unload_radius, unload_radius + 1):
                var key := center_chunk + Vector3i(x, y, z)

                if chunks.has(key):
                    retained_chunks[key] = true

    # Выгружаем только чанки за пределами дополнительного радиуса.
    var loaded_keys: Array = chunks.keys()

    for key_variant in loaded_keys:
        var key: Vector3i = key_variant

        if not retained_chunks.has(key):
            unload_chunk(key)

func is_valid_chunk(key: Vector3i) -> bool:
    var max_chunks: int = ceili(float(SIZE) / CHUNK_SIZE)
    return (
        key.x >= 0 and key.x < max_chunks
        and key.y >= 0 and key.y < max_chunks
        and key.z >= 0 and key.z < max_chunks
    )


func chunk_intersects_planet(key: Vector3i) -> bool:
    var chunk_min := Vector3(
        key.x * CHUNK_SIZE,
        key.y * CHUNK_SIZE,
        key.z * CHUNK_SIZE
    )
    var chunk_max: Vector3 = chunk_min + Vector3.ONE * CHUNK_SIZE
    var center: Vector3 = get_planet_center()
    var closest: Vector3 = center.clamp(chunk_min, chunk_max)
    return closest.distance_to(center) <= RADIUS + 1.0


func create_chunk(key: Vector3i) -> void:
    var root := Node3D.new()
    root.name = "Chunk_%d_%d_%d" % [key.x, key.y, key.z]
    root.position = Vector3(
        key.x * CHUNK_SIZE,
        key.y * CHUNK_SIZE,
        key.z * CHUNK_SIZE
    )
    add_child(root)

    chunks[key] = {
        "root": root,
        "blocks": {},
        "request_id": -1,
        "generated": false
    }
    enqueue_chunk(key, false)


func unload_chunk(key: Vector3i) -> void:
    if not chunks.has(key):
        return

    var chunk_data: Dictionary = chunks[key]
    var root: Node3D = chunk_data["root"]
    root.queue_free()
    chunks.erase(key)
    chunk_queue.erase(key)
    active_chunk_requests.erase(key)



func chunk_priority_distance(key: Vector3i) -> int:
    var dx: int = key.x - last_center_chunk.x
    var dy: int = key.y - last_center_chunk.y
    var dz: int = key.z - last_center_chunk.z
    return dx * dx + dy * dy + dz * dz


func _sort_chunk_keys_near_player(a: Vector3i, b: Vector3i) -> bool:
    return chunk_priority_distance(a) < chunk_priority_distance(b)


func pop_nearest_queued_chunk() -> Vector3i:
    if chunk_queue.is_empty():
        return Vector3i(-1, -1, -1)

    var best_index: int = 0
    var best_distance: int = chunk_priority_distance(chunk_queue[0])

    for i in range(1, chunk_queue.size()):
        var candidate_distance: int = chunk_priority_distance(chunk_queue[i])
        if candidate_distance < best_distance:
            best_distance = candidate_distance
            best_index = i

    return chunk_queue.pop_at(best_index)


func enqueue_chunk(key: Vector3i, high_priority: bool = false) -> void:
    if not chunks.has(key):
        return
    chunk_queue.erase(key)
    if high_priority:
        chunk_queue.push_front(key)
    else:
        chunk_queue.append(key)

func is_chunk_ready_at(world_position: Vector3) -> bool:
    var local_position := to_local(world_position)

    var cell := Vector3i(
        floori(local_position.x / BLOCK_SIZE),
        floori(local_position.y / BLOCK_SIZE),
        floori(local_position.z / BLOCK_SIZE)
    )

    var key := index_to_chunk(cell)

    if not chunks.has(key):
        return false

    var chunk_data: Dictionary = chunks[key]

    return bool(chunk_data.get("generated", false))

func debug_chunk_at(world_position: Vector3) -> void:
    var cell := get_cell(world_position)
    var key := index_to_chunk(cell)

    print("\n--- PHYSICS DEBUG ---")
    print("Cell: ", cell)

    if not chunks.has(key):
        print("CHUNK DOES NOT EXIST")
        return

    var data: Dictionary = chunks[key]
    var blocks: Dictionary = data["blocks"]

    print("Generated: ", data.get("generated", false))
    print("Block exists: ", blocks.has(cell))

    if not blocks.has(cell):
        print("NO BLOCK NODE")
        return

    var body: StaticBody3D = blocks[cell]
    var shape := body.get_node_or_null("CollisionShape3D") as CollisionShape3D

    print("Body RID: ", body.get_rid())
    print("Body space: ", PhysicsServer3D.body_get_space(body.get_rid()))
    print("World space: ", get_world_3d().space)
    print("Shape size: ", (shape.shape as BoxShape3D).size)
    print("Shape owner: ", shape.get_parent())
    print("Body transform: ", body.global_transform)

    # Обновляем трансформ и ждём физический кадр.
    body.force_update_transform()
    await get_tree().physics_frame

    var start := body.global_position + Vector3.UP * 2.0
    var finish := body.global_position - Vector3.UP * 2.0

    var query := PhysicsRayQueryParameters3D.create(start, finish)
    query.collision_mask = 1

    var hit := get_world_3d().direct_space_state.intersect_ray(query)

    if hit.is_empty():
        print("DIRECT RAY AFTER PHYSICS FRAME: NOTHING")
    else:
        print("DIRECT RAY AFTER PHYSICS FRAME: ", hit["collider"].name)



