class_name GameSettings
extends RefCounted
## 配置只写入 user://，不改工程或锁定资源。validate 总是返回可安全使用的完整配置。

const CONFIG_PATH := "user://chromatic_wars.cfg"
const TIME_SCALE_DEFAULT_REVISION := 1
const CAPACITIES := [10000, 50000, 100000, 300000, 1000000]
const LIVE_KEYS := ["gravity", "restitution", "friction", "air_force", "air_height", "air_width", "air_exponent", "growth_target", "growth_duration", "growth_curve_time", "radius_min", "radius_max", "radius_k", "gun_rate", "gun_rotation_speed", "gun_target_switch_cd", "gun_discharge_duration", "storm_ring_interval", "ball_speed", "ball_min_speed", "sniper_speed", "sniper_charge_time", "sniper_split_angle", "shield_scale", "shield_max_diameter", "emergency_cd", "particle_radius", "friendly_particle_collisions", "trail_length", "visual_density", "fps_limit", "time_scale", "channel_width_8", "channel_width_4", "channel_width_2", "custom_pegs", "disabled_preset_pegs", "peg_radius"]

static func defaults() -> Dictionary:
	return {
		"gravity": 820.0, "restitution": 1.0, "friction": 0.0,
		"air_force": 2950.0, "air_height": 180.0, "air_width": 96.0, "air_exponent": 2.8,
		"growth_target": 1000000.0, "growth_duration": 1200.0, "growth_curve_time": 1200.0,
		"radius_min": 4.2, "radius_max": 36.0, "radius_k": 3.0,
		"intro_shield": 1000000.0, "intro_gun": 1000000.0,
		"gun_rate": 1200.0, "gun_rotation_speed": 1.7, "gun_target_switch_cd": 0.5, "gun_discharge_duration": 10.0,
		# gun_duration只保留旧射速增长存档兼容，不用于新的补弹发完时长。
		"gun_start": 1200.0, "gun_end": 1200.0, "gun_duration": 1200.0,
		"storm_ring_particles": 360, "storm_ring_interval": 0.10,
		"ball_speed": 92.0, "ball_min_speed": 40.0, "sniper_speed": 620.0, "sniper_charge_time": 0.65, "sniper_split_angle": 8.0,
		"shield_scale": 1.0, "shield_max_diameter": 389.12,
		"channel_width_8": 37.0, "channel_width_4": 47.0, "channel_width_2": 67.0,
		"custom_pegs": [], "disabled_preset_pegs": [], "peg_radius": 6.0,
		"core_0_x": 256.0, "core_0_y": 256.0,
		"core_1_x": 768.0, "core_1_y": 256.0,
		"core_2_x": 256.0, "core_2_y": 768.0,
		"core_3_x": 768.0, "core_3_y": 768.0,
		"emergency_cd": 180.0, "particle_capacity": 10000,
		"grid_size": 512, "render_size": 768, "particle_radius": 1.2,
		"friendly_particle_collisions": true,
		"trail_length": 0.12, "visual_density": 1.0,
		"packet_energy": 1, "precision_mode": "exact", "fixed_dt": 1.0 / 120.0,
		"fps_limit": 60, "time_scale": 1.0, "seed": 20261016,
	}

