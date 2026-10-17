extends "res://tests/test_harness.gd"
const DirectGPUWorld = preload("res://scripts/gpu_world.gd")
func run_suite() -> void:
	var config := GameSettings.validate({"gravity":20.0,"friction":1.0,"radius_min":12.0,"fixed_dt":0.017,"time_scale":0.3})
	var machine := PinballPhysics.new()
	machine.configure(config)
	check(machine.gravity == config.gravity and machine.friction == config.friction and machine.radius_min == config.radius_min and machine.air.reference_radius == machine.radius_min, "参数UI可接受范围与实际物理一致", "低重力/大摩擦/最小球半径都按同一边界验证，不在物理层静默改为另一数值", {"gravity":config.gravity,"friction":config.friction,"radius_min":config.radius_min})
	check(config.fixed_dt == 1.0 / 120.0 and config.time_scale == 0.25, "离散时步与速度配置不产生显示错位", "手改存档中的非菜单数值安全回到明确默认值")
	var not_finite := GameSettings.validate({"gravity":NAN,"growth_target":INF})
	check(is_finite(not_finite.gravity) and is_finite(not_finite.growth_target), "配置拒绝NaN和无穷", "非法数值不会进入物理或GPU参数")
	var exact := GameSettings.validate({"precision_mode":"exact","packet_energy":4096})
	check(exact.packet_energy == 1, "精确发射模式的包能量为一", "存量包的混合标识由独立实际GPU测试验证")
	var legacy := GameSettings.validate({"gun_end":1400.0,"storm_ring_particles":96,"friendly_particle_collisions":false})
	check(legacy.gun_rate == 1200.0 and legacy.gun_start == legacy.gun_end and legacy.storm_ring_particles == 360 and not legacy.friendly_particle_collisions, "旧配置迁移到固定射速与360颗风暴", "旧默认射速与96颗环更新，保留用户关闭友方碰撞的选择")
	var custom_legacy := GameSettings.validate({"gun_rate_end":777.0,"gun_start":25.0,"storm_ring_particles":999})
	check(custom_legacy.gun_rate == 777.0 and custom_legacy.gun_start == 777.0 and custom_legacy.gun_end == 777.0 and custom_legacy.storm_ring_particles == 360, "旧自定义射速迁移为恒定值", "不再保留时间渐增射速；每圈360是固定规则")
	var bounded := GameSettings.validate({"growth_curve_time":0.0,"gun_target_switch_cd":99.0,"sniper_split_angle":90.0,"friendly_particle_collisions":"false","gun_rate":0.0})
	check(bounded.growth_curve_time == 1.0 and bounded.gun_target_switch_cd == 2.0 and bounded.sniper_split_angle == 30.0 and bounded.friendly_particle_collisions and bounded.gun_rate == 0.0, "新参数有界且保留明确调试停火", "非法碰撞布尔值不会静默关物理；0射速是显式调试选项")
	var growth_nonfinite := GameSettings.validate({"growth_curve_time":NAN,"gun_target_switch_cd":INF})
	check(growth_nonfinite.growth_curve_time == 1200.0 and growth_nonfinite.gun_target_switch_cd == 0.5, "增长缓和与索敌冷却拒绝非有限值")
	check(GameSettings.defaults().gun_target_switch_cd == 0.5 and GameSettings.validate({}).gun_target_switch_cd == 0.5 and GameSettings.validate({"gun_target_switch_cd":0.08}).gun_target_switch_cd == 0.08 and GameSettings.validate({"gun_target_switch_cd":0.0}).gun_target_switch_cd == 0.0, "目标切换默认0.5模拟秒并保留显式自定义", "缺失字段使用新默认，不把合法旧0.08或自定义0静默覆盖")
	check(GameSettings.defaults().gun_discharge_duration == 10.0 and GameSettings.validate({"gun_duration":2.0}).gun_discharge_duration == 10.0 and "gun_discharge_duration" in GameSettings.LIVE_KEYS, "机枪发完时长默认10模拟秒且独立于旧射速增长字段", "新时长即时发送，下次真实补弹锁定；旧gun_duration不能被误当作补弹发完时长")
	var removed_cost := GameSettings.validate({"particle_cost_delay":1.0,"particle_cost_growth":999.0})
	check(not removed_cost.has("particle_cost_delay") and not removed_cost.has("particle_cost_growth") and not "particle_cost_delay" in GameSettings.LIVE_KEYS and not "particle_cost_growth" in GameSettings.LIVE_KEYS, "删除的进程发射成本不进入有效配置或即时更新", "旧存档字段不能恢复已删除的发射成本机制；保留高能粒子的整数能量")
	var direct_world := DirectGPUWorld.new()
	for direct_case: Dictionary in [
		{"name":"partial空配置","config":{},"expected":0.5},
		{"name":"显式旧0.08","config":{"gun_target_switch_cd":0.08},"expected":0.08},
		{"name":"显式0","config":{"gun_target_switch_cd":0.0},"expected":0.0},
		{"name":"显式0.35","config":{"gun_target_switch_cd":0.35},"expected":0.35},
		{"name":"NaN","config":{"gun_target_switch_cd":NAN},"expected":0.5},
		{"name":"无穷","config":{"gun_target_switch_cd":INF},"expected":0.5},
		{"name":"超出上限","config":{"gun_target_switch_cd":4.0},"expected":2.0},
		{"name":"负值","config":{"gun_target_switch_cd":-1.0},"expected":0.0},
		{"name":"非法类型","config":{"gun_target_switch_cd":"invalid"},"expected":0.5}]:
		direct_world.configure(direct_case.config)
		var gpu_params := direct_world._make_params(direct_world.settings)
		var effective_cd := float(direct_world.settings.get("gun_target_switch_cd", -1.0))
		var encoded_cd := gpu_params.decode_float(224)
		check(is_equal_approx(effective_cd, float(direct_case.expected)) and is_equal_approx(encoded_cd, float(direct_case.expected)), "直接GPUWorld配置与实际GPU参数一致 · " + str(direct_case.name), "无需创建RenderingDevice或运行GPU；验证真实configure与224字节参数编码，不以测试get默认值遮盖缺失字段", {"effective_cd":effective_cd,"encoded_cd":encoded_cd,"expected":direct_case.expected})
	for discharge_case: Dictionary in [
		{"name":"partial空配置","config":{},"expected":10.0},
		{"name":"显式2秒","config":{"gun_discharge_duration":2.0},"expected":2.0},
		{"name":"旧射速时长不复用","config":{"gun_duration":1.0},"expected":10.0},
		{"name":"NaN","config":{"gun_discharge_duration":NAN},"expected":10.0},
		{"name":"正无穷","config":{"gun_discharge_duration":INF},"expected":10.0},
		{"name":"负无穷","config":{"gun_discharge_duration":-INF},"expected":10.0},
		{"name":"超过上限","config":{"gun_discharge_duration":121.0},"expected":120.0},
		{"name":"零值","config":{"gun_discharge_duration":0.0},"expected":0.1},
		{"name":"负值","config":{"gun_discharge_duration":-1.0},"expected":0.1},
		{"name":"非法类型","config":{"gun_discharge_duration":"invalid"},"expected":10.0}]:
		var validated_discharge := GameSettings.validate(discharge_case.config)
		direct_world.configure(discharge_case.config)
		var discharge_params := direct_world._make_params(direct_world.settings)
		var effective_discharge := float(direct_world.settings.get("gun_discharge_duration", -1.0))
		var encoded_discharge := discharge_params.decode_float(236)
		check(is_equal_approx(validated_discharge.gun_discharge_duration, float(discharge_case.expected)) and is_equal_approx(effective_discharge, float(discharge_case.expected)) and is_equal_approx(encoded_discharge, float(discharge_case.expected)), "机枪发完时长设置与真实GPU参数一致 · " + str(discharge_case.name), "实际validate/configure与236字节编码均拒绝非法数值，不创建RenderingDevice", {"validated":validated_discharge.gun_discharge_duration,"effective":effective_discharge,"encoded":encoded_discharge,"expected":discharge_case.expected})
	direct_world.configure({"particle_cost_delay":1.0,"particle_cost_growth":999.0})
	direct_world.update_settings({"gun_discharge_duration":2.0,"particle_cost_delay":2.0,"particle_cost_growth":777.0})
	var updated_params := direct_world._make_params(direct_world.settings)
	check(direct_world.settings.gun_discharge_duration == 2.0 and updated_params.decode_float(236) == 2.0 and not direct_world.settings.has("particle_cost_delay") and not direct_world.settings.has("particle_cost_growth") and updated_params.decode_float(208) == 0.0 and updated_params.decode_float(212) == 0.0, "真实即时更新采用新时长且不能恢复旧成本", "未启动GPU的真实update_settings路径；旧成本参数槽清零，新时长按236字节写入")
	direct_world.free()
	var live := GameSettings.LIVE_KEYS
	check("growth_curve_time" in live and "gun_target_switch_cd" in live and "sniper_split_angle" in live and "friendly_particle_collisions" in live, "曲线冷却分裂角与友方碰撞开关均可即时更新")
	var retained := GameSettings.validate({"render_size":1536,"grid_size":1024,"friendly_particle_collisions":true,"disabled_preset_pegs":[14,0,14,-1],"custom_pegs":[Vector3(40,180,8)]})
	check(retained.render_size == 1536 and retained.grid_size == 1024 and retained.friendly_particle_collisions and retained.disabled_preset_pegs == [0,14] and retained.custom_pegs.size() == 1, "新配置保留高分辨率真实碰撞与固定柱编辑", "迁移不降画质、不丢布局")
	var config_existed := FileAccess.file_exists(GameSettings.CONFIG_PATH)
	var previous_config := FileAccess.get_file_as_bytes(GameSettings.CONFIG_PATH) if config_existed else PackedByteArray()
	var saved := GameSettings.save_file(GameSettings.validate({"growth_curve_time":900.0,"gun_target_switch_cd":0.35,"gun_discharge_duration":2.0,"sniper_split_angle":12.0,"friendly_particle_collisions":false,"disabled_preset_pegs":[2,7]}))
	var reloaded := GameSettings.load_file()
	check(saved == OK and reloaded.growth_curve_time == 900.0 and reloaded.gun_target_switch_cd == 0.35 and reloaded.sniper_split_angle == 12.0 and not reloaded.friendly_particle_collisions and reloaded.disabled_preset_pegs == [2,7], "配置持久化包含新参数与碰撞开关", "真实写入再读取用户配置，测试后恢复此前文件")
	check(saved == OK and reloaded.gun_discharge_duration == 2.0, "机枪补弹发完时长真实存档往返保留自定义值", "独立新字段持久化，不复用历史gun_duration")
	var old_file := ConfigFile.new()
	old_file.set_value("游戏", "gun_rate_end", 777.0)
	old_file.set_value("游戏", "storm_ring_particles", 96)
	old_file.set_value("游戏", "friendly_particle_collisions", false)
	old_file.set_value("游戏", "particle_cost_delay", 1.0)
	old_file.set_value("游戏", "particle_cost_growth", 999.0)
	var old_saved := old_file.save(GameSettings.CONFIG_PATH)
	var migrated_file := GameSettings.load_file()
	check(old_saved == OK and migrated_file.gun_rate == 777.0 and migrated_file.storm_ring_particles == 360 and not migrated_file.friendly_particle_collisions and migrated_file.growth_curve_time == 1200.0 and migrated_file.gun_target_switch_cd == 0.5, "真实旧存档读取会迁移旧别名并补齐新字段", "gun_rate_end别名不被默认gun_end遮盖；缺失目标CD采用0.5模拟秒")
	old_file.set_value("游戏", "gun_target_switch_cd", 0.08)
	var custom_old_saved := old_file.save(GameSettings.CONFIG_PATH)
	var custom_migrated_file := GameSettings.load_file()
	check(custom_old_saved == OK and custom_migrated_file.gun_target_switch_cd == 0.08, "真实旧存档保留用户显式目标切换CD", "旧默认与显式自定义无法可靠区分，因此保留所有合法存档值")
	var cost_clean_saved := GameSettings.save_file(custom_migrated_file)
	var cost_clean_file := ConfigFile.new()
	var cost_clean_loaded := cost_clean_file.load(GameSettings.CONFIG_PATH)
	check(cost_clean_saved == OK and cost_clean_loaded == OK and custom_migrated_file.gun_discharge_duration == 10.0 and not custom_migrated_file.has("particle_cost_delay") and not custom_migrated_file.has("particle_cost_growth") and not cost_clean_file.has_section_key("游戏", "particle_cost_delay") and not cost_clean_file.has_section_key("游戏", "particle_cost_growth"), "真实旧成本存档读取并重存后永久丢弃废弃字段", "缺失新时长使用10模拟秒；有效配置与磁盘文件均无旧成本，不能在重启时复活")
	if config_existed:
		var restore := FileAccess.open(GameSettings.CONFIG_PATH, FileAccess.WRITE)
		if restore:
			restore.store_buffer(previous_config)
			restore.close()
	else:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(GameSettings.CONFIG_PATH))
	var ui := GameUI.new()
	root.add_child(ui)
	ui.setup(GameSettings.defaults())
	machine.configure(GameSettings.defaults())
	var displayed_growth_matches := true
	for sim_time: float in [0.0,600.0,1200.0,2400.0,1000000000.0]:
		displayed_growth_matches = displayed_growth_matches and is_equal_approx(ui._growth_threshold(sim_time), machine.threshold_at(sim_time))
	check(displayed_growth_matches, "UI门槛备用显示与真实弛缓指数一致", "包含长期上限；不继续显示旧线性门槛")
	check(ui._inputs.has("growth_curve_time") and ui._inputs.has("gun_target_switch_cd") and is_equal_approx(ui._inputs.gun_target_switch_cd.value, 0.5) and ui._inputs.has("sniper_split_angle") and not ui._inputs.has("storm_ring_particles"), "设置面板暴露有效新参数且不显示废弃风暴数量开关", "目标切换CD控件默认0.5模拟秒，保持即时更新")
	var discharge_input: SpinBox = ui._inputs.get("gun_discharge_duration")
	check(discharge_input != null and discharge_input.value == 10.0 and is_equal_approx(discharge_input.min_value, 0.1) and discharge_input.max_value == 120.0 and discharge_input.get_parent().get_child(0).text == "机枪补弹后发完时长" and discharge_input.get_parent().get_child(0).tooltip_text.contains("下次真实补弹") and discharge_input.get_parent().get_child(2).text == "模拟秒" and discharge_input.tooltip_text.contains("不重置射击相位或瞄准") and discharge_input.tooltip_text.contains("余数全装进尾发") and ui._inputs.gun_rate.tooltip_text.contains("设为0立即调试停火") and not ui._inputs.has("particle_cost_delay") and not ui._inputs.has("particle_cost_growth"), "实际参数面板使用10模拟秒发完时长并删除旧成本控件", "核真实SpinBox边界、中文标签、模拟秒、下次补弹锁定及0立即停火提示，不读取源码猜测UI")
	ui._change("gun_discharge_duration", 2.0)
	check(ui._config.gun_discharge_duration == 2.0 and discharge_input.value == 2.0, "实际UI修改补弹时长同步有效配置与控件")
	ui.update_state({"sim_time":99999.0,"stats":{"active_packet_energy":12345,"current_particle_cost":999999}})
	var energy_diagnostic: Variant = JSON.parse_string(ui._diagnostic_text)
	check(energy_diagnostic is Dictionary and energy_diagnostic.get("particle_model") == "weighted_integer_energy" and int(energy_diagnostic.get("active_particle_energy", -1)) == 12345 and not ui._diagnostic_text.contains("cost") and ui._status.text.contains("粒子实际能量") and ui._ball_details.text.contains("高能权重"), "实际UI诊断仅报告遥测粒子能量而不恢复进程成本", "直接update_state读取实际active_packet_energy，忽略旧current_particle_cost遥测，JSON不含成本字段")
	ui._change("friendly_particle_collisions", false)
	check(not ui._config.friendly_particle_collisions and not ui._inputs.friendly_particle_collisions.button_pressed, "友方碰撞关闭同步到UI与配置")
	ui._change("friendly_particle_collisions", true)
	check(ui._config.friendly_particle_collisions and ui._inputs.friendly_particle_collisions.button_pressed, "友方碰撞重新开启不会丢失开关状态")
	var large_team: Dictionary = {"alive":true,"shield":9007199254740993,"gun":9007199254740995}
	ui.update_state({"stats":{"teams":[large_team,large_team,large_team,large_team]}})
	check(ui._team_labels[0].text.contains("护盾 9,007,199,254,740,993") and ui._team_labels[0].text.contains("机枪 9,007,199,254,740,995") and ui._team_labels[0].tooltip_text.contains("9,007,199,254,740,993") and ui._team_labels[0].tooltip_text.contains("9,007,199,254,740,995"), "真实面板展示超过2^53库存仍保留整数低位", "直接调用实际update_state检查完整数值及悬停提示，避免先转float64造成尾数丢失")
	var team: Dictionary = {"alive":false,"shield":0,"gun":0}
	ui.update_state({"stats":{"teams":[team,team,team,team]}})
	ui.update_state({"stats":{}})
	check(ui._team_labels[0].text.contains("等待GPU状态验证"), "重开初始化不显示上局淘汰与库存", "没有新GPU遥测时明确等待验证，不能把旧状态当开局状态")
	ui.queue_free()
	machine.free()
	finish()
