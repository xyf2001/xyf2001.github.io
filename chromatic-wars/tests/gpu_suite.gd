extends "res://tests/test_harness.gd"
## 此套件必须普通 Vulkan 窗口。只在测试中读取最多64粒子与小地块。
## 所有注入命令由真实Compute执行；本文件不计算或上传粒子演化结果。
const World = preload("res://scripts/gpu_world.gd")
const SpaceRules = preload("res://scripts/gpu_collisions.gd")
var world
var view: TextureRect
var snapshots: Dictionary = {}
var runtime_error := ""
var sim_time := 0.0

func run_suite() -> void:
	print("环境：Godot %s；驱动=%s；GPU Compute 实际规则测试" % [Engine.get_version_info()["string"], RenderingServer.get_current_rendering_driver_name()])
	if RenderingServer.get_current_rendering_method() != "forward_plus" or RenderingServer.get_current_rendering_driver_name() != "vulkan":
		record("NOT TESTED", "Vulkan运行前提", "必须普通窗口 Forward+ / Vulkan，禁止 --headless 假代替GPU测试")
		finish()
		return
	world = World.new()
	# 本套件确实注入±2000的狙击，必须申明相同配置速度上界供正式子步约束使用。
	world.configure({"particle_capacity": 1024, "grid_size": 64, "render_size": 256, "seed": int(options.get("seed", "20261016")), "gun_start": 0.0, "gun_end": 0.0, "precision_mode": "exact", "sniper_speed": 2000.0})
	world.debug_snapshot_ready.connect(_on_snapshot)
	world.failed.connect(func(message: String): runtime_error = message)
	root.add_child(world)
	view = TextureRect.new()
	view.position = Vector2(32.0, 32.0)
	view.size = Vector2(512.0, 512.0)
	view.texture = world.texture
	root.add_child(view)
	world.start()
	var deadline: int = Time.get_ticks_msec() + 30000
	while not world.active and runtime_error.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if not check(world.active, "真实Compute管线初始化", runtime_error if not runtime_error.is_empty() else "初始化截止30秒", {"driver": RenderingServer.get_current_rendering_driver_name()}):
		world.shutdown()
		finish()
		return
	var initial: Dictionary = await _snapshot()
	if initial.is_empty():
		world.shutdown()
		finish()
		return
	await _test_initial(initial)
	await _test_render()
	await _test_gpu_statistics()
	await _test_territory_and_wall()
	await _test_particle_collisions()
	await _test_fine_grid_boundaries()
	await _test_dense_cell()
	await _test_shield_contact()
	await _test_pending_rescue()
	await _test_pending_shield_guard()
	await _test_big_balls()
	await _test_output_energy()
	await _test_dead_output_guard()
	await _test_precision_transition()
	await _test_priority_shield()
	await _test_timed_outputs()
	world.shutdown()
	await process_frame
	await process_frame
	finish()

func _on_snapshot(data: Dictionary) -> void:
	snapshots[int(data.get("request_id", -1))] = data

func _snapshot(kind: String = "sample") -> Dictionary:
	world.flush()
	await process_frame
	var request: Dictionary = world.debug_readback(kind)
	var id: int = request.get("request_id", -1)
	var deadline: int = Time.get_ticks_msec() + 15000
	while not snapshots.has(id) and Time.get_ticks_msec() < deadline and runtime_error.is_empty():
		world.flush()
		await process_frame
	if snapshots.has(id):
		var result: Dictionary = snapshots[id]
		snapshots.erase(id)
		return result
	record("FAIL", "GPU异步调试快照", runtime_error if not runtime_error.is_empty() else "15秒内没有完成少量数据回读")
	return {}

func _advance(steps: int = 1, dt: float = 1.0 / 120.0) -> void:
	for _index in range(steps):
		sim_time += dt
		world.step(dt, sim_time)
	world.flush()
	await process_frame
	await process_frame

