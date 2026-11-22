extends Control

@onready var toolbar: HBoxContainer = $RootLayout/MainSplit/Workspace/ToolbarButtons

@onready var add_node_button: TextureButton = toolbar.get_node("AddNodeButton")
@onready var delete_button: Button = toolbar.get_node("DeleteButton")
@onready var save_button: Button = toolbar.get_node("SaveButton")
@onready var load_button: Button = toolbar.get_node("LoadButton")

@onready var graph_edit: GraphEdit = $RootLayout/MainSplit/Workspace/GraphEdit
@onready var node_list: ItemList = $RootLayout/MainSplit/NodeListPanel/VBoxContainer/NodeList

@onready var AVAILABLE_NODES := NodeDefinitions.get_node_names()

var clipboard_nodes: Array[Dictionary] = []
var clipboard_base: Vector2 = Vector2.ZERO

# История действий
var history: Array[Dictionary] = []
var history_index: int = -1

const MAX_HISTORY := 100

func _ready() -> void:
	add_node_button.pressed.connect(_on_add_node_pressed)
	delete_button.pressed.connect(_on_delete_pressed)
	save_button.pressed.connect(_on_save_pressed)
	load_button.pressed.connect(_on_load_pressed)

	for node_name in AVAILABLE_NODES:
		node_list.add_item(node_name)

	# Отслеживание перемещения нод
	graph_edit.end_node_move.connect(_commit_history)

	# Начальное состояние редактора
	_commit_history()

	node_list.item_activated.connect(_on_node_list_activated)




func _on_add_node_pressed() -> void:
	var selected_items := node_list.get_selected_items()

	if selected_items.is_empty():
		return

	var node_name := node_list.get_item_text(
		selected_items[0]
	)

	_create_graph_node(node_name)


func _on_node_list_activated(index: int) -> void:
	var node_name := node_list.get_item_text(index)
	_create_graph_node(node_name)


func _create_graph_node(node_name: String) -> void:
	var node := EditorGraphNode.new()

	node.setup(node_name)

	node.position_offset = Vector2(
		randf_range(0, 400),
		randf_range(0, 300)
	)

	graph_edit.add_child(node)
	_register_node(node)

	_commit_history()



func _on_delete_pressed() -> void:
	var deleted := false

	for node in graph_edit.get_children():
		if node is GraphNode and node.selected:
			node.queue_free()
			deleted = true

	if deleted:
		_commit_history.call_deferred()

func _on_save_pressed() -> void:
	pass

func _on_load_pressed() -> void:
	pass



func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:

		if event.ctrl_pressed:
			match event.keycode:
				KEY_Z:
					if event.shift_pressed:
						_redo()
					else:
						_undo()

					get_viewport().set_input_as_handled()

				KEY_C:
					_copy_selected_nodes()
					get_viewport().set_input_as_handled()

				KEY_V:
					_paste_nodes()
					get_viewport().set_input_as_handled()



func _copy_selected_nodes() -> void:
	clipboard_nodes.clear()

	var min_pos := Vector2(INF, INF)

	for node in graph_edit.get_children():
		if node is EditorGraphNode and node.selected:
			clipboard_nodes.append({
				"node_type": node.node_type,
				"position_offset": node.position_offset,
				"properties": node.properties.duplicate(true)
			})

			min_pos.x = min(min_pos.x, node.position_offset.x)
			min_pos.y = min(min_pos.y, node.position_offset.y)

	if not clipboard_nodes.is_empty():
		clipboard_base = min_pos
	else:
		clipboard_base = Vector2.ZERO


func _paste_nodes() -> void:
	if clipboard_nodes.is_empty():
		return

	var paste_offset := Vector2(30, 30)
	var new_nodes: Array[EditorGraphNode] = []

	# Создаём новые ноды
	for node_data in clipboard_nodes:
		var node := EditorGraphNode.new()

		# Создаём интерфейс ноды
		node.setup(node_data.node_type)

		# Восстанавливаем свойства
		node.properties = node_data.properties.duplicate(true)

		# Обновляем значения элементов интерфейса
		node.update_properties()

		# Восстанавливаем позицию
		node.position_offset = node_data.position_offset + paste_offset

		graph_edit.add_child(node)
		_register_node(node)
		new_nodes.append(node)

	# Снимаем выделение со старых нод
	for node in graph_edit.get_children():
		if node is GraphNode:
			node.selected = false

	# Выделяем новые ноды
	for node in new_nodes:
		node.selected = true

	_commit_history()


# Создание снимка текущего состояния графа
func _capture_graph_state() -> Dictionary:
	var state := {
		"nodes": []
	}

	for node in graph_edit.get_children():
		if node is EditorGraphNode:
			state.nodes.append({
				"node_type": node.node_type,
				"position_offset": node.position_offset,
				"properties": node.properties.duplicate(true)
			})

	return state


# Сохранение нового состояния в истории
func _commit_history() -> void:
	var new_state := _capture_graph_state()

	# Не сохраняем одинаковые состояния
	if history_index >= 0:
		if history[history_index] == new_state:
			return

	# Удаляем историю после текущего состояния
	if history_index < history.size() - 1:
		history.resize(history_index + 1)

	history.append(new_state)
	history_index = history.size() - 1

	# Ограничиваем размер истории
	if history.size() > MAX_HISTORY:
		history.pop_front()
		history_index -= 1


# Восстановление состояния графа
func _restore_graph_state(state: Dictionary) -> void:
	# Удаляем старые ноды
	for child in graph_edit.get_children():
		if child is GraphNode:
			graph_edit.remove_child(child)
			child.queue_free()

	# Создаём ноды заново
	for node_data in state.nodes:
		var node := EditorGraphNode.new()

		node.setup(node_data.node_type)

		node.properties = node_data.properties.duplicate(true)
		node.update_properties()

		node.position_offset = node_data.position_offset

		graph_edit.add_child(node)
		_register_node(node)


# Отмена действия
func _undo() -> void:
	if history_index <= 0:
		return

	history_index -= 1

	_restore_graph_state(history[history_index])


# Восстановление отменённого действия
func _redo() -> void:
	if history_index >= history.size() - 1:
		return

	history_index += 1

	_restore_graph_state(history[history_index])

func _register_node(node: EditorGraphNode) -> void:
	node.properties_changed.connect(_commit_history)
