extends "res://tests/test_harness.gd"
## Targeted production-physics checks, separate from the multi-seed long run.
const Pinball = preload("res://scripts/pinball_physics.gd")
const Channels = preload("res://scripts/multiplier_channels.gd")

func _fixture():
	var machine = Pinball.new()
	root.add_child(machine)
	machine.reset(20261017)
	machine.balls.resize(1)
	machine.pegs.clear()
	return machine

func run_suite() -> void:
	for energy in [2.0, 2048.0, 1048576.0]:
		var machine = _fixture()
		var ball: Dictionary = machine.balls[0]
		ball["value"] = energy
		ball["threshold"] = 10000000.0
		ball["t_birth"] = 10000000.0
		machine._update_radius(ball)
		ball["p"] = Vector2(240.0, 330.0)
		ball["v"] = Vector2(0.0, 1200.0)
		var deepest := 330.0
		for i in range(120):
			machine.step(1.0 / 120.0, float(i + 1) / 120.0)
			deepest = maxf(deepest, Vector2(ball["p"]).y)
		check(ball["value"] == energy and machine.output_events == 0 and machine.multiplier_events == 0 and deepest + float(ball["r"]) < 466.0 and float(ball["r"]) == machine.radius_min,
			"晚生小球E=%.0f惯性下冲后被真实气流托回" % energy,
			"初速1200游戏单位/模拟秒；仅清除柱子隔离气流行为，不设置弹药输出门禁",
			{"deepest_center_y": deepest, "mass": ball["mass"], "final_position": str(ball["p"]), "final_velocity": str(ball["v"])})
		machine.free()
	var large_machine = _fixture()
	var large: Dictionary = large_machine.balls[0]
	large["value"] = 16384.0
	large["threshold"] = 100.0
	large["t_birth"] = 100.0
	large_machine._update_radius(large)
	large["p"] = Vector2(240.0, 330.0)
	large["v"] = Vector2(0.0, 500.0)
	for i in range(60):
		large_machine.step(1.0 / 120.0, float(i + 1) / 120.0)
	check(Vector2(large["p"]).y - float(large["r"]) > 466.0 and Vector2(large["v"]).y > 0.0 and large_machine.output_events == 0,
		"成长大球依靠真实质量和惯性突破空气墙", "球半径36，中央通道保持开放，没有改写弹药或使用概率放行", {"radius": large["r"], "mass": large["mass"], "position": str(large["p"]), "velocity": str(large["v"])})
	large_machine.free()
	var bounded = _fixture()
	var bounded_ball: Dictionary = bounded.balls[0]
	var bounded_ok := true
	for energy in [2.0, 2048.0, 4294967296.0, 9007199254740991.0]:
		bounded_ball["value"] = energy
		bounded._update_radius(bounded_ball)
		bounded_ok = bounded_ok and is_finite(float(bounded_ball["mass"])) and float(bounded_ball["mass"]) >= bounded.radius_min * bounded.radius_min and float(bounded_ball["mass"]) <= bounded.radius_min * bounded.radius_min * 33.0 and float(bounded_ball["bounce"]) > 0.0
	check(bounded_ok, "精确整数上限附近物理质量和弹性仍有界", "最大2^53−1弹药只进入有界log机械因子，不直接转换为无限质量", {"maximum_mass": bounded_ball["mass"], "minimum_bounce": bounded_ball["bounce"]})
	bounded.free()
	_test_pair_impulses()
	_test_oversize_mouths()
	_test_released_during_confirmation()
	_test_default_corridors()
	_test_custom_layout_preserved()
	finish()