func _reset_fixture(owner: int = 0, shield: float = 0.0) -> void:
	world.debug_command({"op": 14})
	world.debug_command({"op": 16, "team": owner})
	for team in range(4):
		world.debug_command({"op": 10, "team": team, "energy": shield, "gun": 0.0, "state": 0, "ready_time": 0.0})
	world.flush()
	await process_frame
	await process_frame

func _inject(team: int, energy: float, position: Vector2, velocity: Vector2 = Vector2.ZERO, op: int = 11) -> void:
	world.debug_command({"op": op, "team": team, "energy": energy, "x": position.x, "y": position.y, "vx": velocity.x, "vy": velocity.y})

func _energy(data: Dictionary, big: bool = false) -> int:
	var total := 0
	for particle in data.get("balls" if big else "particles", []):
		total += int(particle["energy"])
	return total

func _test_initial(data: Dictionary) -> void:
	var teams: Array = data.get("teams", [])
	var valid: bool = teams.size() == 4
	for team in teams:
		valid = valid and bool(team["alive"]) and not bool(team["pending"]) and int(team["shield"]) == 1000000 and int(team["gun"]) == 1000000
		valid = valid and float(team["rescue_cd"]) == 0.0
	var metrics: Array = data.get("metrics", [])
	valid = valid and metrics.size() >= 12
	if metrics.size() >= 12:
		for index in range(4):
			valid = valid and int(metrics[8 + index]) == 1024
	check(valid, "GPU开局四队存活、盾枪各1M与25%领土", "读取真实GPU团队缓冲与领土归约计数，开局保命就绪", {"teams": teams, "territory_counts": metrics.slice(8, 12)})
	var corners_ok := true
	for corner in [{"index": 0, "owner": 0}, {"index": 63, "owner": 1}, {"index": 4032, "owner": 2}, {"index": 4095, "owner": 3}]:
		var sample: Dictionary = await _snapshot("terrain:%d:1" % int(corner["index"]))
		corners_ok = corners_ok and not sample.get("terrain", []).is_empty() and int(sample["terrain"][0]) == int(corner["owner"])
	check(corners_ok, "GPU领土象限位置", "红左上、绿右上、蓝左下、黄右下；真实GPU角落格子")

func _test_render() -> void:
	await process_frame
	await RenderingServer.frame_post_draw
	var image: Image = root.get_texture().get_image()
	if image == null or image.is_empty():
		record("FAIL", "显存共享纹理实际显示", "视口截图为空")
		return
	var logical_size: Vector2 = root.get_visible_rect().size
	var scale: Vector2 = Vector2(image.get_width(), image.get_height()) / logical_size
	var points: Array[Vector2] = []
	for fraction in [Vector2(0.15, 0.15), Vector2(0.85, 0.15), Vector2(0.15, 0.85), Vector2(0.85, 0.85)]:
		points.append((view.get_global_transform_with_canvas() * (view.size * fraction)) * scale)
	var a: Color = image.get_pixelv(Vector2i(points[0]))
	var b: Color = image.get_pixelv(Vector2i(points[1]))
	var c: Color = image.get_pixelv(Vector2i(points[2]))
	var d: Color = image.get_pixelv(Vector2i(points[3]))
	var valid: bool = world.texture.texture_rd_rid.is_valid() and a.r > a.g * 1.3 and b.g > b.r * 1.3 and c.b > c.r * 1.3 and d.r > d.b * 1.3 and d.g > d.b * 1.3
	var folder: String = str(options.get("artifact-dir", "res://artifacts"))
	DirAccess.make_dir_recursive_absolute(folder)
	var screenshot: String = folder.path_join("gpu_initial.png")
	var saved: int = image.save_png(screenshot)
	check(valid and saved == OK, "显存共享纹理实际显示", "真实视口单次Debug截图，根据实际Canvas缩放采样四象限；正式渲染不依赖此读回", {"screenshot": screenshot, "pixels": [str(a), str(b), str(c), str(d)], "sample_points": str(points), "logical_size": str(logical_size), "image_size": str(image.get_size())})

