extends "res://tests/test_harness.gd"
## 左侧测试使用正式物理模块；只有输入夹具由测试设置。
const Pinball = preload("res://scripts/pinball_physics.gd")
const Channels = preload("res://scripts/multiplier_channels.gd")
const Air = preload("res://scripts/air_curtain.gd")
const Conveyor = preload("res://scripts/weapon_conveyor.gd")
var actual_bottom_logs: int = 0
var birth_errors: int = 0
var output_energy: float = 0.0
var maximum_energy: float = 2.0
var current_run_peak_energy: float = 2.0
var unstuck_reasons: Dictionary = {}

func run_suite() -> void:
	print("环境：Godot %s；左侧CPU规则测试；右侧GPU不在本套件范围" % Engine.get_version_info()["string"])
	_test_initial_and_threshold()
	_test_channels()
	_test_air()
	_test_conveyor()
	_test_rescue()
	_test_physical_contacts()
	_test_motion_watch()
	await _test_long_run()
	finish()

func _new_pinball():
	var pinball = Pinball.new()
	root.add_child(pinball)
	pinball.reset(int(options.get("seed", "20261016")))
	return pinball

func _test_initial_and_threshold() -> void:
	var pinball = _new_pinball()
	var initial_ok: bool = pinball.balls.size() == 16
	var counts := [0, 0, 0, 0]
	var ids: Dictionary = {}
	for ball in pinball.balls:
		counts[int(ball["team"])] += 1
		ids[ball["id"]] = true
		initial_ok = initial_ok and float(ball["value"]) == 2.0 and is_equal_approx(float(ball["r"]), 4.2)
		initial_ok = initial_ok and float(ball["threshold"]) == 100.0 and Vector2(ball["v"]).y < 0.0
	check(initial_ok and ids.size() == 16 and counts == [4, 4, 4, 4], "开局16球与四队对等", "每队4球，数值2、最小物理半径、顶部向上发射", {"team_counts": counts})
	var curve_ok := true
	var max_error := 0.0
	var previous_rate := INF
	for index in range(1001):
		var t: float = float(index) * 1.2
		var relative_progress: float = (sqrt(1.0 + t / 1200.0) - 1.0) / (sqrt(2.0) - 1.0)
		var reference: float = 100.0 * pow(10000.0, relative_progress)
		var error: float = absf(pinball.threshold_at(t) - reference)
		max_error = maxf(max_error, error)
		var rate: float = log(pinball.threshold_at(t + 0.5) / pinball.threshold_at(t)) / 0.5
		curve_ok = curve_ok and error < 0.001 and rate <= previous_rate and rate > 0.0
		previous_rate = rate
	curve_ok = curve_ok and is_equal_approx(pinball.threshold_at(-10.0), 100.0) and is_equal_approx(pinball.threshold_at(1200.0), 1000000.0) and pinball.threshold_at(1800.0) > 1000000.0
	check(curve_ok, "体积门槛指数增长且相对增长率下降", "1001时间点以幂式参考对照log域实现；起点100、1200模拟秒1e6，随后继续增长", {"max_error": max_error, "threshold_600": pinball.threshold_at(600.0), "threshold_1800": pinball.threshold_at(1800.0)})
	var first: Dictionary = pinball.balls[0]
	first["value"] = 400.0
	first["p"] = Vector2(240.0, 210.0)
	first["v"] = Vector2.ZERO
	pinball._update_radius(first)
	var locked_radius: float = first["r"]
	pinball.step(1.0 / 120.0, 600.0)
	check(float(first["threshold"]) == 100.0 and is_equal_approx(float(first["r"]), locked_radius), "旧球锁定出生门槛", "模拟时间推进至600秒，原球物理半径和T_birth保持不变", {"radius": first["r"], "birth_threshold": first["threshold"]})
	first["p"] = Vector2(230.0, 780.0)
	first["v"] = Vector2(0.0, 100.0)
	pinball.step(1.0 / 120.0, 600.0 + 1.0 / 120.0)
	check(float(first["value"]) == 2.0 and is_equal_approx(float(first["threshold"]), pinball.threshold_at(float(first["birth_time"]))) and is_equal_approx(float(first["r"]), pinball.radius_min), "完整输出后按当前门槛重生", "数值重置2，门槛采用实际输出子步时间，半径回最小", {"value": first["value"], "birth_threshold": first["threshold"], "radius": first["r"]})
	var minimum_large_ammo: float = pinball.radius_for(900000.0, 1000000.0)
	check(is_equal_approx(minimum_large_ammo, pinball.radius_min) and pinball.radius_for(400.0, 100.0) > pinball.radius_min, "后期高数值可保持小物理半径", "900000/1000000小于出生门槛；开局400/100已增大")
	pinball.free()

