extends StaticBody3D
class_name Planet

# Лёгкие счётчики для диагностики добычи и воксельных столкновений.
var diag_collision_calls: int = 0
var diag_collision_cells: int = 0
var diag_collision_max_usec: int = 0
var diag_collision_phases: Dictionary = {}
var diag_ray_calls: int = 0
var diag_ray_steps: int = 0
var diag_ray_max_steps: int = 0
var diag_destroy_calls: int = 0
var diag_destroy_max_usec: int = 0
var diag_section_queue_max: int = 0


func record_collision_diagnostic(
    phase: StringName,
    cells_checked: int,
    elapsed_usec: int
) -> void:
    diag_collision_calls += 1
    diag_collision_cells += cells_checked
    diag_collision_max_usec = maxi(diag_collision_max_usec, elapsed_usec)

    var phase_stats: Array = diag_collision_phases.get(
        phase,
        [0, 0, 0]
    )
    phase_stats[0] += 1
    phase_stats[1] += cells_checked
    phase_stats[2] = maxi(int(phase_stats[2]), elapsed_usec)
    diag_collision_phases[phase] = phase_stats


func _record_mining_ray_diagnostic(steps: int) -> void:
    diag_ray_calls += 1
    diag_ray_steps += steps
    diag_ray_max_steps = maxi(diag_ray_max_steps, steps)


func _record_destroy_diagnostic(elapsed_usec: int) -> void:
    diag_destroy_calls += 1
    diag_destroy_max_usec = maxi(diag_destroy_max_usec, elapsed_usec)


func consume_mining_debug_stats() -> Dictionary:
    var result := {
        "collision_calls": diag_collision_calls,
        "collision_cells": diag_collision_cells,
        "collision_max_usec": diag_collision_max_usec,
        "collision_phases": diag_collision_phases.duplicate(true),
        "ray_calls": diag_ray_calls,
        "ray_steps": diag_ray_steps,
        "ray_max_steps": diag_ray_max_steps,
        "destroy_calls": diag_destroy_calls,
        "destroy_max_usec": diag_destroy_max_usec,
        "section_queue_max": diag_section_queue_max
    }

    diag_collision_calls = 0
    diag_collision_cells = 0
    diag_collision_max_usec = 0
    diag_collision_phases.clear()
    diag_ray_calls = 0
    diag_ray_steps = 0
    diag_ray_max_steps = 0
    diag_destroy_calls = 0
    diag_destroy_max_usec = 0
    diag_section_queue_max = section_queue.size()
    return result



var settings:
    get:
        return GameConfig.SETTINGS

# Масштаб и цвет конкретного экземпляра мира.
# -1 означает, что используются локальные настройки по умолчанию.
var world_scale: int = -1
var world_terrain_color: Color

var SIZE: int:
    get:
        return CHUNK_SIZE * (
            world_scale if world_scale > 0 else settings.planet_scale
        )

var RADIUS: float:
    get:
        return 14.0 * (
            world_scale if world_scale > 0 else settings.planet_scale
        )

const CHUNK_SIZE: int = 32
const BLOCK_SIZE: float = 1.0

const SECTION_SIZE: int = 8
const SECTIONS_PER_CHUNK: int = CHUNK_SIZE / SECTION_SIZE

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

# chunks[key] = { root, blocks, request_id, pending_cells, build_cursor }
# blocks[cell] = StaticBody3D for a currently visible block.
var chunks: Dictionary = {}

# Глобальное хранилище изменений.
# Ключ — глобальная координата секции.
# Значение — PackedByteArray из 512 элементов.
var section_deltas: Dictionary = {}

var terrain_material: StandardMaterial3D
var last_center_chunk := Vector3i(-999999, -999999, -999999)

var chunk_queue: Array[Vector3i] = []
var active_chunk_requests: Dictionary = {}
var completed_chunk_data: Dictionary = {}
var completed_mutex := Mutex.new()
var worker_task_ids: Dictionary = {}
var next_request_id: int = 0


# -----------------------------------------------------------------------------
# ASYNC SECTION BUILDER
# -----------------------------------------------------------------------------

const SECTION_SNAPSHOT_SIZE: int = SECTION_SIZE + 2

var section_queue: Array[Vector3i] = []
var queued_sections: Dictionary = {}

# section_id -> request_id
var active_section_requests: Dictionary = {}

# section_id -> version
var section_versions: Dictionary = {}

# task_id -> request_id
var section_worker_task_ids: Dictionary = {}

# request_id -> result
var completed_section_data: Dictionary = {}

var section_mutex := Mutex.new()
var next_section_request_id: int = 0

# Временные грани, появившиеся после разрушения блоков.
# chunk_key -> section_key -> данные временной геометрии.


