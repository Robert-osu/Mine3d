
extends StaticBody3D
class_name Planet

@export_group("Planet")
@export_range(1, 1000) var planet_scale := 5

@export_group("Chunks")
@export_range(1, 4) var load_radius := 1

@export_group("Visual")
@export_range(0.0, 1.0) var smoothness := 0.0

const CHUNK_SIZE := 32
const BLOCK_SIZE := 1.0

var SIZE: int
var RADIUS: float

var chunks: Dictionary = {}
var destroyed_blocks: Dictionary = {}

var terrain_material: StandardMaterial3D
var last_center_chunk := Vector3i(-999999, -999999, -999999)




func _ready() -> void:
    SIZE = 32 * planet_scale
    RADIUS = 14.0 * planet_scale

    terrain_material = StandardMaterial3D.new()
    terrain_material.albedo_color = Color("#8b765e")
    terrain_material.roughness = 1.0
    terrain_material.cull_mode = BaseMaterial3D.CULL_DISABLED

    print("Planet initialized. Size: ", SIZE, " Radius: ", RADIUS)


func get_planet_center() -> Vector3:
    return Vector3(SIZE, SIZE, SIZE) * 0.5


func index_to_chunk(cell: Vector3i) -> Vector3i:
    return Vector3i(
        floori(float(cell.x) / CHUNK_SIZE),
        floori(float(cell.y) / CHUNK_SIZE),
        floori(float(cell.z) / CHUNK_SIZE)
    )


# --------------------------------------------------
# BLOCK STORAGE
# --------------------------------------------------

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

    var center := get_planet_center()
    var block_center := Vector3(x, y, z) + Vector3.ONE * 0.5

    return block_center.distance_squared_to(center) <= RADIUS * RADIUS


func destroy_block(cell: Vector3i) -> bool:
    if not is_solid(cell.x, cell.y, cell.z):
        return false

    destroyed_blocks[cell] = true

    var chunk_key := index_to_chunk(cell)

    # Перестраиваем основной чанк.
    rebuild_if_loaded(chunk_key)

    # Перестраиваем соседей, если блок находился на границе.
    var local := Vector3i(
        cell.x % CHUNK_SIZE,
        cell.y % CHUNK_SIZE,
        cell.z % CHUNK_SIZE
    )

    if local.x == 0:
        rebuild_if_loaded(chunk_key + Vector3i(-1, 0, 0))
    elif local.x == CHUNK_SIZE - 1:
        rebuild_if_loaded(chunk_key + Vector3i(1, 0, 0))

    if local.y == 0:
        rebuild_if_loaded(chunk_key + Vector3i(0, -1, 0))
    elif local.y == CHUNK_SIZE - 1:
        rebuild_if_loaded(chunk_key + Vector3i(0, 1, 0))

    if local.z == 0:
        rebuild_if_loaded(chunk_key + Vector3i(0, 0, -1))
    elif local.z == CHUNK_SIZE - 1:
        rebuild_if_loaded(chunk_key + Vector3i(0, 0, 1))

    return true


func rebuild_if_loaded(key: Vector3i) -> void:
    if chunks.has(key):
        rebuild_chunk(key)


# --------------------------------------------------
# CHUNK STREAMING
# --------------------------------------------------

func update_streaming(world_position: Vector3) -> void:
    var local_position := to_local(world_position)

    var center_chunk := Vector3i(
        floori(local_position.x / CHUNK_SIZE),
        floori(local_position.y / CHUNK_SIZE),
        floori(local_position.z / CHUNK_SIZE)
    )

    # Не обновляем чанки, если игрок остался в том же чанке.
    if center_chunk == last_center_chunk:
        return

    last_center_chunk = center_chunk

    var required_chunks: Dictionary = {}

    # Загружаем чанки вокруг игрока.
    for z in range(-load_radius, load_radius + 1):
        for y in range(-load_radius, load_radius + 1):
            for x in range(-load_radius, load_radius + 1):

                var key := center_chunk + Vector3i(x, y, z)

                if not is_valid_chunk(key):
                    continue

                if not chunk_intersects_planet(key):
                    continue

                required_chunks[key] = true

                if not chunks.has(key):
                    create_chunk(key)

    # Выгружаем чанки, которые больше не нужны.
    var loaded_keys := chunks.keys()

    for key in loaded_keys:
        if not required_chunks.has(key):
            unload_chunk(key)

    print("Loaded chunks: ", chunks.size())


func is_valid_chunk(key: Vector3i) -> bool:
    var max_chunks := ceili(float(SIZE) / CHUNK_SIZE)

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

    var closest := get_planet_center().clamp(
        chunk_min,
        chunk_max
    )

    return closest.distance_to(get_planet_center()) <= RADIUS + 1.0


func create_chunk(key: Vector3i) -> void:
    var root := Node3D.new()
    root.name = "Chunk_%d_%d_%d" % [key.x, key.y, key.z]

    root.position = Vector3(
        key.x * CHUNK_SIZE,
        key.y * CHUNK_SIZE,
        key.z * CHUNK_SIZE
    )

    add_child(root)

    var mesh_instance := MeshInstance3D.new()
    root.add_child(mesh_instance)

    var body := StaticBody3D.new()
    root.add_child(body)

    var collision := CollisionShape3D.new()
    body.add_child(collision)

    chunks[key] = {
        "root": root,
        "mesh": mesh_instance,
        "collision": collision
    }

    rebuild_chunk(key)


func unload_chunk(key: Vector3i) -> void:
    if not chunks.has(key):
        return

    var data: Dictionary = chunks[key]
    var root: Node3D = data["root"]

    root.queue_free()
    chunks.erase(key)


# --------------------------------------------------
# CHUNK MESH
# --------------------------------------------------

func rebuild_chunk(key: Vector3i) -> void:
    if not chunks.has(key):
        return

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

    var data: Dictionary = chunks[key]
    var mesh_instance: MeshInstance3D = data["mesh"]
    var collision: CollisionShape3D = data["collision"]

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
        collision.set_deferred("shape", shape)
    else:
        collision.set_deferred("shape", null)

    mesh_instance.mesh = new_mesh


# --------------------------------------------------
# MINING
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
