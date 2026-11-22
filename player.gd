
extends CharacterBody3D

@export var planet: Planet

@export_group("Movement")
@export var move_speed := 5.0
@export var acceleration := 20.0
@export var gravity := 20.0 / 3
@export var jump_force := 7.0 * 1.5

@export_group("Camera")
@export var mouse_sensitivity := 0.003
@export var min_pitch := -89.0
@export var max_pitch := 89.0
@export var camera_height := 0.8

@export_group("Flashlight")
@export var flashlight_range := 24.0
@export var flashlight_angle := 55.0
@export var flashlight_energy := 7.0

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D

var vertical_speed := 0.0
var heading := Vector3.FORWARD
var mining_requested := false
var spawn_ready := false


func _ready() -> void:
    if planet == null:
        push_error("Assign Planet in Player Inspector!")
        return

    planet.update_streaming(global_position)

    var center := planet.to_global(planet.get_planet_center())

    var spawn_direction := Vector3.UP

    # Радиус планеты + небольшой запас над поверхностью.
    var spawn_distance := planet.RADIUS + 2.0
    
    var direction := Vector3.UP

    var surface_point := center + direction * (planet.RADIUS - 0.5)

    global_position = center + direction * (planet.RADIUS + 3.0)

    planet.update_streaming(global_position)

    while not planet.has_collision_at(surface_point):
        await get_tree().process_frame

    spawn_ready = true

    heading = Vector3.FORWARD.slide(spawn_direction).normalized()

    up_direction = spawn_direction
    update_orientation(spawn_direction)

    # Камера находится непосредственно на персонаже.
    camera_pivot.position = Vector3(0, camera_height, 0)
    camera_pivot.rotation = Vector3.ZERO

    camera.position = Vector3.ZERO
    camera.rotation = Vector3.ZERO
    camera.make_current()

    create_flashlight()

    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func create_flashlight() -> void:
    var flashlight := SpotLight3D.new()

    flashlight.name = "Flashlight"
    flashlight.position = Vector3.ZERO
    flashlight.rotation = Vector3.ZERO

    flashlight.spot_range = flashlight_range
    flashlight.spot_angle = flashlight_angle
    flashlight.light_energy = flashlight_energy

    flashlight.spot_attenuation = 1.0
    flashlight.shadow_enabled = true
    flashlight.light_color = Color(0.85, 0.92, 1.0)

    camera.add_child(flashlight)


func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventMouseMotion:
        if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
            if planet != null:
                var center := planet.to_global(Vector3(planet.SIZE / 2.0, planet.SIZE / 2.0, planet.SIZE / 2.0))
                var up := (global_position - center).normalized()

                # Поворачиваем персонажа по горизонтали.
                heading = heading.rotated(
                    up,
                    -event.relative.x * mouse_sensitivity
                ).normalized()

            # Вертикальный поворот только камеры.
            camera_pivot.rotation.x -= event.relative.y * mouse_sensitivity

            camera_pivot.rotation.x = clampf(
                camera_pivot.rotation.x,
                deg_to_rad(min_pitch),
                deg_to_rad(max_pitch)
            )

    if event is InputEventKey:
        if event.pressed and event.keycode == KEY_ESCAPE:
            Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

    if event is InputEventMouseButton:
        if event.pressed:
            if event.button_index == MOUSE_BUTTON_LEFT:
                if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
                    mining_requested = true

            if event.button_index == MOUSE_BUTTON_RIGHT:
                if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
                    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _physics_process(delta: float) -> void:
    if not spawn_ready:
        return

    if planet == null:
        return

    var center := planet.to_global(planet.get_planet_center())
    var up := (global_position - center).normalized()

    up_direction = up

    update_orientation(up)

    # Управление относительно направления взгляда.
    var input := Input.get_vector(
        "move_left",
        "move_right",
        "move_forward",
        "move_backward"
    )

    var camera_forward := -camera.global_basis.z
    var camera_right := camera.global_basis.x

    camera_forward = camera_forward.slide(up).normalized()
    camera_right = camera_right.slide(up).normalized()

    var move_direction := (
        camera_right * input.x
        + camera_forward * -input.y
    ).normalized()

    

    var horizontal_velocity := velocity.slide(up)

    if move_direction.length_squared() > 0.001:
        horizontal_velocity = horizontal_velocity.move_toward(
            move_direction * move_speed,
            acceleration * delta
        )
    else:
        horizontal_velocity = horizontal_velocity.move_toward(
            Vector3.ZERO,
            acceleration * delta
        )

    # Гравитация.
    if is_on_floor():
        vertical_speed = 0.0

        if Input.is_action_just_pressed("jump"):
            vertical_speed = jump_force
    else:
        vertical_speed -= gravity * delta

    velocity = horizontal_velocity + up * vertical_speed

    move_and_slide()

    planet.update_streaming(global_position)

    vertical_speed = velocity.dot(up)

    # Добыча.
    if mining_requested:
        mining_requested = false
        mine_block()


func update_orientation(up: Vector3) -> void:
    heading = heading.slide(up).normalized()

    if heading.length_squared() < 0.001:
        heading = Vector3.FORWARD.slide(up).normalized()

    var right := heading.cross(up).normalized()
    var backward := -heading

    global_basis = Basis(
        right,
        up,
        backward
    ).orthonormalized()


func mine_block() -> void:
    var origin := camera.global_position
    var direction := -camera.global_basis.z

    var success := planet.mine(
        origin,
        direction,
        10.0
    )

    if success:
        print("Block mined!")
    else:
        print("No block in reach!")