static func load_file() -> Dictionary:
	var file := ConfigFile.new()
	if file.load(CONFIG_PATH) != OK:
		return defaults()
	var config := defaults()
	for key: String in config:
		config[key] = file.get_value("游戏", key, config[key])
	# 旧版起止射速迁移为恒定射速；保留用户自定义的末端值。
	if not file.has_section_key("游戏", "gun_rate"):
		config.erase("gun_rate")
		if not file.has_section_key("游戏", "gun_end") and file.has_section_key("游戏", "gun_rate_end"):
			config["gun_end"] = file.get_value("游戏", "gun_rate_end")
	# 独立元数据只迁移一次旧默认0.25。新版用户主动保存的慢速必须在以后加载时保留。
	var stored_revision: Variant = file.get_value("metadata", "time_scale_default_revision", 0)
	var revision := int(stored_revision) if stored_revision is int else 0
	var migrate_default_speed := revision < TIME_SCALE_DEFAULT_REVISION
	var saved_scale: Variant = file.get_value("游戏", "time_scale", null)
	if migrate_default_speed and (saved_scale is int or saved_scale is float) and is_finite(float(saved_scale)) and float(saved_scale) == 0.25:
		config["time_scale"] = 1.0
	var validated := validate(config)
	if migrate_default_speed:
		var save_error := save_file(validated)
		if save_error != OK:
			push_warning("默认1倍速已应用，但升级配置保存失败：" + error_string(save_error))
	return validated

static func save_file(config: Dictionary) -> Error:
	var file := ConfigFile.new()
	var validated := validate(config)
	for key: String in validated:
		file.set_value("游戏", key, validated[key])
	file.set_value("metadata", "time_scale_default_revision", TIME_SCALE_DEFAULT_REVISION)
	return file.save(CONFIG_PATH)

