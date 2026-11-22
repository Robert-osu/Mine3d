
extends StaticBody3D
class_name Planet

@export_group("Visual")
@export_range(0.0, 1.0) var smoothness := 0.8

const k_size = 5

const SIZE := 32 * k_size
const RADIUS := 14.0 * k_size
const BLOCK_SIZE := 1.0
const CHUNK_SIZE := 8

var blocks := PackedByteArray()
var chunks: Dictionary = {}
var terrain_material: StandardMaterial3D


func _ready() -> void:
    blocks.resize(SIZE * SIZE * SIZE)

    terrain_material = StandardMaterial3D.new()
    terrain_material.albedo_color = Color("#8b765e")
    terrain_material.roughness = 1.0
    terrain_material.cull_mode = BaseMaterial3D.CULL_DISABLED

    generate_planet()
    generate_chunks()


func index_of(x: int, y: int, z: int) -> int:
    return x + SIZE * (y + SIZE * z)


func is_solid(x: int, y: int, z: int) -> bool:
    if x < 0 or x >= SIZE:
        return false
    if y < 0 or y >= SIZE:
        return false
    if z < 0 or z >= SIZE:
        return false

    return blocks[index_of(x, y, z)] == 1


func generate_planet() -> void:
    var center := Vector3(SIZE, SIZE, SIZE) * 0.5

    for z in range(SIZE):
        for y in range(SIZE):
            for x in range(SIZE):
                var pos := Vector3(x, y, z) + Vector3.ONE * 0.5

                if pos.distance_to(center) <= RADIUS:
                    blocks[index_of(x, y, z)] = 1


# --------------------------------------------------
# CHUNKS
# --------------------------------------------------

func generate_chunks() -> void:
    for z in range(SIZE / CHUNK_SIZE):
        for y in range(SIZE / CHUNK_SIZE):
            for x in range(SIZE / CHUNK_SIZE):
                rebuild_chunk(Vector3i(x, y, z))


func rebuild_chunk(key: Vector3i) -> void:
    if (
        key.x < 0 or key.x >= SIZE / CHUNK_SIZE
        or key.y < 0 or key.y >= SIZE / CHUNK_SIZE
        or key.z < 0 or key.z >= SIZE / CHUNK_SIZE
    ):
        return

    var chunk_origin := Vector3(
        key.x * CHUNK_SIZE,
        key.y * CHUNK_SIZE,
        key.z * CHUNK_SIZE
    )

    var vertices := PackedVector3Array()
    var normals := PackedVector3Array()

    var directions := [
        Vector3i(1, 0, 0),
        Vector3i(-1, 0, 0),
        Vector3i(0, 1, 0),
        Vector3i(0, -1, 0),
        Vector3i(0, 0, 1),
        Vector3i(0, 0, -1)
    ]

    var faces := [
        [Vector3(1,0,0), Vector3(1,1,0), Vector3(1,1,1), Vector3(1,0,1)],
        [Vector3(0,0,1), Vector3(0,1,1), Vector3(0,1,0), Vector3(0,0,0)],
        [Vector3(0,1,1), Vector3(1,1,1), Vector3(1,1,0), Vector3(0,1,0)],
        [Vector3(0,0,0), Vector3(1,0,0), Vector3(1,0,1), Vector3(0,0,1)],
        [Vector3(1,0,1), Vector3(1,1,1), Vector3(0,1,1), Vector3(0,0,1)],
        [Vector3(0,0,0), Vector3(0,1,0), Vector3(1,1,0), Vector3(1,0,0)]
    ]

    var face_normals := [
        Vector3.RIGHT,
        Vector3.LEFT,
        Vector3.UP,
        Vector3.DOWN,
        Vector3.BACK,
        Vector3.FORWARD
    ]

    for z in range(CHUNK_SIZE):
        for y in range(CHUNK_SIZE):
            for x in range(CHUNK_SIZE):

                var gx := key.x * CHUNK_SIZE + x
                var gy := key.y * CHUNK_SIZE + y
                var gz := key.z * CHUNK_SIZE + z

                if not is_solid(gx, gy, gz):
                    continue

                var origin := Vector3(x, y, z) * BLOCK_SIZE

                for i in range(6):
                    var direction: Vector3i = directions[i]

                    if is_solid(
                        gx + direction.x,
                        gy + direction.y,
                        gz + direction.z
                    ):
                        continue

                    var face: Array = faces[i]
                    var normal: Vector3 = face_normals[i]

                    var a: Vector3 = origin + face[0]
                    var b: Vector3 = origin + face[1]
                    var c: Vector3 = origin + face[2]
                    var d: Vector3 = origin + face[3]

                    vertices.append_array([
                        a, c, b,
                        a, d, c
                    ])

                    for j in range(6):
                        normals.append(normal)

    # Получаем или создаём объекты чанка.
    var data: Dictionary

    if chunks.has(key):
        data = chunks[key]
    else:
        var root := Node3D.new()
        root.name = "Chunk_%d_%d_%d" % [key.x, key.y, key.z]
        root.position = chunk_origin
        add_child(root)

        var mesh_instance := MeshInstance3D.new()
        root.add_child(mesh_instance)

        var body := StaticBody3D.new()
        root.add_child(body)

        var collision := CollisionShape3D.new()
        body.add_child(collision)

        data = {
            "root": root,
            "mesh": mesh_instance,
            "collision": collision
        }

        chunks[key] = data

    var new_mesh := ArrayMesh.new()

    if vertices.size() > 0:
        var arrays: Array = []
        arrays.resize(Mesh.ARRAY_MAX)

        arrays[Mesh.ARRAY_VERTEX] = vertices
        arrays[Mesh.ARRAY_NORMAL] = normals

        new_mesh.add_surface_from_arrays(
            Mesh.PRIMITIVE_TRIANGLES,
            arrays
        )

        new_mesh.surface_set_material(0, terrain_material)

        var shape := new_mesh.create_trimesh_shape()

        data["collision"].set_deferred("shape", shape)
    else:
        data["collision"].set_deferred("shape", null)

    data["mesh"].mesh = new_mesh


