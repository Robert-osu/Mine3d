
extends RefCounted
class_name NodeDefinitions


const DEFINITIONS := {
    "Start": {
        "title": "Start",
        "category": "Flow",
        "inputs": [],
        "outputs": [
            {"name": "Exec", "type": "exec"}
        ],
        "properties": []
    },

    "Process": {
        "title": "Process",
        "category": "Flow",
        "inputs": [
            {"name": "Exec", "type": "exec"}
        ],
        "outputs": [
            {"name": "Exec", "type": "exec"}
        ],
        "properties": [
            {
                "name": "Operation",
                "type": "enum",
                "options": ["Add", "Subtract", "Multiply", "Divide"],
                "default": 0
            },
            {
                "name": "Value",
                "type": "float",
                "default": 1.0
            }
        ]
    },

    "Condition": {
        "title": "Condition",
        "category": "Flow",
        "inputs": [
            {"name": "Exec", "type": "exec"}
        ],
        "outputs": [
            {"name": "True", "type": "exec"},
            {"name": "False", "type": "exec"}
        ],
        "properties": [
            {
                "name": "Expression",
                "type": "string",
                "default": "Value > 0"
            }
        ]
    },

    "End": {
        "title": "End",
        "category": "Flow",
        "inputs": [
            {"name": "Exec", "type": "exec"}
        ],
        "outputs": [],
        "properties": []
    }
}


static func get_definition(node_name: String) -> Dictionary:
    if not DEFINITIONS.has(node_name):
        return {}

    return DEFINITIONS[node_name].duplicate(true)


static func get_node_names() -> Array:
    return DEFINITIONS.keys()