func _add_temporary_face(
    chunk_key: Vector3i,
    section_key: Vector3i,
    cell: Vector3i,
    face_index: int
) -> void:

    if not chunks.has(chunk_key):
        return

    var chunk_data: Dictionary = chunks[chunk_key]
    var chunk_root: Node3D = chunk_data["root"]

    var temporary_faces: Dictionary = chunk_data.get(
        "temporary_faces",
        {}
    )

    var face_data: Dictionary = temporary_faces.get(
        section_key,
        {}
    )

    # Создаём временный узел секции, если его ещё нет.
    if face_data.is_empty():
        var section_root := Node3D.new()
        section_root.name = "TemporaryFaces"

        section_root.position = Vector3(
            section_key * SECTION_SIZE
        )

        chunk_root.add_child(section_root)

        var mesh_instance := MeshInstance3D.new()
        section_root.add_child(mesh_instance)

        face_data = {
            "root": section_root,
            "mesh_instance": mesh_instance,
            "vertices": PackedVector3Array(),
            "normals": PackedVector3Array()
        }

    var vertices: PackedVector3Array = face_data["vertices"]
    var normals: PackedVector3Array = face_data["normals"]

    # Координаты блока относительно секции.
    var block_origin := Vector3(cell - get_section_origin(
        chunk_key,
        section_key
    ))

    var face: Array = FACE_VERTICES[face_index]

    var a: Vector3 = block_origin + face[0]
    var b: Vector3 = block_origin + face[1]
    var c: Vector3 = block_origin + face[2]
    var d: Vector3 = block_origin + face[3]

    vertices.append_array([
        a, c, b,
        a, d, c
    ])

    for i in range(6):
        normals.append(FACE_NORMALS[face_index])

    face_data["vertices"] = vertices
    face_data["normals"] = normals

    # Обновляем только маленький временный меш.
    var mesh := ArrayMesh.new()

    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)

    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals

    mesh.add_surface_from_arrays(
        Mesh.PRIMITIVE_TRIANGLES,
        arrays
    )

    mesh.surface_set_material(0, terrain_material)

    var mesh_instance: MeshInstance3D = face_data["mesh_instance"]
    mesh_instance.mesh = mesh

    temporary_faces[section_key] = face_data
    chunk_data["temporary_faces"] = temporary_faces


func _clear_temporary_section_faces(
    chunk_key: Vector3i,
    section_key: Vector3i
) -> void:

    if not chunks.has(chunk_key):
        return

    var chunk_data: Dictionary = chunks[chunk_key]

    var temporary_faces: Dictionary = chunk_data.get(
        "temporary_faces",
        {}
    )

    if not temporary_faces.has(section_key):
        return

    var face_data: Dictionary = temporary_faces[section_key]
    var root: Node3D = face_data["root"]

    if is_instance_valid(root):
        root.queue_free()

    temporary_faces.erase(section_key)
    chunk_data["temporary_faces"] = temporary_faces



func _ready() -> void:
    add_to_group("planet")

    world_terrain_color = settings.terrain_color

    terrain_material = StandardMaterial3D.new()
    terrain_material.albedo_color = world_terrain_color
    terrain_material.roughness = 1.0
    terrain_material.cull_mode = BaseMaterial3D.CULL_DISABLED

    print("PLANET READY | SIZE: ", SIZE, " | RADIUS: ", RADIUS)


func _process(_delta: float) -> void:
    collect_finished_worker_tasks()
    collect_finished_section_tasks()

    start_chunk_jobs()
    start_section_jobs()

    apply_completed_chunk_data()
    apply_completed_section_data()

    process_pending_block_creation()


func _build_section_mesh_job(
    section_id: Vector3i,
    chunk_key: Vector3i,
    section_key: Vector3i,
    request_id: int,
    version: int,
    snapshot: PackedByteArray
) -> void:

    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()

    var size: int = SECTION_SNAPSHOT_SIZE

    # Индекс блока внутри снимка.
    # Координаты секции начинаются с 1,
    # поскольку нулевой слой — внешняя граница.
    for z in range(SECTION_SIZE):
        for y in range(SECTION_SIZE):
            for x in range(SECTION_SIZE):

                var sx: int = x + 1
                var sy: int = y + 1
                var sz: int = z + 1

                var index: int = (
                    sz * size * size
                    + sy * size
                    + sx
                )

                if snapshot[index] == 0:
                    continue

                var block_origin := Vector3(x, y, z)

                for face_index in range(6):
                    var direction: Vector3i = DIRECTIONS[face_index]

                    var nx: int = sx + direction.x
                    var ny: int = sy + direction.y
                    var nz: int = sz + direction.z

                    var neighbor_index: int = (
                        nz * size * size
                        + ny * size
                        + nx
                    )

                    # Сосед существует — грань не нужна.
                    if snapshot[neighbor_index] == 1:
                        continue

                    var face: Array = FACE_VERTICES[face_index]

                    var a: Vector3 = block_origin + face[0]
                    var b: Vector3 = block_origin + face[1]
                    var c: Vector3 = block_origin + face[2]
                    var d: Vector3 = block_origin + face[3]

                    vertices.append_array([
                        a, c, b,
                        a, d, c
                    ])

                    for i in range(6):
                        normals.append(FACE_NORMALS[face_index])

    # Передаём результат главному потоку.
    section_mutex.lock()

    completed_section_data[request_id] = {
        "section_id": section_id,
        "chunk_key": chunk_key,
        "section_key": section_key,
        "request_id": request_id,
        "version": version,
        "vertices": vertices,
        "normals": normals
    }

    section_mutex.unlock()

func make_section_id(
    chunk_key: Vector3i,
    section_key: Vector3i
) -> Vector3i:
    return chunk_key * SECTIONS_PER_CHUNK + section_key

func queue_section_rebuild(
    chunk_key: Vector3i,
    section_key: Vector3i
) -> void:

    if not chunks.has(chunk_key):
        return

    var chunk_data: Dictionary = chunks[chunk_key]

    var section_id := make_section_id(
        chunk_key,
        section_key
    )

    # Каждое изменение увеличивает версию.
    var version: int = int(
        section_versions.get(section_id, 0)
    ) + 1

    section_versions[section_id] = version

    # Если секция уже стоит в очереди, не добавляем повторно.
    if queued_sections.has(section_id):
        diag_section_queue_max = maxi(diag_section_queue_max, section_queue.size())
        return

    queued_sections[section_id] = true
    section_queue.append(section_id)
    diag_section_queue_max = maxi(diag_section_queue_max, section_queue.size())