func _test_territory_and_wall() -> void:
	await _reset_fixture(0)
	_inject(0, 8.0, Vector2(100.0, 100.0), Vector2(120.0, 0.0))
	await _advance(4)
	var own: Dictionary = await _snapshot()
	check(_energy(own) == 8, "己方领土不消耗能量", "正式GPU移动4步，粒子包保留8点", {"particles": own.get("particles", [])})
	await _reset_fixture(0)
	# 改一格为中立（4）；粒子实际位于这一格中心。
	var cell := 6 * 64 + 6
	world.debug_command({"op": 15, "team": 4, "energy": cell, "count": 1})
	_inject(0, 8.0, Vector2(104.0, 104.0))
	var before: Dictionary = await _snapshot()
	await _advance()
	var after: Dictionary = await _snapshot("terrain:%d:1" % cell)
	var captures: int = int(after.get("consumed_energy", 0)) - int(before.get("consumed_energy", 0))
	check(_energy(after) == 7 and after.get("terrain", []) == [0] and captures == 1, "包占一格严格消耗一点", "中立格被染为0号队；8点包剩7，累积已消耗只增加1", {"remaining": _energy(after), "consumed_delta": captures})
	await _reset_fixture(0)
	_inject(0, 1.0, Vector2(2.0, 100.0), Vector2(-500.0, 0.0))
	await _advance()
	var wall: Dictionary = await _snapshot()
	var particles: Array = wall.get("particles", [])
	check(particles.size() == 1 and float(particles[0]["vx"]) > 0.0 and float(particles[0]["x"]) >= float(particles[0]["radius"]), "粒子真实墙壁反弹", "向左高速入墙后速度向右，位置仍在实体半径内侧", {"particles": particles})

func _test_particle_collisions() -> void:
	await _reset_fixture(0)
	_inject(0, 1.0, Vector2(100.0, 100.0), Vector2(20.0, 0.0))
	_inject(0, 1.0, Vector2(102.0, 100.0), Vector2(-20.0, 0.0))
	await _advance()
	var friendly: Dictionary = await _snapshot()
	var same: Array = friendly.get("particles", [])
	var bounced: bool = same.size() == 2
	if same.size() == 2:
		bounced = bounced and float(same[0]["vx"]) < 0.0 and float(same[1]["vx"]) > 0.0
	check(_energy(friendly) == 2 and bounced, "同阵营粒子碰撞反弹不消耗", "实际GPU空间链表+碰撞结算，两个能量1粒子", {"particles": same})
	await _reset_fixture(0)
	_inject(0, 10.0, Vector2(100.0, 100.0))
	_inject(1, 4.0, Vector2(101.0, 100.0))
	var before: Dictionary = await _snapshot()
	await _advance()
	var enemy: Dictionary = await _snapshot()
	var enemy_particles: Array = enemy.get("particles", [])
	var consumed_delta: int = int(enemy.get("consumed_energy", 0)) - int(before.get("consumed_energy", 0))
	check(enemy_particles.size() == 1 and _energy(enemy) == 6 and int(enemy_particles[0]["team"]) == 0 and consumed_delta == 8, "异阵营粒子包等量抵消", "10与4相撞后剩6；双方合计消耗8，无负能量", {"particles": enemy_particles, "consumed_delta": consumed_delta})
	await _reset_fixture(0)
	_inject(0, 1.0, Vector2(17.0, 110.0), Vector2(2000.0, 0.0), 12)
	_inject(1, 1.0, Vector2(20.0, 110.0), Vector2(-2000.0, 0.0), 12)
	await _advance()
	var swept: Dictionary = await _snapshot()
	check(swept.get("particles", []).is_empty(), "超高速相向狙击不跨格漏碰", "x17/+2000和x20/-2000，在一个固定步内相遇；两颗1能量应等消", {"particles": swept.get("particles", [])})

