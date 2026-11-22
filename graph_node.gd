
extends GraphNode
class_name EditorGraphNode

signal properties_changed


var node_type: String = ""
var properties: Dictionary = {}


const PORT_COLORS := {
	"exec": Color.WHITE,
	"float": Color.DEEP_SKY_BLUE,
	"int": Color.CORNFLOWER_BLUE,
	"string": Color.ORANGE,
	"bool": Color.LIME_GREEN
}


func setup(type_name: String) -> void:
	node_type = type_name

	var definition := NodeDefinitions.get_definition(type_name)

	if definition.is_empty():
		push_error("Unknown node type: " + type_name)
		return

	title = definition.title

	for property in definition.properties:
		properties[property.name] = property.default

	_build_node(definition)



func update_properties() -> void:
	for child in get_children():
		for control in child.get_children():
			if control is SpinBox:
				control.value = properties.get(
					"Value",
					control.value
				)

			elif control is OptionButton:
				control.select(properties.get(
					"Operation",
					control.selected
				))

			elif control is LineEdit:
				control.text = properties.get(
					"Expression",
					control.text
				)


func _build_node(definition: Dictionary) -> void:
	var inputs: Array = definition.inputs
	var outputs: Array = definition.outputs
	var property_list: Array = definition.properties

	# Входы
	for port in inputs:
		var row := HBoxContainer.new()

		var label := Label.new()
		label.text = port.name

		row.add_child(label)
		add_child(row)

		_configure_slot(
			get_child_count() - 1,
			port.type,
			"",
			true,
			false
		)

	# Свойства
	for property in property_list:
		var row := HBoxContainer.new()

		var label := Label.new()
		label.text = property.name

		row.add_child(label)

		var control: Control

		match property.type:
			"float":
				var spin := SpinBox.new()
				spin.min_value = -100000
				spin.max_value = 100000
				spin.step = 0.1
				spin.value = property.default

				spin.value_changed.connect(
					_on_float_changed.bind(property.name)
				)

				control = spin

			"enum":
				var option := OptionButton.new()

				for item in property.options:
					option.add_item(item)

				option.select(property.default)

				option.item_selected.connect(
					_on_enum_changed.bind(property.name)
				)

				control = option

			"string":
				var line := LineEdit.new()
				line.text = property.default

				line.text_changed.connect(
					_on_string_changed.bind(property.name)
				)

				control = line

		if control != null:
			row.add_child(control)

		add_child(row)

	# Выходы
	for port in outputs:
		var row := HBoxContainer.new()
		row.alignment = BoxContainer.ALIGNMENT_END

		var label := Label.new()
		label.text = port.name

		row.add_child(label)
		add_child(row)

		_configure_slot(
			get_child_count() - 1,
			"",
			port.type,
			false,
			true
		)


func _configure_slot(
	index: int,
	input_type: String,
	output_type: String,
	has_input: bool,
	has_output: bool
) -> void:

	var input_color: Color = PORT_COLORS.get(
		input_type,
		Color.WHITE
	)

	var output_color: Color = PORT_COLORS.get(
		output_type,
		Color.WHITE
	)

	set_slot(
		index,
		has_input,
		_get_type_id(input_type),
		input_color,
		has_output,
		_get_type_id(output_type),
		output_color
	)


func _get_type_id(type_name: String) -> int:
	match type_name:
		"exec":
			return 0
		"float":
			return 1
		"int":
			return 2
		"string":
			return 3
		"bool":
			return 4
		_:
			return 0


func _on_float_changed(
	value: float,
	property_name: String
) -> void:
	properties[property_name] = value
	properties_changed.emit()


func _on_enum_changed(
	index: int,
	property_name: String
) -> void:
	properties[property_name] = index
	properties_changed.emit()


func _on_string_changed(
	value: String,
	property_name: String
) -> void:
	properties[property_name] = value
	properties_changed.emit()