func start_section_jobs() -> void:
    var started: int = 0
    
    # Проверяем не больше тех секций, которые были в очереди
    # в начале вызова. Это защищает от бесконечного перебора.
    var sections_to_check: int = section_queue.size()

    while (
        started < settings.max_section_jobs_per_frame
        and active_section_requests.size() < settings.max_parallel_section_jobs
        and not section_queue.is_empty()
        and sections_to_check > 0
    ):
        sections_to_check -= 1

        var section_id: Vector3i = section_queue.pop_front()
        queued_sections.erase(section_id)

        var chunk_key := Vector3i(
            floori(float(section_id.x) / SECTIONS_PER_CHUNK),
            floori(float(section_id.y) / SECTIONS_PER_CHUNK),
            floori(float(section_id.z) / SECTIONS_PER_CHUNK)
        )

        var section_key := Vector3i(
            posmod(section_id.x, SECTIONS_PER_CHUNK),
            posmod(section_id.y, SECTIONS_PER_CHUNK),
            posmod(section_id.z, SECTIONS_PER_CHUNK)
        )

        if not chunks.has(chunk_key):
            continue

        # Если секция уже перестраивается, оставляем её в очереди,
        # но проверяем следующие секции.
        if active_section_requests.has(section_id):
            if not queued_sections.has(section_id):
                queued_sections[section_id] = true
                section_queue.append(section_id)
            continue

        var chunk_data: Dictionary = chunks[chunk_key]

        # Неготовую секцию откладываем в конец очереди.
        if not bool(chunk_data.get("generated", false)):
            queued_sections[section_id] = true
            section_queue.append(section_id)
            continue

        var version: int = int(
            section_versions.get(section_id, 0)
        )

        var snapshot := create_section_snapshot(
            chunk_key,
            section_key
        )

        next_section_request_id += 1
        var request_id: int = next_section_request_id

        active_section_requests[section_id] = request_id

        var task_id: int = WorkerThreadPool.add_task(
            _build_section_mesh_job.bind(
                section_id,
                chunk_key,
                section_key,
                request_id,
                version,
                snapshot
            ),
            false,
            "Build voxel section"
        )

        section_worker_task_ids[task_id] = request_id

        started += 1


func collect_finished_section_tasks() -> void:
    var finished_ids: Array[int] = []

    for task_id_variant in section_worker_task_ids.keys():
        var task_id: int = int(task_id_variant)

        if WorkerThreadPool.is_task_completed(task_id):
            WorkerThreadPool.wait_for_task_completion(task_id)
            finished_ids.append(task_id)

    for task_id in finished_ids:
        section_worker_task_ids.erase(task_id)

func apply_completed_section_data() -> void:
    section_mutex.lock()

    if completed_section_data.is_empty():
        section_mutex.unlock()
        return

    var results: Array = completed_section_data.values()
    completed_section_data.clear()

    section_mutex.unlock()

    for result: Dictionary in results:

        var section_id: Vector3i = result["section_id"]
        var request_id: int = int(result["request_id"])

        # Проверяем, что это всё ещё актуальный запрос.
        if active_section_requests.get(section_id, -1) != request_id:
            continue

        active_section_requests.erase(section_id)

        var current_version: int = int(
            section_versions.get(section_id, -1)
        )

        # Пока поток работал, блоки могли измениться.
        if int(result["version"]) != current_version:
            continue

        var chunk_key: Vector3i = result["chunk_key"]
        var section_key: Vector3i = result["section_key"]

        if not chunks.has(chunk_key):
            continue

        var chunk_data: Dictionary = chunks[chunk_key]

        if not bool(chunk_data.get("generated", false)):
            continue

        _clear_temporary_section_faces(
            chunk_key,
            section_key
        )

        _finish_section_geometry(
            chunk_key,
            section_key,
            result["vertices"],
            result["normals"]
        )

func create_section_snapshot(
    chunk_key: Vector3i,
    section_key: Vector3i
) -> PackedByteArray:

    var snapshot := PackedByteArray()
    snapshot.resize(
        SECTION_SNAPSHOT_SIZE
        * SECTION_SNAPSHOT_SIZE
        * SECTION_SNAPSHOT_SIZE
    )

    var origin := get_section_origin(chunk_key, section_key)

    for z in range(-1, SECTION_SIZE + 1):
        for y in range(-1, SECTION_SIZE + 1):
            for x in range(-1, SECTION_SIZE + 1):

                var cell := origin + Vector3i(x, y, z)

                var index := (
                    (z + 1) * SECTION_SNAPSHOT_SIZE * SECTION_SNAPSHOT_SIZE
                    + (y + 1) * SECTION_SNAPSHOT_SIZE
                    + (x + 1)
                )

                snapshot[index] = 1 if is_solid(
                    cell.x,
                    cell.y,
                    cell.z
                ) else 0

    return snapshot

