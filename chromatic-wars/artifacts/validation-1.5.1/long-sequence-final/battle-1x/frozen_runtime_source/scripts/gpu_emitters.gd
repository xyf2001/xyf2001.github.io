class_name GPUEmitters
extends RefCounted
## CPU仅把真实左侧输出编码为少量32字节命令；发射、扣库存和积压均由GPU执行。
const COMMAND_STRIDE := 32
const MAX_ENERGY := 9223372036854775807

static func _energy_value(value: Variant) -> int:
	# 整数能量直接编码，不能先转float而丢掉2^53以上的低位。
	if typeof(value) == TYPE_INT:
		return maxi(0, int(value))
	var scalar := float(value)
	if not is_finite(scalar):
		return 0
	if scalar >= float(MAX_ENERGY):
		return MAX_ENERGY
	return int(maxf(0.0, scalar))

static func encode(command: Dictionary) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(COMMAND_STRIDE)
	var op := int(command.get("op", 0))
	result.encode_u32(0, op)
	result.encode_u32(4, int(command.get("team", 0)))
	var energy := _energy_value(command.get("energy", 0))
	result.encode_u32(8, energy & 0xffffffff)
	result.encode_u32(12, (energy >> 32) & 0xffffffff)
	if op == 10:
		var gun := _energy_value(command.get("gun", 0))
		result.encode_u32(16, gun & 0xffffffff)
		result.encode_u32(20, (gun >> 32) & 0xffffffff)
		result.encode_u32(24, int(command.get("state", 0)))
		result.encode_float(28, float(command.get("ready_time", 0.0)))
	elif op >= 11 and op <= 13:
		result.encode_float(16, float(command.get("x", 0.0)))
		result.encode_float(20, float(command.get("y", 0.0)))
		result.encode_float(24, float(command.get("vx", 0.0)))
		result.encode_float(28, float(command.get("vy", 0.0)))
	elif op == 17:
		result.encode_float(16, float(command.get("vx", 0.0)))
		result.encode_float(20, float(command.get("vy", 0.0)))
		result.encode_u32(24, maxi(0, int(command.get("count", 0))))
	elif op == 15:
		result.encode_u32(16, int(command.get("count", 1)))
	else:
		result.encode_u32(16, int(command.get("seed", 0)))
		result.encode_u32(20, int(command.get("nonce", 0)))
		result.encode_u32(24, 1 if bool(command.get("death", false)) else 0)
		if op >= 1 and op <= 5:
			result.encode_float(28, float(command.get("at_time", -1.0)))
	return result

