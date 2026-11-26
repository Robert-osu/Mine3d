extends RefCounted
class_name NetworkProtocol

# Здесь будут общие параметры протокола.

const VERSION := 2
const WORLD_SYNC_SECTIONS_PER_BATCH := 8
const MAX_PLAYER_NAME_LENGTH := 24

enum Buttons {
	NONE = 0,
	JUMP = 1 << 0,
	SPRINT = 1 << 1,
}

# Режимы доставки.
const RELIABLE := "reliable"
const UNRELIABLE := "unreliable"
const UNRELIABLE_ORDERED := "unreliable_ordered"

# Пока используем стандартный канал.
const DEFAULT_CHANNEL := 0