func _exit_tree() -> void:
    # Не позволяем фоновым задачам обращаться к объекту после его удаления.
    for task_id_variant in worker_task_ids.keys():
        var task_id: int = int(task_id_variant)
        WorkerThreadPool.wait_for_task_completion(task_id)
    worker_task_ids.clear()

    for task_id_variant in section_worker_task_ids.keys():
        var task_id: int = int(task_id_variant)
        WorkerThreadPool.wait_for_task_completion(task_id)

    section_worker_task_ids.clear()


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
        started < settings.max_chunks_per_frame
        and active_chunk_requests.size() < settings.max_parallel_chunks
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
        var delta_snapshot := create_chunk_delta_snapshot(key)

        active_chunk_requests[key] = request_id

        var task_id: int = WorkerThreadPool.add_task(
            _build_visible_cells.bind(key, delta_snapshot, request_id),
            false,
            "Scan visible voxel blocks"
        )
        worker_task_ids[task_id] = true
        started += 1


func _build_visible_cells(
    key: Vector3i,
    delta_snapshot: Dictionary,
    request_id: int
) -> void:

    const SNAP_SIZE := CHUNK_SIZE + 2
    const SNAP_AREA := SNAP_SIZE * SNAP_SIZE
    const SNAP_VOLUME := SNAP_AREA * SNAP_SIZE

    # 1. Создаём компактную карту заполненности чанка.
    # Внешний слой нужен для проверки соседей на границах.
    var occupancy := PackedByteArray()
    occupancy.resize(SNAP_VOLUME)

    var has_deltas := not delta_snapshot.is_empty()

    var half_size := float(SIZE) * 0.5
    var radius_squared := RADIUS * RADIUS

    var chunk_origin := key * CHUNK_SIZE

    # Заполняем карту один раз.
    for z in range(-1, CHUNK_SIZE + 1):
        var gz := chunk_origin.z + z
        var dz := float(gz) + 0.5 - half_size
        var dz_squared := dz * dz

        for y in range(-1, CHUNK_SIZE + 1):
            var gy := chunk_origin.y + y
            var dy := float(gy) + 0.5 - half_size
            var dyz_squared := dy * dy + dz_squared

            for x in range(-1, CHUNK_SIZE + 1):
                var gx := chunk_origin.x + x

                if (
                    gx < 0 or gx >= SIZE
                    or gy < 0 or gy >= SIZE
                    or gz < 0 or gz >= SIZE
                ):
                    continue

                var dx := float(gx) + 0.5 - half_size

                if dx * dx + dyz_squared > radius_squared:
                    continue

                # Проверяем разрушение блока.
                if has_deltas:
                    var section_id := Vector3i(
                        floori(float(gx) / SECTION_SIZE),
                        floori(float(gy) / SECTION_SIZE),
                        floori(float(gz) / SECTION_SIZE)
                    )

                    if delta_snapshot.has(section_id):
                        var delta: PackedByteArray = delta_snapshot[section_id]

                        var local_index := (
                            posmod(gz, SECTION_SIZE) * SECTION_SIZE * SECTION_SIZE
                            + posmod(gy, SECTION_SIZE) * SECTION_SIZE
                            + posmod(gx, SECTION_SIZE)
                        )

                        if delta[local_index] != 0:
                            continue

                var index := (
                    (z + 1) * SNAP_AREA
                    + (y + 1) * SNAP_SIZE
                    + (x + 1)
                )

                occupancy[index] = 1

    # 2. Строим геометрию, используя только готовую карту.
    var section_build_data: Dictionary = {}

    # Смещения соседей в линейном массиве.
    var neighbor_offsets: Array[int] = [
        1,
        -1,
        SNAP_SIZE,
        -SNAP_SIZE,
        SNAP_AREA,
        -SNAP_AREA
    ]

    for z in range(CHUNK_SIZE):
        for y in range(CHUNK_SIZE):
            for x in range(CHUNK_SIZE):

                var center_index := (
                    (z + 1) * SNAP_AREA
                    + (y + 1) * SNAP_SIZE
                    + (x + 1)
                )

                if occupancy[center_index] == 0:
                    continue

                # Секция внутри чанка.
                var section_key := Vector3i(
                    x / SECTION_SIZE,
                    y / SECTION_SIZE,
                    z / SECTION_SIZE
                )

                var section_data: Dictionary = section_build_data.get(
                    section_key,
                    {
                        "vertices": PackedVector3Array(),
                        "normals": PackedVector3Array()
                    }
                )

                var vertices: PackedVector3Array = section_data["vertices"]
                var normals: PackedVector3Array = section_data["normals"]

                var block_origin := Vector3(
                    x % SECTION_SIZE,
                    y % SECTION_SIZE,
                    z % SECTION_SIZE
                )

                # Добавляем только открытые грани.
                for face_index in range(6):

                    var neighbor_index := (
                        center_index + neighbor_offsets[face_index]
                    )

                    if occupancy[neighbor_index] != 0:
                        continue

                    var face: Array = FACE_VERTICES[face_index]

                    var a: Vector3 = block_origin + face[0]
                    var b: Vector3 = block_origin + face[1]
                    var c: Vector3 = block_origin + face[2]
                    var d: Vector3 = block_origin + face[3]

                    vertices.append_array([
                        a, c, b,
                        a, d, c
                    ])

                    for i in range(6):
                        normals.append(FACE_NORMALS[face_index])

                section_data["vertices"] = vertices
                section_data["normals"] = normals

                section_build_data[section_key] = section_data

    # 3. Передаём готовые данные главному потоку.
    completed_mutex.lock()

    completed_chunk_data[request_id] = {
        "key": key,
        "request_id": request_id,
        "section_build_data": section_build_data
    }

    completed_mutex.unlock()