func _test_fine_grid_boundaries() -> void:
	var bounds_ok := true
	var bounds: Array = []
	for fixture in [{"radius": 0.5, "speed": 620.0, "dt": 1.0 / 60.0}, {"radius": 1.2, "speed": 620.0, "dt": 1.0 / 120.0}, {"radius": 3.0, "speed": 2000.0, "dt": 1.0 / 60.0}, {"radius": 1.4, "speed": 2000.0, "dt": 1.0 / 240.0}]:
		var radius: float = fixture["radius"]
		var speed: float = fixture["speed"]
		var dt: float = fixture["dt"]
		var count: int = SpaceRules.substep_count(dt, {"particle_radius": radius, "sniper_speed": speed, "particle_speed": 140.0, "ball_speed": 92.0})
		var displacement: float = speed * dt / float(count)
		var limit: float = minf(4.0, (8.0 - 2.0 * radius) * 0.5)
		bounds_ok = bounds_ok and count >= 1 and displacement <= limit + 0.000001 and 2.0 * displacement + 2.0 * radius <= 8.000001 and dt / float(count) <= 1.0 / 120.0 + 0.000001
		if radius == 1.2 and speed == 620.0:
			bounds_ok = bounds_ok and count == 2
		bounds.append({"radius": radius, "speed": speed, "fixed_dt": dt, "substeps": count, "displacement": displacement, "limit": limit})
	check(bounds_ok, "8px空间格子步位移覆盖3×3高速候选", "半径0.5至3、速度620/2000与1/60至1/240固定步满足2*位移+2*半径<=8；默认配置仍只需2子步", {"bounds": bounds})
	await _reset_fixture(0)
	# 起点分别属于8px格1与格3。若仍用旧4px上限，第一子步交换后仍隔两个格，
	# 3×3邻域会漏碰；配套细网格位移约束应在中间子步先找到相遇候选。
	_inject(0, 1.0, Vector2(15.9, 110.0), Vector2(2000.0, 0.0), 12)
	_inject(1, 1.0, Vector2(24.1, 110.0), Vector2(-2000.0, 0.0), 12)
	var before: Dictionary = await _snapshot()
	await _advance()
	var after: Dictionary = await _snapshot()
	var consumed_delta: int = int(after.get("consumed_energy", 0)) - int(before.get("consumed_energy", 0))
	check(after.get("particles", []).is_empty() and consumed_delta == 2, "8px格边界两格相隔高速相向狙击不漏碰", "真实GPU从x15.9/+2000与x24.1/−2000推进一个固定步，配套子步使两颗1能量严格等消", {"particles": after.get("particles", []), "consumed_delta": consumed_delta, "substeps": SpaceRules.substep_count(1.0 / 120.0, world.settings)})

func _test_dense_cell() -> void:
	await _reset_fixture(0)
	for index in range(40):
		_inject(0 if index < 20 else 1, 1.0, Vector2(101.0, 101.0))
	var before: Dictionary = await _snapshot()
	await _advance()
	var data: Dictionary = await _snapshot()
	var metrics: Array = data.get("metrics", [])
	var occupancy: int = int(metrics[6]) if metrics.size() > 6 else -1
	var consumed_delta: int = int(data.get("consumed_energy", 0)) - int(before.get("consumed_energy", 0))
	check(_energy(data) + consumed_delta == 40 and occupancy >= 40, "同格40颗敌我粒子无32颗截断", "密集格最大占用真实报告≥40；碰撞位置分离后剩余能量+已消耗严格等于40", {"remaining": _energy(data), "consumed_delta": consumed_delta, "max_cell_occupancy": occupancy})

func _test_shield_contact() -> void:
	await _reset_fixture(1, 2.0)
	var state: Dictionary = await _snapshot()
	var team: Dictionary = state["teams"][0]
	var radius: float = float(team["shield_radius"])
	# 初始大球能量10、T_birth≈100，半径由正式GPU自己计算。
	var big_radius: float = 7.0 + 3.0 * sqrt(10.0 / (100.0 + 999900.0 * sim_time / 1200.0))
	_inject(1, 10.0, Vector2(256.0 + radius + big_radius - 0.2, 256.0), Vector2(-60.0, 0.0), 13)
	await _advance()
	var impact: Dictionary = await _snapshot()
	var defender: Dictionary = impact["teams"][0]
	var big: Array = impact.get("balls", [])
	var valid: bool = int(defender["shield"]) == 0 and int(defender["state"]) == 0 and big.size() == 1
	if big.size() == 1:
		valid = valid and float(big[0]["vx"]) > 0.0 and float(big[0]["x"]) > 256.0 + 12.0 + float(big[0]["radius"])
	check(valid, "破盾同一次大球接触不能致死", "盾2对球10，破盾仍存活；大球立即分离并反射", {"defender": defender, "balls": big})
	await _advance(8)
	var separated: Dictionary = await _snapshot()
	check(int(separated["teams"][0]["state"]) == 0 and _energy(separated, true) == 8, "大球破盾后不粘连或重复扣能量", "分离后8个固定步，剩余8点且核心仍存活", {"balls": separated.get("balls", [])})