func _test_custom_layout_preserved() -> void:
	var machine = _fixture()
	machine.configure({"custom_pegs": [[98.0, 523.0, 6.0]], "disabled_preset_pegs": [0]})
	var preserved: bool = machine.custom_pegs.size() == 1 and machine.custom_pegs[0] == Vector3(98.0, 523.0, 6.0) and machine.disabled_preset_pegs.has(0) and machine.disabled_preset_pegs.has(3)
	machine.restore_preset_pegs()
	preserved = preserved and machine.custom_pegs.size() == 1 and machine.custom_pegs[0] == Vector3(98.0, 523.0, 6.0) and machine.disabled_preset_pegs.has(3) and not machine.disabled_preset_pegs.has(0)
	var restored_custom: Array = machine.custom_pegs.duplicate()
	var restored_disabled: Array = machine.disabled_preset_pegs.duplicate()
	machine.configure({"custom_pegs": [], "disabled_preset_pegs": []})
	preserved = preserved and machine.custom_pegs.is_empty() and machine.disabled_preset_pegs.is_empty() and machine.pegs.size() == 15
	check(preserved, "默认柱布局修正保留旧合法自定义位置", "旧合法自定义柱保持原位并隐藏重叠新预设；恢复不挤掉用户柱；明确加载空布局可完整还原15柱", {"preserved_custom_pegs": restored_custom, "disabled_before_clear": restored_disabled, "restored_preset_count": machine.pegs.size()})
	machine.free()

func _test_default_corridors() -> void:
	var geometry = _fixture()
	geometry._build_pegs()
	var minimum_wall_gap := INF
	var minimum_peg_gap := INF
	for index in range(geometry.pegs.size()):
		var peg: Vector3 = geometry.pegs[index]
		minimum_wall_gap = minf(minimum_wall_gap, minf(peg.x - peg.z - 16.0, 464.0 - peg.x - peg.z))
		for other_index in range(index + 1, geometry.pegs.size()):
			var other: Vector3 = geometry.pegs[other_index]
			minimum_peg_gap = minf(minimum_peg_gap, Vector2(peg.x, peg.y).distance_to(Vector2(other.x, other.y)) - peg.z - other.z)
	check(geometry.pegs.size() == 15 and minimum_wall_gap >= 76.0 and minimum_peg_gap >= 76.0,
		"默认15柱对最大球保留真实穿行净距", "柱壁和柱间净距至少76游戏单位，大于默认最大球直径72；不改自定义柱",
		{"pegs": geometry.pegs.size(), "minimum_wall_gap": minimum_wall_gap, "minimum_peg_gap": minimum_peg_gap})
	geometry.free()
	for side in ["left", "right"]:
		var machine = _fixture()
		machine._build_pegs()
		var ball: Dictionary = machine.balls[0]
		ball["value"] = 16384.0
		machine._update_radius(ball)
		ball["p"] = Vector2(16.0 + float(ball["r"]) + 0.2, 570.0) if side == "left" else Vector2(464.0 - float(ball["r"]) - 0.2, 550.0)
		ball["v"] = Vector2.ZERO
		var captured: Array[float] = []
		machine.weapon_output.connect(func(_team: int, _kind: int, energy: float) -> void: captured.append(energy))
		var initial_clearance: float = INF
		for peg in machine.pegs:
			initial_clearance = minf(initial_clearance, Vector2(ball["p"]).distance_to(Vector2(peg.x, peg.y)) - float(ball["r"]) - peg.z)
		for i in range(144):
			machine.step(1.0 / 120.0, float(i + 1) / 120.0)
			if machine.output_events > 0:
				break
		check(initial_clearance > 0.0 and captured == [16384.0] and machine.unstuck_events == 0,
			"最大球%s侧柱壁走廊真实下落且无需防卡" % side,
			"无初始重叠，从默认柱层上方静止释放，1.2模拟秒内靠重力完整输出原弹药",
			{"initial_clearance": initial_clearance, "output_energy": captured, "unstuck_events": machine.unstuck_events, "sim_seconds": machine.simulation_time})
		machine.free()

func _test_released_during_confirmation() -> void:
	var machine = _fixture()
	var ball: Dictionary = machine.balls[0]
	ball["value"] = 16384.0
	machine._update_radius(ball)
	ball["p"] = Vector2(240.0, 240.0)
	ball["v"] = Vector2.ZERO
	machine.simulation_time = 0.0
	machine._reset_motion_watch(ball)
	for i in range(34):
		machine.simulation_time = float(i + 1) * 0.1
		if i == 33:
			# The ball has just fallen off its support before confirmation.
			# Its old 3-second extent remains small, but it now moves normally.
			ball["v"] = Vector2(0.0, 82.0)
			ball["p"] = Vector2(240.0, 248.2)
		machine._watch_motion(ball)
	check(machine.unstuck_events == 0 and ball["value"] == 16384.0 and Vector2(ball["p"]).y > 240.0,
		"静止确认期末已恢复运动不误重发", "3.3秒受阻后以82游戏单位/模拟秒恢复下落；旧短窗口包围盒仍小，必须由即时速度取消still判定", {"unstuck_events": machine.unstuck_events, "velocity": str(ball["v"]), "position": str(ball["p"])})
	machine.free()