# --------------------------------------------------
# BLOCK DESTRUCTION
# --------------------------------------------------

func destroy_block(cell: Vector3i) -> bool:
    if not is_solid(cell.x, cell.y, cell.z):
        return false

    blocks[index_of(cell.x, cell.y, cell.z)] = 0

    var chunk_key := Vector3i(
        cell.x / CHUNK_SIZE,
        cell.y / CHUNK_SIZE,
        cell.z / CHUNK_SIZE
    )

    # Перестраиваем основной чанк.
    rebuild_chunk(chunk_key)

    # Если блок был на границе, обновляем соседей.
    var local := Vector3i(
        cell.x % CHUNK_SIZE,
        cell.y % CHUNK_SIZE,
        cell.z % CHUNK_SIZE
    )

    if local.x == 0:
        rebuild_chunk(chunk_key + Vector3i(-1, 0, 0))
    elif local.x == CHUNK_SIZE - 1:
        rebuild_chunk(chunk_key + Vector3i(1, 0, 0))

    if local.y == 0:
        rebuild_chunk(chunk_key + Vector3i(0, -1, 0))
    elif local.y == CHUNK_SIZE - 1:
        rebuild_chunk(chunk_key + Vector3i(0, 1, 0))

    if local.z == 0:
        rebuild_chunk(chunk_key + Vector3i(0, 0, -1))
    elif local.z == CHUNK_SIZE - 1:
        rebuild_chunk(chunk_key + Vector3i(0, 0, 1))

    return true


# --------------------------------------------------
# RAYCAST / MINING
# --------------------------------------------------

func get_cell(world_position: Vector3) -> Vector3i:
    var local_position := to_local(world_position)

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

    # Переводим луч в локальные координаты планеты.
    var origin := to_local(ray_origin)
    var direction := (
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
        INF if direction.x == 0.0 else (
            (cell.x + (1 if step.x > 0 else 0) - origin.x) / direction.x
        ),
        INF if direction.y == 0.0 else (
            (cell.y + (1 if step.y > 0 else 0) - origin.y) / direction.y
        ),
        INF if direction.z == 0.0 else (
            (cell.z + (1 if step.z > 0 else 0) - origin.z) / direction.z
        )
    )

    var distance := 0.0

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


func smooth_vertex(vertex: Vector3) -> Vector3:
    var center := Vector3(SIZE, SIZE, SIZE) * 0.5

    var direction := (vertex - center).normalized()

    var radius := (vertex - center).length()

    var target := center + direction * RADIUS

    return vertex.lerp(target, smoothness)