func _test_channels() -> void:
	var channels = Channels.new()
	var widths: Array = channels.snapshot()["clear_widths"]
	check(float(widths[0]) < float(widths[1]) and float(widths[1]) < float(widths[2]) and widths[0] == widths[6] and widths[1] == widths[5] and widths[2] == widths[4], "倍率实体入口镜像与净宽", "×8最窄、×4其次、×2最宽", {"clear_widths": widths})
	var captures_ok := true
	for channel in [0, 1, 2, 4, 5, 6]:
		var bounds: Vector2 = channels.clear_bounds(channel)
		var radius := 4.2
		var x: float = (bounds.x + bounds.y) * 0.5
		captures_ok = captures_ok and channels.capture(Vector2(x, channels.MOUTH_Y + radius - 0.01), radius) == -1
		captures_ok = captures_ok and channels.capture(Vector2(x, channels.MOUTH_Y + radius + 0.01), radius) == channel
		captures_ok = captures_ok and channels.capture(Vector2(x, channels.MOUTH_Y + 30.0), (bounds.y - bounds.x) * 0.5 + 0.01) == -1
		channels.register(channel)
	captures_ok = captures_ok and channels.capture(Vector2(240.0, 390.0), 4.2) == -1
	check(captures_ok and channels.counts == [1, 1, 1, 1, 1, 1], "六倍率口完整圆即时触发与超宽拒绝", "逐口检查完整圆过入口才触发、超宽不能触发、中央不是倍率口，独立计数")

func _test_air() -> void:
	var air = Air.new()
	var small: Vector2 = air.acceleration(Vector2(220.0, 390.0), 4.2)
	var large: Vector2 = air.acceleration(Vector2(220.0, 390.0), 15.2)
	check(small.y + 820.0 < 0.0 and large.y + 820.0 > 0.0 and absf(small.y) > absf(large.y) * 10.0, "空气墙按真实半径区分上下推力", "同位置小球净加速度向上，大球净加速度向下", {"small_ay": small.y, "large_ay": large.y})
	check(air.acceleration(Vector2(100.0, 390.0), 4.2) == Vector2.ZERO and air.acceleration(Vector2(240.0, 500.0), 4.2) == Vector2.ZERO, "空气墙有真实空间范围", "倍率外侧与作用高度外没有气流力")
	var pinball = _new_pinball()
	pinball.balls.resize(1)
	var ball: Dictionary = pinball.balls[0]
	ball["p"] = Vector2(220.0, 410.0)
	ball["v"] = Vector2(0.0, 100.0)
	for index in range(30):
		pinball.step(1.0 / 120.0, float(index + 1) / 120.0)
	var physically_rising: bool = Vector2(ball["v"]).y < -100.0 and Vector2(ball["p"]).y < 410.0
	check(physically_rising, "小球在正式物理步中被推回上方", "非概率判定，实际积分与实体接触", {"position": str(ball["p"]), "velocity": str(ball["v"])})
	pinball.free()

func _test_conveyor() -> void:
	var conveyor = Conveyor.new()
	var matches := 0
	var coverage_ok := true
	var continuity_ok := true
	for index in range(120):
		conveyor.phase = fposmod(float(index) * 0.137919, 6.0)
		var x: float = Conveyor.LEFT + fposmod(float(index) * 53.7321 + 0.123, Conveyor.RIGHT - Conveyor.LEFT)
		# 独立几何参考：按绘制矩形覆盖x选择内容，避免直接照抄sample索引算法。
		var visible_kind := -1
		var visible_width := 0.0
		var previous_end: float = Conveyor.LEFT
		for cell in range(-2, 14):
			var raw_left: float = Conveyor.LEFT + (float(cell) - conveyor.phase) * Conveyor.CELL_WIDTH
			var left: float = maxf(Conveyor.LEFT, raw_left)
			var right: float = minf(Conveyor.RIGHT, raw_left + Conveyor.CELL_WIDTH)
			if right <= left:
				continue
			coverage_ok = coverage_ok and absf(left - previous_end) < 0.0001
			previous_end = right
			visible_width += right - left
			if x >= left and x < right:
				visible_kind = Conveyor.CONTENT[posmod(cell, 6)]
		coverage_ok = coverage_ok and absf(visible_width - (Conveyor.RIGHT - Conveyor.LEFT)) < 0.0001
		var hit: Dictionary = conveyor.register(x, index % 16, index % 4, float(index + 2))
		if visible_kind == int(hit["kind"]):
			matches += 1
		print("CONVEYOR_TRIGGER " + JSON.stringify({"fixture": "独立坐标相位输入", "ball_id": index % 16, "x": x, "phase": conveyor.phase, "position_slot": hit["position_slot"], "content_slot": hit["content_slot"], "visible_kind": visible_kind, "output_kind": hit["kind"]}))
	var total_positions := 0
	var total_contents := 0
	for value in conveyor.position_counts:
		total_positions += value
	for value in conveyor.content_counts:
		total_contents += value
	conveyor.phase = 5.999999
	var before := int(conveyor.sample(35.0)["kind"])
	conveyor.phase = 0.000001
	continuity_ok = before == int(conveyor.sample(35.0)["kind"])
	check(matches == 120 and coverage_ok and continuity_ok, "120次输送带显示与输出一致", "测试输入覆盖不同落点及相位，独立几何参考；矩形全宽覆盖且循环边界连续", {"matches": matches, "count": 120})
	check(total_positions == 120 and total_contents == 120, "底部固定位置与内容分别计数", "两套累计各120次，固定位置与内容索引独立", {"position_counts": conveyor.position_counts, "content_counts": conveyor.content_counts})

