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
	direct_world.free()
	var live := GameSettings.LIVE_KEYS
	check("growth_curve_time" in live and "gun_target_switch_cd" in live and "sniper_split_angle" in live and "friendly_particle_collisions" in live, "曲线冷却分裂角与友方碰撞开关均可即时更新")
	var retained := GameSettings.validate({"render_size":1536,"grid_size":1024,"friendly_particle_collisions":true,"disabled_preset_pegs":[14,0,14,-1],"custom_pegs":[Vector3(40,180,8)]})
	check(retained.render_size == 1536 and retained.grid_size == 1024 and retained.friendly_particle_collisions and retained.disabled_preset_pegs == [0,14] and retained.custom_pegs.size() == 1, "新配置保留高分辨率真实碰撞与固定柱编辑", "迁移不降画质、不丢布局")
	var config_existed := FileAccess.file_exists(GameSettings.CONFIG_PATH)
	var previous_config := FileAccess.get_file_as_bytes(GameSettings.CONFIG_PATH) if config_existed else PackedByteArray()
	var saved := GameSettings.save_file(GameSettings.validate({"growth_curve_time":900.0,"gun_target_switch_cd":0.35,"sniper_split_angle":12.0,"friendly_particle_collisions":false,"disabled_preset_pegs":[2,7]}))
	var reloaded := GameSettings.load_file()
	check(saved == OK and reloaded.growth_curve_time == 900.0 and reloaded.gun_target_switch_cd == 0.35 and reloaded.sniper_split_angle == 12.0 and not reloaded.friendly_particle_collisions and reloaded.disabled_preset_pegs == [2,7], "配置持久化包含新参数与碰撞开关", "真实写入再读取用户配置，测试后恢复此前文件")
	var old_file := ConfigFile.new()
	old_file.set_value("游戏", "gun_rate_end", 777.0)
	old_file.set_value("游戏", "storm_ring_particles", 96)
	old_file.set_value("游戏", "friendly_particle_collisions", false)
	var old_saved := old_file.save(GameSettings.CONFIG_PATH)
	var migrated_file := GameSettings.load_file()
	check(old_saved == OK and migrated_file.gun_rate == 777.0 and migrated_file.storm_ring_particles == 360 and not migrated_file.friendly_particle_collisions and migrated_file.growth_curve_time == 1200.0 and migrated_file.gun_target_switch_cd == 0.5, "真实旧存档读取会迁移旧别名并补齐新字段", "gun_rate_end别名不被默认gun_end遮盖；缺失目标CD采用0.5模拟秒")
	old_file.set_value("游戏", "gun_target_switch_cd", 0.08)
	var custom_old_saved := old_file.save(GameSettings.CONFIG_PATH)
	var custom_migrated_file := GameSettings.load_file()
	check(custom_old_saved == OK and custom_migrated_file.gun_target_switch_cd == 0.08, "真实旧存档保留用户显式目标切换CD", "旧默认与显式自定义无法可靠区分，因此保留所有合法存档值")
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