func _is_solid_snapshot(
    cell: Vector3i,
    half_size: float,
    radius_squared: float,
    delta_snapshot: Dictionary,
    has_deltas: bool
) -> bool:

    if cell.x < 0 or cell.x >= SIZE:
        return false
    if cell.y < 0 or cell.y >= SIZE:
        return false
    if cell.z < 0 or cell.z >= SIZE:
        return false

    if has_deltas:
        if _is_destroyed_snapshot(cell, delta_snapshot):
            return false

    var dx := float(cell.x) + 0.5 - half_size
    var dy := float(cell.y) + 0.5 - half_size
    var dz := float(cell.z) + 0.5 - half_size

    return dx * dx + dy * dy + dz * dz <= radius_squared

func _is_destroyed_snapshot(
    cell: Vector3i,
    delta_snapshot: Dictionary
) -> bool:

    var section_id := get_global_section_key(cell)

    if not delta_snapshot.has(section_id):
        return false

    var delta: PackedByteArray = delta_snapshot[section_id]
    var index := get_local_section_index(cell)

    return delta[index] != 0


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

    var section_build_data: Dictionary = result["section_build_data"]

    chunk_data["pending_section_data"] = section_build_data
    chunk_data["pending_section_keys"] = section_build_data.keys()
    chunk_data["section_build_cursor"] = 0

func process_pending_block_creation() -> void:
    var budget: int = settings.sections_per_frame

    var chunk_keys: Array = chunks.keys()
    chunk_keys.sort_custom(_sort_chunk_keys_near_player)

    for key_variant in chunk_keys:
        if budget <= 0:
            break

        var key: Vector3i = key_variant

        if not chunks.has(key):
            continue

        var chunk_data: Dictionary = chunks[key]

        if not chunk_data.has("pending_section_keys"):
            continue

        var section_keys: Array = chunk_data["pending_section_keys"]
        var section_build_data: Dictionary = chunk_data["pending_section_data"]

        var cursor: int = int(chunk_data["section_build_cursor"])

        while cursor < section_keys.size() and budget > 0:
            var section_key: Vector3i = section_keys[cursor]

            var section_data: Dictionary = section_build_data[section_key]

            _finish_section_geometry(
                key,
                section_key,
                section_data["vertices"],
                section_data["normals"]
            )

            cursor += 1
            budget -= 1

        chunk_data["section_build_cursor"] = cursor

        if cursor >= section_keys.size():
            chunk_data.erase("pending_section_keys")
            chunk_data.erase("pending_section_data")
            chunk_data.erase("section_build_cursor")

            chunk_data["generated"] = true

func get_section_key(cell: Vector3i) -> Vector3i:
    var local_cell := Vector3i(
        posmod(cell.x, CHUNK_SIZE),
        posmod(cell.y, CHUNK_SIZE),
        posmod(cell.z, CHUNK_SIZE)
    )

    return Vector3i(
        floori(float(local_cell.x) / SECTION_SIZE),
        floori(float(local_cell.y) / SECTION_SIZE),
        floori(float(local_cell.z) / SECTION_SIZE)
    )


func get_section_origin(
    chunk_key: Vector3i,
    section_key: Vector3i
) -> Vector3i:
    return (
        chunk_key * CHUNK_SIZE
        + section_key * SECTION_SIZE
    )


func get_section_owner(cell: Vector3i) -> Vector3i:
    return index_to_chunk(cell)

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


# -----------------------------------------------------------------------------
# CHUNK MESH AND COLLISION
# -----------------------------------------------------------------------------

func _append_cell_faces(
    cell: Vector3i,
    section_origin: Vector3i,
    vertices: PackedVector3Array,
    normals: PackedVector3Array
) -> void:
    var block_origin := Vector3(cell - section_origin)

    for face_index in range(6):
        var direction: Vector3i = DIRECTIONS[face_index]
        var neighbor: Vector3i = cell + direction

        if is_solid(neighbor.x, neighbor.y, neighbor.z):
            continue

        var face: Array = FACE_VERTICES[face_index]

        var a: Vector3 = block_origin + face[0]
        var b: Vector3 = block_origin + face[1]
        var c: Vector3 = block_origin + face[2]
        var d: Vector3 = block_origin + face[3]

        vertices.append_array([a, c, b, a, d, c])

        for i in range(6):
            normals.append(FACE_NORMALS[face_index])