func _test_rescue() -> void:
	var pinball = _new_pinball()
	var values := [8.0, 1024.0, 64.0, 256.0]
	for index in range(4):
		pinball.balls[index]["value"] = values[index]
		pinball._update_radius(pinball.balls[index])
	pinball.simulation_time = 900.0
	var rescued: float = pinball.rescue(0)
	check(rescued == 1024.0 and pinball.balls[1]["value"] == 2.0 and pinball.balls[0]["value"] == 8.0 and pinball.balls[2]["value"] == 64.0 and pinball.balls[3]["value"] == 256.0 and pinball.balls[1]["threshold"] == pinball.threshold_at(900.0), "紧急保命仅抽当前最大弹药球", "最大1024转换，只有该球重生并更新出生门槛，剩余三球不动", {"rescued": rescued})
	var death_values: Array[float] = pinball.eliminate(0)
	death_values.sort()
	check(death_values == [2.0, 8.0, 64.0, 256.0] and pinball.balls.size() == 12 and pinball.rescue(0) == 0.0 and pinball.eliminate(0).is_empty(), "阵营死亡抽出4球且停止循环", "死亡余波保留四球当前数值；再次抽取为空", {"death_balls": death_values})
	pinball.free()

func _test_physical_contacts() -> void:
	var pinball = _new_pinball()
	pinball.configure({"restitution": 1.0, "friction": 0.0})
	pinball.balls.resize(2)
	var a: Dictionary = pinball.balls[0]
	var b: Dictionary = pinball.balls[1]
	a["p"] = Vector2(200.0, 200.0)
	b["p"] = Vector2(207.0, 200.0)
	a["v"] = Vector2(100.0, 0.0)
	b["v"] = Vector2(-100.0, 0.0)
	b["team"] = 1
	pinball._ball_contacts()
	check(Vector2(a["v"]).x < 0.0 and Vector2(b["v"]).x > 0.0 and a["value"] == 2.0 and b["value"] == 2.0, "异色弹药球弹性相撞不消耗", "正式冲量解析，相向速度反转且弹药保留")
	a["value"] = 4000.0
	pinball._update_radius(a)
	a["p"] = Vector2(200.0, 210.0)
	b["p"] = Vector2(218.0, 210.0)
	a["v"] = Vector2.ZERO
	b["v"] = Vector2(-100.0, 0.0)
	pinball._ball_contacts()
	check(float(a["mass"]) > float(b["mass"]) and absf(Vector2(a["v"]).x) < absf(Vector2(b["v"]).x - (-100.0)), "大球质量更大且碰撞偏移更小", "半径平方质量参与真实冲量", {"large_mass": a["mass"], "small_mass": b["mass"]})
	pinball.free()