func _test_pending_rescue() -> void:
	await _reset_fixture(3)
	for target in range(2):
		var center := Vector2(256.0 if target == 0 else 768.0, 256.0)
		for hit in range(3):
			_inject(1 - target, 1.0, center + Vector2(5.0 + float(hit) * 3.0, 0.0))
	await _advance()
	var pending: Dictionary = await _snapshot()
	var valid: bool = int(pending["teams"][0]["state"]) == 1 and int(pending["teams"][1]["state"]) == 1
	check(valid, "同帧多致命命中与多核心保命待定", "两核各3个攻击仍进入唯一PENDING_RESCUE，不先行死亡", {"teams": pending.get("teams", [])})
	await _advance(8)
	var latched: Dictionary = await _snapshot()
	check(int(latched["teams"][0]["state"]) == 1 and int(latched["teams"][1]["state"]) == 1 and int(latched["teams"][0]["request_nonce"]) == int(pending["teams"][0]["request_nonce"]), "GPU待定事件跨帧锁存", "CPU还未答复时8步仍待定，同核请求nonce只增加一次")
	# 等待正式少量统计回读更新nonce，再调用正式resolve_rescue入口。
	var deadline: int = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < deadline:
		world.flush()
		await process_frame
		var teams: Array = world.stats.get("teams", [])
		if teams.size() == 4 and bool(teams[0].get("pending", false)) and bool(teams[1].get("pending", false)):
			break
	world.resolve_rescue(0, 777.0)
	world.resolve_rescue(1, 0.0)
	await _advance()
	var rescued: Dictionary = await _snapshot()
	check(int(rescued["teams"][0]["state"]) == 0 and int(rescued["teams"][0]["shield"]) == 777 and float(rescued["teams"][0]["rescue_cd"]) >= 179.9 and int(rescued["teams"][1]["state"]) == 2, "正式保命握手成功补盾与失败淘汰", "0号队补777并设180模拟秒CD；1号队无球回0才淘汰", {"teams": rescued.get("teams", [])})
	world.output(1, 0, 1000.0)
	await _advance()
	var no_revive: Dictionary = await _snapshot()
	check(int(no_revive["teams"][1]["state"]) == 2 and int(no_revive["teams"][1]["shield"]) == 0, "淘汰核心不可通过护盾输出复活", "已死亡队再补盾命令被拒绝")
	# 模拟成功保命后护盾已被先前攻击耗尽，但CD还没有到期。
	world.debug_command({"op": 14})
	world.debug_command({"op": 10, "team": 0, "energy": 0, "gun": 11, "state": 0, "ready_time": float(rescued["teams"][0]["ready_time"])})
	_inject(1, 1.0, Vector2(261.0, 256.0))
	var before_cd_death: Dictionary = await _snapshot()
	await _advance()
	var cd_death: Dictionary = await _snapshot()
	var dead: Dictionary = cd_death["teams"][0]
	var consumed_delta: int = int(cd_death.get("consumed_energy", 0)) - int(before_cd_death.get("consumed_energy", 0))
	var accounted: int = _energy(cd_death) + int(dead["storm"]) + consumed_delta
	check(int(dead["state"]) == 2 and int(dead["request_nonce"]) == int(rescued["teams"][0]["request_nonce"]) and int(dead["gun"]) == 0 and accounted == 12, "保命CD中再致命必须淘汰并释放枪库存", "无盾+CD未就绪不再抽球；11机枪库存转死亡风暴（可已发射）+1入侵粒子严格守恒", {"team": dead, "accounted_energy": accounted, "consumed_delta": consumed_delta, "particles": cd_death.get("particles", [])})

