extends RefCounted
class_name NetworkProtocol

# Здесь будут общие параметры протокола.

const VERSION := 1
const MAX_PLAYER_NAME_LENGTH := 24

# Каналы передачи данных.
enum Channel {
	CONTROL,
	PLAYER_STATE,
	WORLD,
}