func _test_oversize_mouths() -> void:
	for channel in [0, 1, 2, 4, 5, 6]:
		var machine = _fixture()
		machine.air.configure({"air_force": 0.0})
		var ball: Dictionary = machine.balls[0]
		var bounds: Vector2 = machine.channels.clear_bounds(channel)
		var radius: float = (bounds.y - bounds.x) * 0.5 + 0.5
		ball["r"] = radius
		ball["mass"] = radius * radius
		ball["p"] = Vector2((bounds.x + bounds.y) * 0.5, Channels.MOUTH_Y - radius - 8.0)
		ball["v"] = Vector2(0.0, 300.0)
		var observed: Dictionary = {"target_triggered": false}
		machine.trigger_log.connect(func(event: Dictionary) -> void:
			if event.get("type", "") == "multiplier" and int(event.get("channel", -1)) == channel:
				observed["target_triggered"] = true
		)
		for i in range(120):
			machine.step(1.0 / 120.0, float(i + 1) / 120.0)
			# Stop on a legitimate other slot/output: it creates a different ball
			# size, and must not be mistaken for the original oversize fixture.
			if machine.multiplier_events > 0 or machine.output_events > 0:
				break
		check(not bool(observed["target_triggered"]) and machine.contact_events > 0,
			"倍率槽%d实际超宽圆被入口实体拒绝" % channel,
			"直径比净宽大1游戏单位；经正式积分/实体接触，非直接调用capture参考",
			{"diameter": radius * 2.0, "clear_width": bounds.y - bounds.x, "physical_contacts": machine.contact_events, "target_triggered": observed["target_triggered"]})
		machine.free()

func _test_pair_impulses() -> void:
	var machine = _fixture()
	var second: Dictionary = machine.balls[0].duplicate(true)
	second["id"] = 1
	second["team"] = 1
	machine.balls.append(second)
	var correct := true
	var max_momentum_error := 0.0
	var max_kinetic_ratio := 0.0
	for energy in [2.0, 32.0, 1024.0, 65536.0]:
		var a: Dictionary = machine.balls[0]
		var b: Dictionary = machine.balls[1]
		a["value"] = energy
		b["value"] = 2.0
		machine._update_radius(a)
		machine._update_radius(b)
		for side_velocity in [-200.0, 0.0, 150.0]:
			b["team"] = 0 if side_velocity < 0.0 else 1
			a["p"] = Vector2(200.0, 200.0)
			b["p"] = Vector2(200.0 + float(a["r"]) + float(b["r"]) - 0.5, 200.0)
			a["v"] = Vector2(300.0, side_velocity)
			b["v"] = Vector2(-100.0, -side_velocity)
			var ma: float = a["mass"]
			var mb: float = b["mass"]
			var before_p: Vector2 = Vector2(a["v"]) * ma + Vector2(b["v"]) * mb
			var before_ke: float = ma * Vector2(a["v"]).length_squared() + mb * Vector2(b["v"]).length_squared()
			machine._ball_contacts()
			var after_p: Vector2 = Vector2(a["v"]) * ma + Vector2(b["v"]) * mb
			var after_ke: float = ma * Vector2(a["v"]).length_squared() + mb * Vector2(b["v"]).length_squared()
			var momentum_error: float = before_p.distance_to(after_p) / maxf(1.0, before_p.length())
			max_momentum_error = maxf(max_momentum_error, momentum_error)
			max_kinetic_ratio = maxf(max_kinetic_ratio, after_ke / before_ke)
			correct = correct and momentum_error < 0.00001 and after_ke <= before_ke * 1.00001 and a["value"] == energy and b["value"] == 2.0
	check(correct, "左侧同/异色球碰撞保持动量且不凭空增加动能", "12组阵营/质量差/切向速度组合；弹药不消耗，软化恢复系数只耗散动能", {"maximum_relative_momentum_error": max_momentum_error, "maximum_kinetic_ratio": max_kinetic_ratio})
	machine.free()