func _test_big_balls() -> void:
	await _reset_fixture(0)
	_inject(0, 40.0, Vector2(100.0, 100.0), Vector2(10.0, 0.0), 13)
	_inject(0, 40.0, Vector2(116.0, 100.0), Vector2(-10.0, 0.0), 13)
	await _advance()
	var same: Dictionary = await _snapshot()
	var balls: Array = same.get("balls", [])
	check(balls.size() == 2 and _energy(same, true) == 80 and float(balls[0]["vx"]) < 0.0 and float(balls[1]["vx"]) > 0.0, "同阵营大球实体碰撞无损耗", "实际GPU球-球碰撞速度互换，能量保留80", {"balls": balls})
	await _reset_fixture(0)
	_inject(0, 40.0, Vector2(100.0, 100.0), Vector2(10.0, 0.0), 13)
	_inject(1, 10.0, Vector2(115.0, 100.0), Vector2(-10.0, 0.0), 13)
	await _advance()
	var enemy: Dictionary = await _snapshot()
	check(enemy.get("balls", []).size() == 1 and _energy(enemy, true) == 30, "异阵营大球等量抵消", "40对10剩30，敌球消失", {"balls": enemy.get("balls", [])})
	await _reset_fixture(0)
	_inject(0, 40.0, Vector2(100.0, 100.0), Vector2.ZERO, 13)
	_inject(1, 1.0, Vector2(108.0, 100.0), Vector2(-200.0, 0.0))
	await _advance()
	var pushed: Dictionary = await _snapshot()
	var result: Array = pushed.get("balls", [])
	check(result.size() == 1 and _energy(pushed, true) == 39 and absf(float(result[0]["vx"])) > 0.01, "普通粒子等消并推动大球", "大球40变39且获得非零真实冲量", {"balls": result})

func _test_pending_shield_guard() -> void:
	await _reset_fixture(1)
	_inject(1, 1.0, Vector2(261.0, 256.0))
	await _advance()
	var pending: Dictionary = await _snapshot()
	world.debug_command({"op": 14})
	world.output(0, 0, 23.0)
	await _advance()
	# 旧的无球回复可在异步往返期间迟到；GPU若已有盾应取消淘汰。
	world.debug_command({"op": 6, "team": 0, "energy": 0, "nonce": int(pending["teams"][0]["request_nonce"])})
	await _advance()
	var guarded: Dictionary = await _snapshot()
	check(int(guarded["teams"][0]["state"]) == 0 and int(guarded["teams"][0]["shield"]) == 23, "待保命期间补盾抵挡迟到的失败回复", "GPU已有唯一23护盾后，旧resolve0不能再杀核心", {"team": guarded["teams"][0]})

func _test_output_energy() -> void:
	await _reset_fixture(0)
	world.output(0, 3, 2.0)
	await _advance()
	var data: Dictionary = await _snapshot()
	check(_energy(data) + int(data["teams"][0]["storm"]) == 2, "风暴小额输出不凭空增能", "输出2严格等于实际在场粒子+未发库存，不得强制生成8颗", {"particles": data.get("particles", []), "storm_remaining": data["teams"][0]["storm"]})
	await _reset_fixture(0)
	world.output(0, 0, 17.0)
	world.output(0, 4, 19.0)
	await _advance()
	var charged: Dictionary = await _snapshot()
	check(int(charged["teams"][0]["shield"]) == 17 and int(charged["teams"][0]["gun"]) == 19 and int(charged["teams"][0]["storm"]) == 0 and int(charged["teams"][0]["sniper"]) == 0, "护盾与机枪输出独立库存", "17仅补唯一护盾，19仅补机枪，未共享至即时武器")

