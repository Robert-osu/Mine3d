extends RefCounted
class_name PacketTypes

# Этот файл будет содержать идентификаторы сообщений. Они нужны, чтобы все части игры одинаково понимали назначение сетевых операций.

enum Type {
	# Connection
	HELLO,
	WELCOME,
	REJECT,

	# Player
	PLAYER_LIST,
	PLAYER_JOINED,
	PLAYER_LEFT,
	PLAYER_STATE,

	# World
	BLOCK_DESTROYED,
	BLOCK_UPDATED,
}