func _finish_section_geometry(
    chunk_key: Vector3i,
    section_key: Vector3i,
    vertices: PackedVector3Array,
    normals: PackedVector3Array
) -> void:
    if not chunks.has(chunk_key):
        return

    var chunk_data: Dictionary = chunks[chunk_key]
    var root: Node3D = chunk_data["root"]

    # Пустая секция не нуждается в меше.
    if vertices.is_empty():
        _clear_section_geometry(chunk_key, section_key)
        return

    # Создаём корневой узел секции.
    var section_root := Node3D.new()
    section_root.name = "Section_%d_%d_%d" % [
        section_key.x,
        section_key.y,
        section_key.z
    ]

    section_root.position = Vector3(
        section_key * SECTION_SIZE
    )

    root.add_child(section_root)

    # ----------------------------------
    # VISUAL MESH
    # ----------------------------------

    var mesh := ArrayMesh.new()

    var arrays: Array = []
    arrays.resize(Mesh.ARRAY_MAX)

    arrays[Mesh.ARRAY_VERTEX] = vertices
    arrays[Mesh.ARRAY_NORMAL] = normals

    mesh.add_surface_from_arrays(
        Mesh.PRIMITIVE_TRIANGLES,
        arrays
    )

    mesh.surface_set_material(0, terrain_material)

    var mesh_instance := MeshInstance3D.new()
    mesh_instance.name = "SectionMesh"
    mesh_instance.mesh = mesh

    section_root.add_child(mesh_instance)

    # ----------------------------------
    # PHYSICS COLLISION
    # ----------------------------------

    var collision_shape := ConcavePolygonShape3D.new()
    collision_shape.set_faces(vertices)

    var body := StaticBody3D.new()
    body.name = "SectionCollision"
    body.collision_layer = 1
    body.collision_mask = 1

    var shape_node := CollisionShape3D.new()
    shape_node.shape = collision_shape

    body.add_child(shape_node)
    section_root.add_child(body)

    # Сохраняем секцию.
    var sections: Dictionary = chunk_data["sections"]

    # Сохраняем старую секцию до установки новой.
    var old_section: Dictionary = sections.get(section_key, {})

    # Устанавливаем новую геометрию.
    sections[section_key] = {
        "root": section_root,
        "mesh_instance": mesh_instance,
        "physics_body": body
    }

    chunk_data["sections"] = sections

    # Только теперь удаляем старую геометрию.
    if not old_section.is_empty():
        var old_root: Node3D = old_section.get("root")

        if is_instance_valid(old_root):
            old_root.queue_free()



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

    if not section_deltas.is_empty():
        if is_block_destroyed(Vector3i(x, y, z)):
            return false

    var half_size := float(SIZE) * 0.5

    var dx := float(x) + 0.5 - half_size
    var dy := float(y) + 0.5 - half_size
    var dz := float(z) + 0.5 - half_size

    return dx * dx + dy * dy + dz * dz <= RADIUS * RADIUS



func destroy_block(cell: Vector3i) -> bool:
    var destroy_started_usec: int = Time.get_ticks_usec()
    if not is_solid(cell.x, cell.y, cell.z):
        _record_destroy_diagnostic(Time.get_ticks_usec() - destroy_started_usec)
        return false

    set_block_destroyed(cell)

    var chunk_key := index_to_chunk(cell)
    var section_key := get_section_key(cell)

    # Перестраиваем секцию разрушенного блока.
    rebuild_section_geometry(chunk_key, section_key)

    # Открываем грани соседних блоков немедленно.
    for direction_index in range(6):
        var direction: Vector3i = DIRECTIONS[direction_index]
        var neighbor := cell + direction

        if not is_solid(
            neighbor.x,
            neighbor.y,
            neighbor.z
        ):
            continue

        var neighbor_chunk := index_to_chunk(neighbor)
        var neighbor_section := get_section_key(neighbor)

        # Грань соседа, направленная к разрушенному блоку.
        var face_index: int = direction_index ^ 1

        _add_temporary_face(
            neighbor_chunk,
            neighbor_section,
            neighbor,
            face_index
        )

        # Если сосед находится в другой секции,
        # ставим её на фоновую перестройку.
        if (
            neighbor_chunk != chunk_key
            or neighbor_section != section_key
        ):
            rebuild_section_geometry(
                neighbor_chunk,
                neighbor_section
            )

    _record_destroy_diagnostic(Time.get_ticks_usec() - destroy_started_usec)
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


func get_mined_cell(
    ray_origin: Vector3,
    ray_direction: Vector3,
    max_distance: float = 100.0
) -> Vector3i:

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

    var distance := 0.0
    var ray_steps: int = 0

    while distance <= max_distance:
        ray_steps += 1
        if is_solid(cell.x, cell.y, cell.z):
            _record_mining_ray_diagnostic(ray_steps)
            return cell

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

    _record_mining_ray_diagnostic(ray_steps)
    return Vector3i(-1, -1, -1)


func mine(
    ray_origin: Vector3,
    ray_direction: Vector3,
    max_distance: float = 100.0
) -> bool:

    var cell := get_mined_cell(
        ray_origin,
        ray_direction,
        max_distance
    )

    if cell == Vector3i(-1, -1, -1):
        return false

    return destroy_block(cell)


func has_collision_at(world_position: Vector3) -> bool:
    var cell: Vector3i = get_cell(world_position)
    var chunk_key: Vector3i = index_to_chunk(cell)

    if not chunks.has(chunk_key):
        return false

    var chunk_data: Dictionary = chunks[chunk_key]

    if not bool(chunk_data.get("generated", false)):
        return false

    return is_block_visible(cell)


# -----------------------------------------------------------------------------
# CHUNK STREAMING
# -----------------------------------------------------------------------------