func _test_priority_shield() -> void:
	await _reset_fixture(0)
	for index in range(64):
		_inject(0, 2.0, Vector2(100.0 + float(index % 8) * 100.0, 100.0 + float(index / 8) * 100.0), Vector2.ZERO, 13)
	var full: Dictionary = await _snapshot()
	world.output(0, 1, 2.0)
	world.output(0, 0, 37.0)
	await _advance()
	var blocked: Dictionary = await _snapshot()
	check(full.get("balls", []).size() == 64 and int(blocked["teams"][0]["shield"]) == 37 and blocked.get("balls", []).size() == 64, "大球槽满时补盾不受发射队列阻塞", "真实64大球占满，下一大球仍积压；独立优先补盾37照常到唯一GPU护盾", {"shield": blocked["teams"][0]["shield"], "active_balls": blocked.get("balls", []).size(), "ring_backlog": blocked.get("metrics", [0, 0, 0, 0, 0, -1])[5]})

func _test_dead_output_guard() -> void:
	await _reset_fixture(0)
	world.debug_command({"op": 10, "team": 0, "energy": 0, "gun": 0, "state": 2})
	await _advance()
	world.output(0, 1, 7.0)
	world.output(0, 2, 11.0)
	world.output(0, 3, 13.0)
	await _advance()
	var rejected: Dictionary = await _snapshot()
	check(_energy(rejected) == 0 and _energy(rejected, true) == 0 and int(rejected["teams"][0]["storm"]) == 0 and int(rejected["teams"][0]["sniper"]) == 0, "死队普通即时武器不能继续生产", "普通大球/狙击/风暴均拒绝，与明确标记的死亡余波区分")
	world.death_balls(0, [2.0, 4.0, 8.0, 16.0])
	await _advance()
	var after: Dictionary = await _snapshot()
	check(after.get("balls", []).size() == 4 and _energy(after, true) == 30 and not bool(after["teams"][0]["alive"]), "死亡余波标记允许四球且核心不复活", "真实GPU收到death_balls标记，4颗球总能量严格30", {"balls":after.get("balls",[])})

func _test_precision_transition() -> void:
	await _reset_fixture(0)
	_inject(0, 8.0, Vector2(100.0, 100.0), Vector2(1.0, 0.0))
	await _advance()
	var end: int = Time.get_ticks_msec() + 10000
	while Time.get_ticks_msec() < end and (str(world.stats.get("precision_mode", "")) != "mixed" or float(world.stats.get("sim_time", -1)) + 0.00001 < sim_time or int(world.stats.get("active_packet_energy", 0)) != 8):
		world.flush()
		await process_frame
	check(str(world.stats.get("precision_mode", "")) == "mixed" and int(world.stats.get("active_packet_energy", 0)) == 8 and float(world.stats.get("sim_time", -1)) + 0.00001 >= sim_time, "存量能量包仍在时不冒称逐粒子精确", "即使新发射是精确模式，旧8点包还在时遥测显示mixed，界面说明存量近似")

