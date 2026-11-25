
extends Control

@export var planet: Planet

@onready var performance_label: Label = $VBoxContainer/PerformanceLabel
@onready var chunks_label: Label = $VBoxContainer/ChunksLabel
@onready var sections_label: Label = $VBoxContainer/SectionsLabel

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

func _process(_delta: float) -> void:
	if not is_instance_valid(planet):
		return

	var stats := planet.get_debug_stats()

	performance_label.text = stats["performance"]
	chunks_label.text = stats["chunks"]
	sections_label.text = stats["sections"]