func _test_motion_watch() -> void:
	# Sensor fixtures supply a known trajectory to the production observer;
	# physical integration itself is covered by the long run and channel suite.
	for scenario in ["still", "local_loop", "moving"]:
		var pinball = _new_pinball()
		pinball.balls.resize(1)
		var ball: Dictionary = pinball.balls[0]
		ball["value"] = 8192.0
		ball["threshold"] = 10000.0
		ball["t_birth"] = 10000.0
		ball["birth_time"] = 123.0
		ball["p"] = Vector2(240.0, 240.0)
		ball["v"] = Vector2.ZERO
		pinball._update_radius(ball)
		pinball.simulation_time = 0.0
		pinball._reset_motion_watch(ball)
		var relocated_at := -1.0
		for index in range(110):
			var t: float = float(index + 1) * 0.1
			pinball.simulation_time = t
			if scenario == "local_loop":
				ball["p"] = Vector2(240.0 + 24.0 * sin(t * TAU), 240.0 + 24.0 * cos(t * TAU))
				ball["v"] = Vector2(24.0 * TAU * cos(t * TAU), -24.0 * TAU * sin(t * TAU))
			elif scenario == "moving":
				ball["p"] = Vector2(240.0 + 110.0 * sin(t), 200.0 + 20.0 * t)
				ball["v"] = Vector2(110.0 * cos(t), 20.0)
			pinball._watch_motion(ball)
			if pinball.unstuck_events > 0:
				relocated_at = t
				break
		var preserved: bool = ball["value"] == 8192.0 and ball["threshold"] == 10000.0 and ball["t_birth"] == 10000.0 and ball["birth_time"] == 123.0 and int(ball["team"]) == 0 and pinball.output_events == 0 and pinball.multiplier_events == 0
		var correct: bool = preserved
		if scenario == "moving":
			correct = correct and relocated_at < 0.0
		else:
			correct = correct and relocated_at >= (3.0 if scenario == "still" else 8.0) and relocated_at < (4.0 if scenario == "still" else 9.0) and Vector2(ball["v"]).y < 0.0 and Vector2(ball["p"]).y < 150.0
		check(correct, "防卡轨迹观测-%s" % scenario, "静止与局部回圈应保值重发；持续推进轨迹不触发；重发不记输出或倍率", {"relocated_at_sim_seconds": relocated_at, "energy": ball["value"], "threshold": ball["threshold"], "outputs": pinball.output_events, "multipliers": pinball.multiplier_events})
		pinball.free()

func _on_physical_trigger(data: Dictionary) -> void:
	maximum_energy = maxf(maximum_energy, float(data.get("after", data.get("energy", 2.0))))
	current_run_peak_energy = maxf(current_run_peak_energy, float(data.get("after", data.get("energy", 2.0))))
	if data.get("type", "") == "unstuck":
		var reason: String = str(data.get("reason", "unknown"))
		unstuck_reasons[reason] = int(unstuck_reasons.get(reason, 0)) + 1
		print("PINBALL_UNSTUCK " + JSON.stringify(data))
	if data.get("type", "") == "output":
		actual_bottom_logs += 1
		output_energy += float(data.get("energy", 0.0))
		if actual_bottom_logs <= 120:
			print("PHYSICAL_OUTPUT " + JSON.stringify(data))