func update_streaming(world_position: Vector3) -> void:
    # Переводим позицию игрока в локальные координаты планеты.
    var local_position := to_local(world_position)
    var planet_center := get_planet_center()

    # Направление от центра планеты к игроку.
    var radial_direction := local_position - planet_center

    if radial_direction.length_squared() < 0.0001:
        return

    radial_direction = radial_direction.normalized()

    # Проецируем игрока на поверхность планеты.
    var surface_position := planet_center + radial_direction * RADIUS

    # Определяем центральный чанк поверхности.
    var center_chunk := Vector3i(
        floori(local_position.x / CHUNK_SIZE),
        floori(local_position.y / CHUNK_SIZE),
        floori(local_position.z / CHUNK_SIZE)
    )

    # Обновляем область только при переходе в другой чанк.
    if center_chunk == last_center_chunk:
        return

    last_center_chunk = center_chunk

    var retained_chunks: Dictionary = {}

    # -------------------------------------------------
    # 1. Загружаем чанки поверхности вокруг игрока.
    # -------------------------------------------------

    for z in range(-settings.load_radius, settings.load_radius + 1):
        for y in range(-settings.load_radius, settings.load_radius + 1):
            for x in range(-settings.load_radius, settings.load_radius + 1):
                var key := center_chunk + Vector3i(x, y, z)

                if not is_valid_chunk(key):
                    continue

                if not chunk_intersects_planet(key):
                    continue

                retained_chunks[key] = true

                if not chunks.has(key):
                    create_chunk(key)

    # -------------------------------------------------
    # 2. Загружаем дополнительные чанки над поверхностью.
    # -------------------------------------------------

    for i in range(1, settings.air_chunks_above + 1):
        var above_chunk := center_chunk + Vector3i(
            roundi(radial_direction.x * i),
            roundi(radial_direction.y * i),
            roundi(radial_direction.z * i)
        )

        if not is_valid_chunk(above_chunk):
            continue

        retained_chunks[above_chunk] = true

        if not chunks.has(above_chunk):
            create_chunk(above_chunk)

    # -------------------------------------------------
    # 3. Сохраняем уже загруженные чанки в радиусе выгрузки.
    # -------------------------------------------------

    for z in range(-settings.unload_radius, settings.unload_radius + 1):
        for y in range(-settings.unload_radius, settings.unload_radius + 1):
            for x in range(-settings.unload_radius, settings.unload_radius + 1):
                var key := center_chunk + Vector3i(x, y, z)

                if chunks.has(key):
                    retained_chunks[key] = true

    # -------------------------------------------------
    # 4. Выгружаем чанки, которые больше не нужны.
    # -------------------------------------------------

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

    var chunk_max := chunk_min + Vector3.ONE * CHUNK_SIZE
    var center := get_planet_center()

    var closest := center.clamp(chunk_min, chunk_max)
    var min_distance_squared := closest.distance_squared_to(center)

    # Чанк должен пересекать объём планеты.
    return min_distance_squared <= RADIUS * RADIUS


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
        "sections": {},
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

    # Удаляем ожидающие секции этого чанка.
    for z in range(SECTIONS_PER_CHUNK):
        for y in range(SECTIONS_PER_CHUNK):
            for x in range(SECTIONS_PER_CHUNK):

                var section_key := Vector3i(x, y, z)

                var section_id := make_section_id(
                    key,
                    section_key
                )

                section_queue.erase(section_id)
                queued_sections.erase(section_id)

                # Инвалидируем старую версию.
                section_versions[section_id] = (
                    int(section_versions.get(section_id, 0)) + 1
                )

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

func _clear_section_geometry(
    chunk_key: Vector3i,
    section_key: Vector3i
) -> void:
    if not chunks.has(chunk_key):
        return

    var chunk_data: Dictionary = chunks[chunk_key]
    var sections: Dictionary = chunk_data["sections"]

    if not sections.has(section_key):
        return

    var section_data: Dictionary = sections[section_key]

    var root: Node3D = section_data["root"]

    if is_instance_valid(root):
        var body: StaticBody3D = section_data["physics_body"]

        if is_instance_valid(body):
            body.collision_layer = 0
            body.collision_mask = 0

        root.queue_free()

    sections.erase(section_key)


func rebuild_section_geometry(
    chunk_key: Vector3i,
    section_key: Vector3i
) -> void:
    queue_section_rebuild(chunk_key, section_key)


    


func get_global_section_key(cell: Vector3i) -> Vector3i:
    return Vector3i(
        floori(float(cell.x) / SECTION_SIZE),
        floori(float(cell.y) / SECTION_SIZE),
        floori(float(cell.z) / SECTION_SIZE)
    )


func get_local_section_index(cell: Vector3i) -> int:
    var local := Vector3i(
        posmod(cell.x, SECTION_SIZE),
        posmod(cell.y, SECTION_SIZE),
        posmod(cell.z, SECTION_SIZE)
    )

    return (
        local.z * SECTION_SIZE * SECTION_SIZE
        + local.y * SECTION_SIZE
        + local.x
    )


func is_block_destroyed(cell: Vector3i) -> bool:
    # На нетронутой планете сразу выходим.
    if section_deltas.is_empty():
        return false

    var section_id := get_global_section_key(cell)

    if not section_deltas.has(section_id):
        return false

    var delta: PackedByteArray = section_deltas[section_id]
    var index := get_local_section_index(cell)

    return delta[index] != 0

func set_block_destroyed(cell: Vector3i) -> void:
    var section_id := get_global_section_key(cell)

    var delta: PackedByteArray = section_deltas.get(
        section_id,
        PackedByteArray()
    )

    if delta.is_empty():
        delta.resize(SECTION_SIZE * SECTION_SIZE * SECTION_SIZE)

    var index := get_local_section_index(cell)
    delta[index] = 1

    section_deltas[section_id] = delta