static func validate(config: Dictionary) -> Dictionary:
	# 仅重建当前受支持字段；旧存档已删除的进程发射成本不再读入，重存时也不会复活。
	var result := defaults()
	var limits := {
		"gravity": [50.0, 2000.0], "restitution": [0.05, 1.0], "friction": [0.0, 0.3],
		"air_force": [0.0, 12000.0], "air_height": [40.0, 280.0], "air_width": [30.0, 98.0],
		"air_exponent": [0.5, 8.0], "growth_target": [100.0, 1000000000.0],
		"growth_duration": [1.0, 7200.0], "growth_curve_time": [1.0, 7200.0], "radius_min": [4.0, 9.0],
		"radius_max": [12.0, 40.0], "radius_k": [0.1, 30.0],
		"intro_shield": [0.0, 1000000000.0], "intro_gun": [0.0, 1000000000.0],
		"gun_rate": [0.0, 10000.0], "gun_rotation_speed": [0.1, 6.0], "gun_target_switch_cd": [0.0, 2.0], "gun_discharge_duration": [0.1, 120.0],
		"storm_ring_interval": [0.02, 2.0],
		"ball_speed": [10.0, 500.0], "ball_min_speed": [1.0, 500.0],
		"sniper_speed": [50.0, 2000.0], "sniper_charge_time": [0.0, 3.0], "sniper_split_angle": [0.0, 30.0],
		"shield_scale": [0.25, 3.0], "shield_max_diameter": [32.0, 768.0],
		"channel_width_8": [12.0, 100.0], "channel_width_4": [12.0, 100.0], "channel_width_2": [12.0, 100.0],
		"peg_radius": [3.0, 24.0],
		"core_0_x": [32.0, 992.0], "core_0_y": [32.0, 992.0],
		"core_1_x": [32.0, 992.0], "core_1_y": [32.0, 992.0],
		"core_2_x": [32.0, 992.0], "core_2_y": [32.0, 992.0],
		"core_3_x": [32.0, 992.0], "core_3_y": [32.0, 992.0],
		"emergency_cd": [0.0, 3600.0], "particle_radius": [0.5, 3.0],
		"trail_length": [0.0, 0.9], "visual_density": [0.05, 1.0],
		"fixed_dt": [1.0 / 480.0, 1.0 / 30.0], "time_scale": [0.25, 4.0],
	}
	for key: String in limits:
		var value: Variant = config.get(key, result[key])
		if key == "gun_rate" and not config.has(key):
			value = config.get("gun_end", config.get("gun_rate_end", result[key]))
			if (value is int or value is float) and is_equal_approx(float(value), 1400.0):
				value = result[key]
		if (value is int or value is float) and is_finite(float(value)):
			result[key] = clampf(float(value), float(limits[key][0]), float(limits[key][1]))
	var friendly_collisions: Variant = config.get("friendly_particle_collisions", true)
	if friendly_collisions is bool:
		result["friendly_particle_collisions"] = friendly_collisions
	# 只为旧工具保留别名，机枪射速不再随时间变化。
	result["gun_start"] = result["gun_rate"]
	result["gun_end"] = result["gun_rate"]
	result["ball_min_speed"] = minf(float(result["ball_min_speed"]), float(result["ball_speed"]))
	result["radius_max"] = maxf(float(result["radius_min"]), float(result["radius_max"]))
	# 左右各一组通道共用可用宽度；为中央空气通路与实体隔墙留足空间。
	var channel_total := float(result["channel_width_8"]) + float(result["channel_width_4"]) + float(result["channel_width_2"])
	if channel_total > 158.0:
		var width_factor := (158.0 - 36.0) / (channel_total - 36.0)
		result["channel_width_8"] = floorf((12.0 + (float(result["channel_width_8"]) - 12.0) * width_factor) * 1000.0) / 1000.0
		result["channel_width_4"] = floorf((12.0 + (float(result["channel_width_4"]) - 12.0) * width_factor) * 1000.0) / 1000.0
		result["channel_width_2"] = 158.0 - float(result["channel_width_8"]) - float(result["channel_width_4"])
	var custom_pegs: Array[Vector3] = []
	var supplied_pegs: Variant = config.get("custom_pegs", [])
	if supplied_pegs is Array:
		for entry: Variant in supplied_pegs:
			if entry is Vector3 and is_finite(entry.x) and is_finite(entry.y) and is_finite(entry.z):
				var peg_radius := clampf(entry.z, 3.0, 24.0)
				custom_pegs.append(Vector3(clampf(entry.x, 16.0 + peg_radius, 464.0 - peg_radius), clampf(entry.y, 130.0 + peg_radius, 750.0 - peg_radius), peg_radius))
				if custom_pegs.size() == 64:
					break
	result["custom_pegs"] = custom_pegs
	var disabled_preset_pegs: Array[int] = []
	var supplied_disabled: Variant = config.get("disabled_preset_pegs", [])
	if supplied_disabled is Array:
		for entry: Variant in supplied_disabled:
			if entry is int and entry >= 0 and entry < 15 and not entry in disabled_preset_pegs:
				disabled_preset_pegs.append(entry)
	disabled_preset_pegs.sort()
	result["disabled_preset_pegs"] = disabled_preset_pegs
	for key: String in ["particle_capacity", "grid_size", "render_size", "fps_limit", "seed"]:
		var value: Variant = config.get(key, result[key])
		if value is int or value is float:
			if is_finite(float(value)):
				result[key] = int(value)
	if not result["particle_capacity"] in CAPACITIES:
		result["particle_capacity"] = 10000
	if not result["grid_size"] in [256, 512, 768, 1024]:
		result["grid_size"] = 512
	if not result["render_size"] in [512, 768, 1024, 1536]:
		result["render_size"] = 768
	# 每圈固定 360 颗、最多 3 圈是战斗规则；旧配置的 96 颗等值统一迁移。
	result["storm_ring_particles"] = 360
	result["fps_limit"] = clampi(int(result["fps_limit"]), 0, 240)
	result["seed"] = clampi(int(result["seed"]), 0, 2147483647)
	# 旧配置的近似粒子包开关不再改变整数结算；实际高能权重保存在各粒子自身。
	result["precision_mode"] = "exact"
	result["packet_energy"] = 1
	if not float(result["fixed_dt"]) in [1.0 / 60.0, 1.0 / 120.0, 1.0 / 240.0]:
		result["fixed_dt"] = 1.0 / 120.0
	if not float(result["time_scale"]) in [0.25, 0.5, 1.0, 2.0, 4.0]:
		result["time_scale"] = 1.0
	return result