func _test_long_run() -> void:
	var pinball = _new_pinball()
	pinball.trigger_log.connect(_on_physical_trigger)
	var requested: float = float(options.get("duration", "1200"))
	var seed: int = int(options.get("seed", "20261016"))
	var seed_count: int = clampi(int(options.get("seeds", "3")), 1, 32)
	var secondary_duration: float = maxf(0.01, float(options.get("secondary-duration", str(minf(120.0, requested)))))
	var executed_seeds: Array[int] = []
	var all_valid := true
	var reported_invalid := false
	var all_progress := true
	var worst_idle := 0.0
	var total_multipliers := 0
	var total_outputs := 0
	var begin: int = Time.get_ticks_msec()
	# CPU-only real left-side simulation; these are not complete GPU matches.
	# --secondary-duration permits multiple full long seeds without changing physics.
	for run_index in range(seed_count):
		pinball.reset(seed + run_index)
		current_run_peak_energy = 2.0
		executed_seeds.append(seed + run_index)
		var run_output_start: int = actual_bottom_logs
		var run_energy_start: float = output_energy
		var run_max_energy: float = 2.0
		var last_birth: Dictionary = {}
		var last_output: Dictionary = {}
		var reported_stalls: Dictionary = {}
		var duration: float = requested if run_index == 0 else secondary_duration
		var last_events: Array[int] = []
		var last_active: Array[float] = []
		for _id in range(16):
			last_events.append(0)
			last_active.append(0.0)
		var steps: int = int(ceil(duration * 120.0))
		for index in range(steps):
			var t: float = float(index + 1) / 120.0
			pinball.step(1.0 / 120.0, t)
			if index % 120 != 0 and index + 1 < steps:
				continue
			all_valid = all_valid and pinball.balls.size() == 16
			all_valid = all_valid and str(pinball.snapshot().get("error", "")).is_empty()
			for ball in pinball.balls:
				var id: int = ball["id"]
				var p: Vector2 = ball["p"]
				var v: Vector2 = ball["v"]
				var ball_valid: bool = is_finite(p.x) and is_finite(p.y) and is_finite(v.x) and is_finite(v.y) and is_finite(float(ball["value"])) and float(ball["value"]) >= 2.0 and p.y >= 58.0 and p.y <= 790.0 and p.x >= 15.0 and p.x <= 465.0
				all_valid = all_valid and ball_valid
				if not ball_valid and not reported_invalid:
					reported_invalid = true
					print("PINBALL_INVALID_STATE " + JSON.stringify({"seed": seed + run_index, "sim_seconds": t, "ball": ball.duplicate(true)}))
				run_max_energy = maxf(run_max_energy, float(ball["value"]))
				maximum_energy = maxf(maximum_energy, float(ball["value"]))
				if last_birth.has(id) and int(last_output[id]) == int(ball["outputs"]):
					if float(last_birth[id]) != float(ball["threshold"]) or float(ball["t_birth"]) != float(ball["threshold"]):
						birth_errors += 1
				last_birth[id] = ball["threshold"]
				last_output[id] = ball["outputs"]
				var events: int = int(ball["loops"]) + int(ball["outputs"])
				if events != last_events[id]:
					last_active[id] = t
					last_events[id] = events
				worst_idle = maxf(worst_idle, t - last_active[id])
				if t - last_active[id] > 90.0 and not reported_stalls.has(id):
					reported_stalls[id] = true
					print("PINBALL_STALL_OBSERVATION " + JSON.stringify({"seed": seed + run_index, "sim_seconds": t, "no_multiplier_or_output_seconds": t - last_active[id], "ball": ball.duplicate(true)}))
			if index % 1200 == 0:
				await process_frame
			if index % 7200 == 0:
				var max_speed := 0.0
				for tracked in pinball.balls:
					max_speed = maxf(max_speed, Vector2(tracked["v"]).length())
				print("PINBALL_PROGRESS " + JSON.stringify({"seed": seed + run_index, "sim_seconds": t, "active": pinball.balls.size(), "multipliers": pinball.multiplier_events, "outputs": pinball.output_events, "fault": pinball.snapshot().get("error", ""), "worst_idle": worst_idle, "maximum_speed": max_speed, "wall_seconds": float(Time.get_ticks_msec() - begin) / 1000.0}))
		for ball in pinball.balls:
			all_progress = all_progress and int(ball["loops"]) + int(ball["outputs"]) > 0
			total_multipliers += int(ball["loops"])
			total_outputs += int(ball["outputs"])
		print("PINBALL_LONG_RUN " + JSON.stringify({"seed": seed + run_index, "sim_seconds": duration, "multiplier_events": pinball.multiplier_events, "output_events": pinball.output_events, "counts": pinball.channels.counts, "active": pinball.balls.size(), "worst_idle_seconds": worst_idle, "maximum_active_energy": run_max_energy, "maximum_event_energy": current_run_peak_energy, "average_output_energy": (output_energy - run_energy_start) / maxf(1.0, actual_bottom_logs - run_output_start), "unstuck_events": pinball.unstuck_events}))
	check(all_valid, "多种子左侧持续模拟16球完整与数值有限", "按命令指定主/次种子时长；每模拟秒检查球数、边界、有限值及显式故障", {"main_sim_seconds": requested, "secondary_sim_seconds": secondary_duration, "seeds": executed_seeds, "wall_seconds": float(Time.get_ticks_msec() - begin) / 1000.0})
	check(all_progress and worst_idle < 120.0, "多种子实体通道不卡球", "每球均产生倍率或完整输出，任何球连续无进度不得达到120模拟秒", {"worst_idle_seconds": worst_idle, "multiplier_events": total_multipliers, "output_events": total_outputs})
	check(actual_bottom_logs >= 100, "至少100次真实物理落槽日志", "记录正式物理触发落点/相位/槽位/输出；与独立坐标夹具日志分开", {"physical_outputs": actual_bottom_logs})
	check(birth_errors == 0, "长局倍率/防卡保持出生基准", "逐模拟秒对照相邻快照：未正常输出的同一球不能更改阈值，t_birth必须始终匹配", {"birth_errors": birth_errors, "maximum_energy": maximum_energy, "average_output_energy": output_energy / maxf(1.0, actual_bottom_logs), "unstuck_reasons": unstuck_reasons})
	pinball.free()