func restore_block(cell: Vector3i) -> bool:
    # Используется для отмены клиентского предсказания,
    # если сервер отклонил добычу или выбрал другую ячейку.
    if not is_block_destroyed(cell):
        return false

    var section_id := get_global_section_key(cell)
    var delta: PackedByteArray = section_deltas[section_id]
    delta[get_local_section_index(cell)] = 0

    var has_destroyed_blocks := false
    for value in delta:
        if value != 0:
            has_destroyed_blocks = true
            break

    if has_destroyed_blocks:
        section_deltas[section_id] = delta
    else:
        section_deltas.erase(section_id)

    # Перестраиваем секцию блока и секции соседей:
    # это также удалит временные открытые грани, созданные при prediction.
    var affected_cells: Array[Vector3i] = [cell]
    for direction in DIRECTIONS:
        affected_cells.append(cell + direction)

    var queued_sections_to_rebuild: Dictionary = {}

    for affected_cell in affected_cells:
        if not is_solid(
            affected_cell.x,
            affected_cell.y,
            affected_cell.z
        ):
            continue

        var chunk_key := index_to_chunk(affected_cell)
        var section_key := get_section_key(affected_cell)
        var section_id_to_rebuild := make_section_id(
            chunk_key,
            section_key
        )

        if queued_sections_to_rebuild.has(section_id_to_rebuild):
            continue

        queued_sections_to_rebuild[section_id_to_rebuild] = true
        rebuild_section_geometry(chunk_key, section_key)

    return true

func create_chunk_delta_snapshot(
    chunk_key: Vector3i
) -> Dictionary:

    var result: Dictionary = {}

    var base := chunk_key * SECTIONS_PER_CHUNK

    # Четыре секции чанка плюс соседние секции
    # для проверки граничных блоков.
    for z in range(base.z - 1, base.z + SECTIONS_PER_CHUNK + 1):
        for y in range(base.y - 1, base.y + SECTIONS_PER_CHUNK + 1):
            for x in range(base.x - 1, base.x + SECTIONS_PER_CHUNK + 1):

                var section_id := Vector3i(x, y, z)

                if section_deltas.has(section_id):
                    result[section_id] = section_deltas[section_id]

    return result


# ============================================================
# DEBUG STATISTICS
# ============================================================

func get_debug_stats() -> Dictionary:
    var generated_chunks := 0
    var generating_chunks := 0
    var pending_initial_sections := 0
    var temporary_sections := 0

    # Статистика загруженных чанков.
    for chunk_key in chunks:
        var chunk_data: Dictionary = chunks[chunk_key]

        if bool(chunk_data.get("generated", false)):
            generated_chunks += 1
        else:
            generating_chunks += 1

        # Секции, которые ещё предстоит создать
        # при первоначальной генерации чанка.
        var pending_keys: Array = chunk_data.get(
            "pending_section_keys", []
        )
        var build_cursor: int = int(
            chunk_data.get("section_build_cursor", 0)
        )

        pending_initial_sections += maxi(
            0,
            pending_keys.size() - build_cursor
        )

        # Секции с временной геометрией после копания.
        var temp_faces: Dictionary = chunk_data.get(
            "temporary_faces", {}
        )
        temporary_sections += temp_faces.size()

    # Получаем количество результатов, ожидающих обработки.
    # Словари защищены Mutex, поэтому читаем их под блокировкой.
    completed_mutex.lock()
    var waiting_chunk_results := completed_chunk_data.size()
    completed_mutex.unlock()

    section_mutex.lock()
    var waiting_section_results := completed_section_data.size()
    section_mutex.unlock()

    # Производительность.
    var fps := Engine.get_frames_per_second()

    var process_ms := (
        Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
    )

    var physics_ms := (
        Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
    )

    var physics_objects := Performance.get_monitor(
        Performance.PHYSICS_3D_ACTIVE_OBJECTS
    )

    var collision_pairs := Performance.get_monitor(
        Performance.PHYSICS_3D_COLLISION_PAIRS
    )

    # Формируем текстовые блоки для интерфейса.
    var performance_text := """
FPS: %d
Process: %.2f ms
Physics: %.2f ms
Physics objects: %d
Collision pairs: %d
""" % [
        fps,
        process_ms,
        physics_ms,
        physics_objects,
        collision_pairs
    ]

    var chunk_text := """
Loaded chunks: %d
Generated chunks: %d
Generating chunks: %d

Chunk queue: %d
Chunk worker tasks: %d
Active chunk requests: %d
Waiting chunk results: %d

Initial sections pending: %d
Center chunk: %s
""" % [
        chunks.size(),
        generated_chunks,
        generating_chunks,

        chunk_queue.size(),
        worker_task_ids.size(),
        active_chunk_requests.size(),
        waiting_chunk_results,

        pending_initial_sections,
        str(last_center_chunk)
    ]

    var section_text := """
Section queue: %d
Queued sections: %d

Section worker tasks: %d
Active section requests: %d
Waiting section results: %d

Temporary sections: %d
""" % [
        section_queue.size(),
        queued_sections.size(),

        section_worker_task_ids.size(),
        active_section_requests.size(),
        waiting_section_results,

        temporary_sections
    ]

    return {
        "performance": performance_text,
        "chunks": chunk_text,
        "sections": section_text
    }

func configure_world(
    server_scale: int,
    server_terrain_color: Color
) -> bool:
    if server_scale < 1 or server_scale > 1000:
        push_error("Invalid planet scale: %d" % server_scale)
        return false

    if not chunks.is_empty():
        push_error("Cannot configure planet after chunk loading!")
        return false

    # Новый серверный снимок полностью заменяет старые изменения мира.
    # configure_world вызывается до генерации чанков на клиенте.
    section_deltas.clear()

    # Настраиваем только этот экземпляр планеты.
    # Общий GameSettings ресурс не изменяется.
    world_scale = server_scale
    world_terrain_color = server_terrain_color

    if is_instance_valid(terrain_material):
        terrain_material.albedo_color = world_terrain_color

    last_center_chunk = Vector3i(
        -999999,
        -999999,
        -999999
    )

    return true