func _test_timed_outputs() -> void:
	await _reset_fixture(0)
	var dt := 1.0 / 120.0
	var due := sim_time + 4.0 * dt
	world.output(0, 0, 17.0, due)
	await _advance(2, dt)
	var early: Dictionary = await _snapshot()
	check(int(early["teams"][0]["shield"]) == 0 and world._queued.size() == 1, "定时护盾未到落槽时刻不提前生效", "安排4步后的17护盾；2步及多次空flush后护盾为0，未来命令仍由CPU保留", {"shield": early["teams"][0]["shield"], "cpu_queue": world._queued.size(), "due": due, "sim_time": sim_time})
	await _advance(2, dt)
	var ready: Dictionary = await _snapshot()
	check(int(ready["teams"][0]["shield"]) == 17 and world._queued.is_empty(), "定时护盾到期只生效一次且未丢失", "继续2步抵达落槽时刻，唯一护盾变17，未来队列清空", {"shield": ready["teams"][0]["shield"], "cpu_queue": world._queued.size()})
	await _reset_fixture(0)
	due = sim_time + 4.0 * dt
	world.output(0, 1, 41.0, due)
	await _advance(4, dt)
	var batched: Dictionary = await _snapshot()
	var born: Array = batched.get("balls", [])
	var expected_birth_scale := 100.0 + 999900.0 * due / 1200.0
	var birth_ok := born.size() == 1 and _energy(batched, true) == 41
	if born.size() == 1:
		birth_ok = birth_ok and absf(float(born[0]["birth_scale"]) - expected_birth_scale) < 0.01
	check(birth_ok, "同批大球按落槽步出生而非批首提前出生", "四个固定步一次flush；大球T_birth必须取第四步的成长阈值，直接读取真实GPU出生尺度", {"balls": born, "expected_birth_scale": expected_birth_scale, "due": due})
	await _reset_fixture(0)
	# 该时刻float32向下舍入，若拿double事件时间比较Vector2批末时间，会误留下一帧。
	sim_time = 1199.99
	due = sim_time + 4.0 * dt
	world.output(0, 0, 29.0, due)
	await _advance(4, dt)
	var long_game: Dictionary = await _snapshot()
	check(int(long_game["teams"][0]["shield"]) == 29 and world._queued.is_empty(), "1200秒附近批末事件不被float32量化拖延", "事件时刻与GPU固定步使用同一float32域；本批末步准确生效，空flush不丢命令", {"shield": long_game["teams"][0]["shield"], "cpu_queue": world._queued.size(), "due": due, "gpu_time": PackedFloat32Array([sim_time])[0]})

func _test_gpu_statistics() -> void:
	await _reset_fixture(0)
	# 129个正常槽的低字相加必然产生进位，独立核对整数分类/总能量。
	# 不推进物理，避免高能粒子碰撞或占地影响统计守恒断言。
	var particle_energy: int = 4294967295
	var expected_energy: int = particle_energy * 129
	for index in range(129):
		_inject(0, float(particle_energy), Vector2(80.0 + float(index % 16) * 40.0, 80.0 + float(index / 16) * 40.0))
	for index in range(3):
		_inject(0, 7.0, Vector2(800.0, 100.0 + 100.0 * float(index)), Vector2.ZERO, 13)
	var data: Dictionary = await _snapshot()
	var metrics: Array = data.get("metrics", [])
	var measured_energy: int = -1
	var counts_ok := false
	if metrics.size() >= 25:
		measured_energy = int(metrics[23]) | (int(metrics[24]) << 32)
		counts_ok = int(metrics[0]) == 129 and int(metrics[1]) == 3 and int(metrics[22]) == 129 and int(metrics[15]) == 0
	check(counts_ok and measured_energy == expected_energy, "GPU统计64位能量进位与粒子分类", "真实Compute注入129颗各2^32−1能量的普通粒子与3大球；正常能量归约保留低字进位，大球能量不混入", {"normal": metrics[0] if metrics.size() > 0 else -1, "big": metrics[1] if metrics.size() > 1 else -1, "packet_count": metrics[22] if metrics.size() > 22 else -1, "energy": measured_energy, "expected_energy": expected_energy})
	await _reset_fixture(0)
	# 三段区域改变不等数量格子，独立核对四队增量面积及总数。
	for region in [{"team": 1, "start": 17, "count": 101}, {"team": 2, "start": 1024, "count": 731}, {"team": 3, "start": 3500, "count": 333}]:
		world.debug_command({"op": 15, "team": region["team"], "energy": region["start"], "count": region["count"]})
	data = await _snapshot()
	metrics = data.get("metrics", [])
	var expected: Array = [2931, 101, 731, 333]
	var territory_ok := metrics.size() >= 12
	for team in range(4):
		territory_ok = territory_ok and metrics.size() > 8 + team and int(metrics[8 + team]) == expected[team]
	check(territory_ok, "GPU领土增量计数四队不等区域", "真实GPU多次修改领土，增量面积必须2931/101/731/333且总和4096", {"counts": metrics.slice(8, 12) if metrics.size() >= 12 else [], "expected": expected})
