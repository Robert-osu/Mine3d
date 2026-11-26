
extends Resource
class_name GameSettings

# ============================================================
# PLANET
# ============================================================

@export_group("Planet")
@export_range(1, 1000) var planet_scale: int = 5
@export var terrain_color: Color = Color("#8b765e")

# ============================================================
# CHUNKS
# ============================================================

@export_group("Chunks")
@export_range(1, 8) var load_radius: int = 3
@export_range(0, 16) var air_chunks_above: int = 4
@export_range(1, 6) var unload_radius: int = 3
@export_range(1, 4096) var blocks_per_frame: int = 512
@export_range(1, 16) var sections_per_frame: int = 2

@export_group("Chunk Generation")

@export_range(1, 16) var max_parallel_chunks: int = 2
@export_range(1, 16) var max_chunks_per_frame: int = 1

@export_group("Section Generation")

@export_range(1, 16) var max_parallel_section_jobs: int = 2
@export_range(1, 16) var max_section_jobs_per_frame: int = 2

# ============================================================
# PLAYER
# ============================================================

@export_group("Movement")
@export var move_speed: float = 10.0
@export var acceleration: float = 20.0
@export var gravity: float = 18
@export var jump_force: float = 10.5

@export_group("Mining")

@export_range(1.0, 100.0, 0.5) var mining_distance: float = 10.0

# ============================================================
# COLLISION
# ============================================================

@export_group("Collision")
@export var collision_radius: float = 0.35
@export var collision_height: float = 1.4

# ============================================================
# CAMERA
# ============================================================

@export_group("Camera")
@export var mouse_sensitivity: float = 0.003
@export var min_pitch: float = -89.0
@export var max_pitch: float = 89.0
@export var camera_height: float = 0.8

# ============================================================
# FLASHLIGHT
# ============================================================

@export_group("Flashlight")
@export var flashlight_range: float = 24.0
@export var flashlight_angle: float = 55.0
@export var flashlight_energy: float = 7.0

# ============================================================
# NETWORK
# ============================================================

@export_group("Network")
@export var port: int = 7777
@export var max_clients: int = 100
@export var snapshot_interval: int = 3

# ============================================================
# NETWORK SMOOTHING
# ============================================================

@export_group("Network Smoothing")
@export var reconciliation_epsilon: float = 0.02
@export var correction_smoothing: float = 12.0
@export var interpolation_delay: float = 0.1
@export var max_remote_snapshots: int = 8

