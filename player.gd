
extends CharacterBody3D

@export var planet: Planet

var settings: GameSettings:
    get:
        return GameConfig.SETTINGS

@onready var camera_pivot: Node3D = $CameraPivot
@onready var camera: Camera3D = $CameraPivot/Camera3D
# @onready var coord_label: Label = $Player/DebugPanel/VBoxContainer/CoordLabel
@onready var collision_shape: CollisionShape3D = $CollisionShape3D

@onready var visual: Node3D = $Visual

var visual_rest_position := Vector3.ZERO
var camera_rest_position := Vector3.ZERO

const VISUAL_CORRECTION_SPEED := 12.0

var vertical_speed := 0.0
var heading := Vector3.FORWARD
var pending_mining_requests: int = 0
var spawn_ready := false
var is_remote: bool = false

var mining_ray: MeshInstance3D

func _ready() -> void:
    if is_remote:
        # Удалённому игроку не нужна камера.
        camera_pivot.visible = false
        camera.current = false

        # Удалённые персонажи не участвуют
        # в локальной физике.
        collision_shape.disabled = true

        set_physics_process(false)
        set_process_unhandled_input(false)

        return

    if planet == null:
        push_error("Assign Planet in Player Inspector!")
        return

    # Клиент ждёт подтверждения подключения и настройки мира.
    if not multiplayer.is_server():
        while not Network.connection_network.connected:
            if not multiplayer.has_multiplayer_peer():
                return

            await get_tree().process_frame

    var center := planet.to_global(planet.get_planet_center())
    var player_id := multiplayer.get_unique_id()
    var spawn_position := Network.get_player_spawn_position(
        planet,
        player_id
    )
    var spawn_direction := (spawn_position - center).normalized()
    var surface_point := center + spawn_direction * (planet.RADIUS - 0.5)

    global_position = spawn_position
    planet.update_streaming(global_position)

    # Не ждём бесконечно, если точка появления повреждена
    # или нужная секция мира не смогла сгенерироваться.
    var spawn_wait_started := Time.get_ticks_msec()
    const SPAWN_TIMEOUT_MSEC: int = 15000

    while not planet.has_collision_at(surface_point):
        if Time.get_ticks_msec() - spawn_wait_started >= SPAWN_TIMEOUT_MSEC:
            push_error(
                "Player spawn timed out. ID: ",
                player_id,
                " | Position: ",
                spawn_position
            )
            return

        await get_tree().process_frame

    spawn_ready = true

    Network.register_local_player(self)
    

    heading = Vector3.FORWARD.slide(spawn_direction).normalized()

    up_direction = spawn_direction
    update_orientation(spawn_direction)

    # Камера находится непосредственно на персонаже.
    camera_pivot.position = Vector3(0, settings.camera_height, 0)
    camera_pivot.rotation = Vector3.ZERO

    visual_rest_position = visual.position
    camera_rest_position = camera_pivot.position

    camera.position = Vector3.ZERO
    camera.rotation = Vector3.ZERO
    camera.make_current()

    create_flashlight()

func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_IN and not is_remote:
        Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func apply_reconciliation_correction(old_position: Vector3) -> void:
    var world_offset := old_position - global_position
    var local_offset := global_basis.inverse() * world_offset

    visual.position += local_offset
    camera_pivot.position += local_offset

func create_flashlight() -> void:
    var flashlight := SpotLight3D.new()

    flashlight.name = "Flashlight"
    flashlight.position = Vector3.ZERO
    flashlight.rotation = Vector3.ZERO

    flashlight.spot_range = settings.flashlight_range
    flashlight.spot_angle = settings.flashlight_angle
    flashlight.light_energy = settings.flashlight_energy

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
                    -event.relative.x * settings.mouse_sensitivity
                ).normalized()

            # Вертикальный поворот только камеры.
            camera_pivot.rotation.x -= event.relative.y * settings.mouse_sensitivity

            camera_pivot.rotation.x = clampf(
                camera_pivot.rotation.x,
                deg_to_rad(settings.min_pitch),
                deg_to_rad(settings.max_pitch)
            )

    if event is InputEventKey:
        if event.pressed and event.keycode == KEY_ESCAPE:
            Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

    if event is InputEventMouseButton:
        if event.pressed:
            if event.button_index == MOUSE_BUTTON_LEFT:
                if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
                    pending_mining_requests = mini(
                        pending_mining_requests + 1,
                        8
                    )

            if event.button_index == MOUSE_BUTTON_RIGHT:
                if Input.mouse_mode == Input.MOUSE_MODE_VISIBLE:
                    Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

func _physics_process(delta: float) -> void:
    if is_remote:
        return

    var weight := 1.0 - exp(-VISUAL_CORRECTION_SPEED * delta)

    visual.position = visual.position.lerp(
        visual_rest_position,
        weight
    )

    camera_pivot.position = camera_pivot.position.lerp(
        camera_rest_position,
        weight
    )

    if not spawn_ready:
        return

    if planet == null:
        return

    var center := planet.to_global(planet.get_planet_center())
    var up := (global_position - center).normalized()

    up_direction = up

    update_orientation(up)

    # Получаем ввод.
    var input := Input.get_vector(
        "move_left",
        "move_right",
        "move_forward",
        "move_backward"
    )

    # Направление камеры.
    var look_direction := -camera.global_basis.z

    # Кнопки.
    var buttons := NetworkProtocol.Buttons.NONE

    if Input.is_action_pressed("jump"):
        buttons |= NetworkProtocol.Buttons.JUMP

    # Забираем накопленные удары и прикрепляем их к текущему input.
    var mine_requests_this_tick := pending_mining_requests
    pending_mining_requests = 0

    # Остаточная скорость при контакте с поверхностью не означает,
    # что игрок действительно движется. Для добычи учитываем ввод
    # направления и состояние опоры из предыдущего шага симуляции.
    var is_moving := (
        input.length_squared() > 0.01
        or not Network.local_grounded
    )

    if is_moving:
        mine_requests_this_tick = 0

    # Серверная симуляция + клиентское предсказание.
    Network.process_local_player(
        self,
        delta,
        input,
        look_direction,
        buttons,
        mine_requests_this_tick
    )

    # Обновляем чанки.
    planet.update_streaming(global_position)


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


