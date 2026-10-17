extends "res://tests/gpu_suite.gd"
## 本轮物理规则的独立真实GPU回归；不以CPU计算替代Compute演化。
## 所有大整数输入保持int，避免调试注入先经过float丢失2^53以上低位。

func run_suite() -> void:
	if RenderingServer.get_current_rendering_method() != "forward_plus" or RenderingServer.get_current_rendering_driver_name() != "vulkan":
		record("NOT TESTED", "接触守恒GPU前提", "需要普通窗口Forward+/Vulkan，不能用headless替代")
		finish()
		return
	world = World.new()
	world.configure({"particle_capacity": 1024, "grid_size": 64, "render_size": 256, "seed": 20261017, "intro_gun": 0, "intro_shield": 0, "gun_rate": 1200.0, "particle_speed": 140.0, "sniper_speed": 600.0, "ball_speed": 42.0, "ball_min_speed": 1.0, "growth_target": 100.0, "friendly_particle_collisions": true})
	world.debug_snapshot_ready.connect(_on_snapshot)
	world.failed.connect(func(message: String): runtime_error = message)
	root.add_child(world)
	world.start()
	var deadline := Time.get_ticks_msec() + 240000
	while not world.active and runtime_error.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if not check(world.active, "接触守恒Compute初始化", runtime_error):
		await _shutdown_world()
		finish()
		return
	var atomic_only := str(options.get("atomic-only", "false")).to_lower() in ["true", "1", "yes"]
	var death_only := str(options.get("death-only", "false")).to_lower() in ["true", "1", "yes"]
	if atomic_only or death_only:
		if atomic_only: await _test_parallel_atomic_carry()
		if death_only: await _test_dead_command_energy_accounting()
		await _shutdown_world()
		finish()
		return
	await _test_exact_integer_cancel()
	await _test_friendly_constant_speed()
	await _test_collision_toggle()
	await _test_sniper_direction()
	await _test_sniper_terrain_before_entities()
	await _test_ordinary_terrain_before_entities()
	await _test_ordinary_reflected_path()
	await _test_sniper_entity_toi_order()
	await _test_ball_snapshot_impulse()
	await _test_ball_grazing_contact()
	await _test_ball_projectile_excess()
	await _test_projectile_multi_ball_remainder()
	await _test_friendly_feed()
	await _test_ball_shield_dedup()
	await _test_explicit_ball_drive()
	await _test_zero_energy_exclusion()
	await _test_dead_command_energy_accounting()
	if str(options.get("include-atomic", "false")).to_lower() in ["true", "1", "yes"]:
		await _test_parallel_atomic_carry()
	await _shutdown_world()
	finish()

func _inject_int(t: int, e: int, position: Vector2, velocity: Vector2, op: int = 11) -> void:
	world.debug_command({"op": op, "team": t, "energy": e, "x": position.x, "y": position.y, "vx": velocity.x, "vy": velocity.y})

func _velocity(particle: Dictionary) -> Vector2:
	return Vector2(float(particle.vx), float(particle.vy))

func _physical_particles(data: Dictionary) -> Array:
	var result: Array = []
	var seen: Dictionary = {}
	for particle: Dictionary in data.get("particles", []) + data.get("snipers", []):
		var id := int(particle.id)
		if not seen.has(id):
			seen[id] = true
			result.append(particle)
	return result

func _energy(data: Dictionary, big: bool = false) -> int:
	var total := 0
	for particle: Dictionary in (data.get("balls", []) if big else _physical_particles(data)):
		total += int(particle.energy)
	return total

func _all_energy(data: Dictionary) -> int:
	return _energy(data) + _energy(data, true)

func _accounted(before: Dictionary, after: Dictionary) -> int:
	return _all_energy(after) + int(after.consumed_energy) - int(before.consumed_energy)

func _test_exact_integer_cancel() -> void:
	for amounts in [[10, 4], [4294967301, 4294967298], [9007199254741009, 9007199254740995]]:
		await _reset_fixture(0)
		_inject_int(0, int(amounts[0]), Vector2(100, 100), Vector2(140, 0))
		_inject_int(1, int(amounts[1]), Vector2(102, 100), Vector2(-140, 0))
		var before: Dictionary = await _snapshot()
		await _advance(1, 0.001)
		var after: Dictionary = await _snapshot()
		var survivors: Array = _physical_particles(after)
		var expected: int = int(amounts[0]) - int(amounts[1])
		var valid := survivors.size() == 1 and _energy(after) == expected and _accounted(before, after) == int(amounts[0]) + int(amounts[1])
		if survivors.size() == 1:
			valid = valid and _velocity(survivors[0]).distance_to(Vector2(140, 0)) < 0.001
		check(valid, "敌粒子整数min等消与幸存者不偏转-%s" % str(amounts), "含32位进位与2^53以上整数；残余+双方实际消耗等于注入总能量", {"particles": survivors, "accounted": _accounted(before, after), "expected_remaining": expected})

func _test_friendly_constant_speed() -> void:
	await _reset_fixture(0)
	_inject_int(0, 7, Vector2(100, 100), Vector2(100, 0))
	_inject_int(0, 11, Vector2(102, 100), Vector2(-100, 0))
	var before: Dictionary = await _snapshot()
	await _advance(1, 0.001)
	var after: Dictionary = await _snapshot()
	var ps: Array = _physical_particles(after)
	var valid := ps.size() == 2 and _energy(after) == 18 and int(after.consumed_energy) == int(before.consumed_energy)
	if ps.size() == 2:
		for particle: Dictionary in ps:
			valid = valid and (float(particle.vx) < 0 if int(particle.energy) == 7 else float(particle.vx) > 0)
			valid = valid and absf(_velocity(particle).length() - 100) < 0.001
	check(valid, "己方普通碰撞真实反弹、恒速且无能量损耗", "两颗不同能量普通粒子仍为等机械质量，逐颗保持出生速度", {"particles": ps})

func _test_collision_toggle() -> void:
	world.update_settings({"friendly_particle_collisions": false})
	await _reset_fixture(0)
	_inject_int(0, 7, Vector2(100, 100), Vector2(100, 0))
	_inject_int(0, 11, Vector2(102, 100), Vector2(-100, 0))
	await _advance(1, 0.001)
	var data: Dictionary = await _snapshot()
	var ps: Array = _physical_particles(data)
	var valid := ps.size() == 2 and _energy(data) == 18
	for particle: Dictionary in ps:
		valid = valid and (float(particle.vx) > 0 if int(particle.energy) == 7 else float(particle.vx) < 0)
	check(valid, "友方碰撞开关即时关闭仅实体反弹", "按粒子身份能量检查原方向，不假设free-stack复用后的ID顺序", {"particles": ps})
	world.update_settings({"friendly_particle_collisions": true})

func _test_sniper_direction() -> void:
	await _reset_fixture(0)
	_inject_int(0, 20, Vector2(100, 100), Vector2(500, 100), 12)
	_inject_int(1, 3, Vector2(102, 100), Vector2(-140, 0))
	var before: Dictionary = await _snapshot()
	await _advance(1, 0.001)
	var after: Dictionary = await _snapshot()
	var ps: Array = _physical_particles(after)
	check(ps.size() == 1 and int(ps[0].type) == 2 and int(ps[0].energy) == 17 and _velocity(ps[0]).distance_to(Vector2(500, 100)) < 0.001 and _accounted(before, after) == 23, "狙击被普通粒子等消后方向速度均不偏移", "普通粒子接触不触发实体分裂", {"particles": ps})

func _test_sniper_terrain_before_entities() -> void:
	await _reset_fixture(0)
	world.debug_command({"op": 15, "team": 1, "energy": 6 * 64 + 7, "count": 1})
	_inject_int(0, 1, Vector2(100, 100), Vector2(40000, 0), 12)
	_inject_int(0, 4, Vector2(140, 100), Vector2.ZERO, 13)
	var before: Dictionary = await _snapshot()
	await _advance(1, 0.001)
	var after: Dictionary = await _snapshot()
	check(_physical_particles(after).is_empty() and _energy(after, true) == 4 and int(after.consumed_energy) - int(before.consumed_energy) == 1 and _accounted(before, after) == 5, "敌格先耗尽狙击则不能隔空给后方己球补能", "1能狙击先穿x112敌格扣1耗尽，x140友球仍4；余能4+消耗1严格等于输入5", {"particles": _physical_particles(after), "balls": after.get("balls", []), "accounted": _accounted(before, after), "consumed_delta": int(after.consumed_energy) - int(before.consumed_energy)})
	await _reset_fixture(0)
	world.debug_command({"op": 10, "team": 1, "energy": 10, "gun": 0, "state": 0})
	world.debug_command({"op": 15, "team": 1, "energy": 16 * 64 + 45, "count": 1})
	_inject_int(0, 1, Vector2(710, 256), Vector2(50000, 0), 12)
	before = await _snapshot()
	await _advance(1, 0.001)
	after = await _snapshot()
	check(_physical_particles(after).is_empty() and int(after.teams[1].shield) == 10 and int(after.consumed_energy) - int(before.consumed_energy) == 1 and _accounted(before, after) == 1, "敌格先耗尽狙击则不能隔空伤盾", "x720敌格在护盾实体之前固定扣1；护盾10完整保留，粒子1全部进入消耗账本", {"particles": _physical_particles(after), "team": after.teams[1], "accounted": _accounted(before, after), "consumed_delta": int(after.consumed_energy) - int(before.consumed_energy)})

func _test_ordinary_terrain_before_entities() -> void:
	# Ordinary packets share terrain-before-entity TOI ordering, but never
	# split like a sniper. Input1 expires on the first cell; input8 reaches
	# the actual downstream target with exactly7, without an early-cell veto.
	for incoming in [1, 8]:
		await _reset_fixture(0)
		var cell: int = 6 * 64 + 7
		world.debug_command({"op": 15, "team": 1, "energy": cell, "count": 1})
		_inject_int(0, incoming, Vector2(100, 100), Vector2(40000, 0))
		_inject_int(0, 4, Vector2(140, 100), Vector2.ZERO, 13)
		var before: Dictionary = await _snapshot()
		await _advance(1, 0.001)
		var after: Dictionary = await _snapshot()
		var terrain: Dictionary = await _snapshot("terrain:%d:1" % cell)
		var balls: Array = after.get("balls", [])
		var expected_ball: int = 4 + maxi(incoming - 1, 0)
		var spent: int = int(after.consumed_energy) - int(before.consumed_energy)
		var valid: bool = _physical_particles(after).is_empty() and balls.size() == 1 and int(balls[0].team) == 0 and int(balls[0].energy) == expected_ball and spent == 1 and _accounted(before, after) == incoming + 4 and terrain.get("terrain", []) == [0]
		check(valid, "普通粒子先过敌格再结算后方友球-E%d" % incoming, "1能先染格耗尽不能隔空补球；8能染格扣1后余7真实补给4能友球成11，无狙击分裂；总账严格等于输入", {"input_particle": incoming, "balls": balls, "particles": _physical_particles(after), "terrain": terrain.get("terrain", []), "consumed_delta": spent, "accounted": _accounted(before, after)})

		await _reset_fixture(0)
		world.debug_command({"op": 10, "team": 1, "energy": 10, "gun": 0, "state": 0})
		cell = 16 * 64 + 45
		world.debug_command({"op": 15, "team": 1, "energy": cell, "count": 1})
		_inject_int(0, incoming, Vector2(710, 256), Vector2(50000, 0))
		before = await _snapshot()
		await _advance(1, 0.001)
		after = await _snapshot()
		terrain = await _snapshot("terrain:%d:1" % cell)
		var remaining_hit: int = maxi(incoming - 1, 0)
		var expected_shield: int = 10 - remaining_hit
		spent = int(after.consumed_energy) - int(before.consumed_energy)
		var shield: int = int(after.teams[1].shield)
		valid = _physical_particles(after).is_empty() and shield == expected_shield and int(after.teams[1].state) == 0 and spent == 1 + 2 * remaining_hit and shield + _accounted(before, after) == 10 + incoming and terrain.get("terrain", []) == [0]
		check(valid, "普通粒子先过敌格再结算后方敌盾-E%d" % incoming, "1能只染格不伤盾；8能染格后余7只能将10盾扣至3，双方等消14加染格1，无普通弹分裂或穿盾杀核", {"input_particle": incoming, "shield": shield, "particles": _physical_particles(after), "terrain": terrain.get("terrain", []), "consumed_delta": spent, "shield_plus_accounted": shield + _accounted(before, after)})

func _test_ordinary_reflected_path() -> void:
	# An analytic one-wall trajectory: x4 travels40, reaches the real left
	# radius boundary, then ends at2*r+40-4. Only cells0,1,2 are traversed.
	await _reset_fixture(0)
	var first_cell: int = 6 * 64
	world.debug_command({"op": 15, "team": 1, "energy": first_cell, "count": 4})
	_inject_int(0, 8, Vector2(4, 104), Vector2(-40000, 0))
	var before: Dictionary = await _snapshot()
	await _advance(1, 0.001)
	var after: Dictionary = await _snapshot()
	var terrain: Dictionary = await _snapshot("terrain:%d:4" % first_cell)
	var ps: Array = _physical_particles(after)
	var spent: int = int(after.consumed_energy) - int(before.consumed_energy)
	var free_valid: bool = ps.size() == 1 and int(ps[0].type) == 1 and int(ps[0].energy) == 5 and spent == 3 and _accounted(before, after) == 8 and terrain.get("terrain", []) == [0, 0, 0, 1]
	if ps.size() == 1:
		var expected_x: float = 2.0 * float(ps[0].radius) + 40.0 - 4.0
		free_valid = free_valid and absf(float(ps[0].x) - expected_x) < 0.05 and _velocity(ps[0]).distance_to(Vector2(40000, 0)) < 0.02
	var free_observation: Dictionary = {"particles": ps, "terrain": terrain.get("terrain", []), "consumed_delta": spent, "accounted": _accounted(before, after), "valid": free_valid}

	# With56 total travel the reflected leg reaches a friendly ball atx56.
	# Its front is pastx32, so three actual hostile cells must be paid first.
	# The ball itself never overlaps those hostile cell centres initially.
	await _reset_fixture(0)
	world.debug_command({"op": 15, "team": 1, "energy": first_cell, "count": 3})
	world.debug_command({"op": 15, "team": 1, "energy": first_cell + 4, "count": 1})
	_inject_int(0, 8, Vector2(4, 104), Vector2(-56000, 0))
	_inject_int(0, 4, Vector2(56, 104), Vector2.ZERO, 13)
	before = await _snapshot()
	await _advance(1, 0.001)
	after = await _snapshot()
	terrain = await _snapshot("terrain:%d:5" % first_cell)
	var bs: Array = after.get("balls", [])
	spent = int(after.consumed_energy) - int(before.consumed_energy)
	var feed_valid: bool = _physical_particles(after).is_empty() and bs.size() == 1 and int(bs[0].team) == 0 and int(bs[0].energy) == 9 and spent == 3 and _accounted(before, after) == 12 and terrain.get("terrain", []) == [0, 0, 0, 0, 1]
	check(free_valid and feed_valid, "普通高能同子步墙反射保速且反射余程先染格后补球", "无目标时反射终点符合总路程且40000出生速度保留；有目标时8先真实染3格，再将余5补给4能友球成9；未到达格不染、无双反射或普通弹分裂", {"free_reflection": free_observation, "reflected_feed": {"balls": bs, "particles": _physical_particles(after), "terrain": terrain.get("terrain", []), "consumed_delta": spent, "accounted": _accounted(before, after), "valid": feed_valid}})

func _test_sniper_entity_toi_order() -> void:
	await _reset_fixture(0)
	# 故意先给远处友球分配低slot；正确结果由近处敌球TOI决定，不是slot顺序。
	_inject_int(0, 30, Vector2(140, 100), Vector2.ZERO, 13)
	_inject_int(1, 4, Vector2(115, 100), Vector2.ZERO, 13)
	_inject_int(0, 10, Vector2(100, 100), Vector2(40000, 0), 12)
	var before: Dictionary = await _snapshot()
	await _advance(1, 0.001)
	var after: Dictionary = await _snapshot()
	var bs: Array = after.get("balls", [])
	check(bs.size() == 1 and int(bs[0].team) == 0 and int(bs[0].energy) == 36 and _physical_particles(after).is_empty() and _accounted(before, after) == 44, "狙击先撞最近大球、余能再补远球而非slot顺序", "10先对近敌4剩6，远友30吸收6成36；双方等消8", {"balls": bs, "particles": _physical_particles(after), "accounted": _accounted(before, after)})

func _split_territory() -> void:
	for row in range(64):
		world.debug_command({"op": 15, "team": 1, "energy": row * 64 + 32, "count": 32})
	world.flush()
	for frame in range(2): await process_frame

func _mechanical_mass(particle: Dictionary) -> float:
	var logarithm := log(1.0 + float(particle.energy)) / log(2.0)
	return 8.0 * clampf(pow(float(particle.radius) / 7.0, 2), 1.0, 144.0) + 24.0 * logarithm / (12.0 + logarithm)

func _restitution(particle: Dictionary) -> float:
	var size := clampf((float(particle.radius) - 7.0) / 35.0, 0.0, 1.0)
	var logarithm := log(1.0 + float(particle.energy)) / log(2.0)
	var hardness := clampf(1.0 - 0.55 * size - 0.25 * logarithm / (12.0 + logarithm), 0.2, 1.0)
	return 0.26 + 0.62 * hardness

func _test_ball_snapshot_impulse() -> void:
	await _reset_fixture(0)
	await _split_territory()
	_inject_int(0, 100, Vector2(500, 120), Vector2(42, 0), 13)
	_inject_int(1, 100, Vector2(520, 120), Vector2(-42, 0), 13)
	var before: Dictionary = await _snapshot()
	var original: Array = before.get("balls", [])
	await _advance(1, 0.001)
	var after: Dictionary = await _snapshot()
	var bs: Array = after.get("balls", [])
	var expected_speed: float = _restitution(original[0]) * 42.0 if original.size() == 2 else -1.0
	var valid := bs.size() == 2 and _accounted(before, after) == 200
	if bs.size() == 2:
		valid = valid and int(bs[0].energy) < 100 and int(bs[0].energy) > 0 and int(bs[0].energy) == int(bs[1].energy)
		valid = valid and absf(float(bs[0].vx) + expected_speed) < 0.01 and absf(float(bs[1].vx) - expected_speed) < 0.01
		var momentum: float = _mechanical_mass(original[0]) * float(bs[0].vx) + _mechanical_mass(original[1]) * float(bs[1].vx)
		valid = valid and absf(momentum) < 0.01
	check(valid, "敌大球部分互耗与碰前质量冲量", "独立机械公式检查反弹速度/动量；损耗后不即时拉基础速度，不全量清空小球", {"before": original, "after": bs, "expected_speed": expected_speed, "accounted": _accounted(before, after)})
	var first_loss := int(after.consumed_energy)
	await _advance(5, 0.001)
	var separated: Dictionary = await _snapshot()
	check(int(separated.consumed_energy) == first_loss, "大球连续接触不重复能量结算", "首次反弹后5个小步离开，接触锁去重", {"balls": separated.get("balls", []), "extra_consumed": int(separated.consumed_energy) - first_loss})

func _test_ball_grazing_contact() -> void:
	await _reset_fixture(0)
	_inject_int(0, 100, Vector2(490, 120), Vector2(42, 30), 13)
	_inject_int(0, 100, Vector2(509.8, 120), Vector2(-42, 30), 13)
	var before: Dictionary = await _snapshot()
	await _advance(1, 0.001)
	var after: Dictionary = await _snapshot()
	var bs: Array = after.get("balls", [])
	var valid := bs.size() == 2 and _all_energy(after) == 200 and int(after.consumed_energy) == int(before.consumed_energy)
	if bs.size() == 2:
		valid = valid and absf(float(bs[0].vy) - 30) < 0.001 and absf(float(bs[1].vy) - 30) < 0.001
		var kinetic_before := 42.0 * 42.0 + 30.0 * 30.0
		valid = valid and _velocity(bs[0]).length_squared() <= kinetic_before + 0.01 and _velocity(bs[1]).length_squared() <= kinetic_before + 0.01
	check(valid, "同阵营大球斜碰保持切向速度且不增能", "法向恢复系数小于1、切向速度不变，碰撞能量不增加", {"balls": bs})

func _test_ball_projectile_excess() -> void:
	await _reset_fixture(0)
	_inject_int(0, 50, Vector2(100, 100), Vector2(140, 0))
	_inject_int(1, 4, Vector2(107, 100), Vector2.ZERO, 13)
	var before: Dictionary = await _snapshot()
	await _advance(1, 0.001)
	var after: Dictionary = await _snapshot()
	var ps: Array = _physical_particles(after)
	check(after.get("balls", []).is_empty() and ps.size() == 1 and int(ps[0].energy) == 46 and _velocity(ps[0]).distance_to(Vector2(140, 0)) < 0.001 and _accounted(before, after) == 54, "高能普通粒子击散小大球后余能继续", "50对4只各耗4，余46不被删除或空气大球反射", {"particles": ps, "balls": after.get("balls", []), "accounted": _accounted(before, after)})

func _test_projectile_multi_ball_remainder() -> void:
	await _reset_fixture(0)
	# 故意注入高于配置上限的真实扫掠速度，覆盖fast链回退与同一步多个大球。
	_inject_int(0, 50, Vector2(100, 100), Vector2(40000, 0))
	_inject_int(1, 4, Vector2(111, 100), Vector2.ZERO, 13)
	_inject_int(1, 6, Vector2(128, 100), Vector2.ZERO, 13)
	var before: Dictionary = await _snapshot()
	await _advance(1, 0.001)
	var after: Dictionary = await _snapshot()
	var ps: Array = _physical_particles(after)
	check(after.get("balls", []).is_empty() and ps.size() == 1 and int(ps[0].energy) == 40 and _velocity(ps[0]).distance_to(Vector2(40000, 0)) < 0.01 and _accounted(before, after) == 60, "高能普通粒子同子步穿过多个被击散的大球", "50依次对4与6，余40；真实扫掠+TOI顺序不漏接触、不重复结算", {"particles": ps, "balls": after.get("balls", []), "accounted": _accounted(before, after)})

func _test_friendly_feed() -> void:
	await _reset_fixture(0)
	_inject_int(0, 10, Vector2(100, 100), Vector2(140, 0))
	_inject_int(0, 100, Vector2(110, 100), Vector2(0, 42), 13)
	var before: Dictionary = await _snapshot()
	await _advance(1, 0.001)
	var after: Dictionary = await _snapshot()
	var bs: Array = after.get("balls", [])
	check(_physical_particles(after).is_empty() and bs.size() == 1 and int(bs[0].energy) == 110 and float(bs[0].vx) > 0 and _accounted(before, after) == 110, "己方粒子被大球完整吸收并轻微推动", "球100吸收10、游离粒子消失、能量不进入已消耗账本", {"balls": bs})

func _test_ball_shield_dedup() -> void:
	await _reset_fixture(1)
	world.debug_command({"op": 10, "team": 0, "energy": 10, "gun": 0, "state": 0})
	var state: Dictionary = await _snapshot()
	var defender: Dictionary = state.teams[0]
	var radius := 7.0 + 3.0 * sqrt(1000.0 / 100.0)
	_inject_int(1, 1000, Vector2(float(defender.x) + float(defender.shield_radius) + radius - 0.1, float(defender.y)), Vector2(-42, 0), 13)
	await _advance(1, 0.001)
	var impact: Dictionary = await _snapshot()
	var bs: Array = impact.get("balls", [])
	var shield := int(impact.teams[0].shield)
	var remaining := _energy(impact, true)
	var valid := bs.size() == 1 and shield < 10 and shield >= 0 and remaining > 0 and int(impact.teams[0].state) == 0 and float(bs[0].vx) > 0
	await _advance(5, 0.001)
	var separated: Dictionary = await _snapshot()
	valid = valid and int(separated.teams[0].state) == 0 and int(separated.teams[0].shield) == shield and _energy(separated, true) == remaining
	check(valid, "大球撞盾部分消耗、去重且同触不杀核", "盾/球仍存时逐小步检查不重复扣能；若破盾同一次接触直接返回", {"after_impact": impact.get("balls", []), "shield": shield, "after_separation": separated.get("balls", [])})
	# 极小护盾必破：1点部分损耗的最小整数仍是1，不能同触直杀核心。
	await _reset_fixture(1)
	world.debug_command({"op": 10, "team": 0, "energy": 1, "gun": 0, "state": 0})
	state = await _snapshot()
	defender = state.teams[0]
	_inject_int(1, 1000, Vector2(float(defender.x) + float(defender.shield_radius) + radius - 0.1, float(defender.y)), Vector2(-42, 0), 13)
	await _advance(1, 0.001)
	var broken: Dictionary = await _snapshot()
	check(int(broken.teams[0].shield) == 0 and int(broken.teams[0].state) == 0 and _energy(broken, true) == 999, "刚破盾不能在同接触杀核心", "1盾只各扣1，大球999被实体反射，核心仍存活", {"team": broken.teams[0], "balls": broken.get("balls", [])})

func _test_explicit_ball_drive() -> void:
	world.update_settings({"ball_min_speed": 40.0})
	await _reset_fixture(0)
	_inject_int(0, 100, Vector2(100, 100), Vector2.ZERO, 13)
	await _advance(1, 0.001)
	var first: Dictionary = await _snapshot()
	var bs: Array = first.get("balls", [])
	var speed := _velocity(bs[0]).length() if bs.size() == 1 else -1.0
	check(bs.size() == 1 and speed > 0 and speed <= 0.301 and int(bs[0].energy) == 100, "大球最低移速为独立有限加速度驱动", "静止球0.001模拟秒仅增加≤0.3速度，不瞬时跳40且不消耗/增生弹药", {"balls": bs, "first_speed": speed})
	await _advance(150, 0.001)
	var driven: Dictionary = await _snapshot()
	bs = driven.get("balls", [])
	check(bs.size() == 1 and absf(_velocity(bs[0]).length() - 40) < 0.01 and int(bs[0].energy) == 100, "大球基础推进达到设定速度后停止加速", "150毫模拟秒后恰到40，独立驱动避免永久停球", {"balls": bs})
	world.update_settings({"ball_min_speed": 1.0})

func _test_zero_energy_exclusion() -> void:
	await _reset_fixture(0)
	for op in [11, 12, 13]:
		_inject_int(0, 0, Vector2(100, 100), Vector2(140, 0), int(op))
	await _advance(1, 0.001)
	var data: Dictionary = await _snapshot()
	check(_physical_particles(data).is_empty() and data.get("balls", []).is_empty(), "零能实体立即退出物理与空间系统", "零能调试注入也不会占活跃槽、碰撞或染色", {"particles": _physical_particles(data), "balls": data.get("balls", [])})

func _test_parallel_atomic_carry() -> void:
	var all_valid := true
	var rounds: Array = []
	const SMALLER := 4294967293
	const RESIDUAL := 9
	# 24游戏单位=3个空间格；32对位于同一九色相位的32个独立中心格。
	# 每格一个invocation同时向u64消费账本写低word，64次atomicAdd强制多次进位。
	for trial in range(8):
		await _reset_fixture(0)
		for pair in range(32):
			var position := Vector2(100 + (pair % 8) * 24, 100 + int(pair / 8) * 24)
			_inject_int(0, SMALLER + RESIDUAL, position, Vector2(140, 0))
			_inject_int(1, SMALLER, position + Vector2(2, 0), Vector2(-140, 0))
		var before: Dictionary = await _snapshot()
		await _advance(1, 0.001)
		var after: Dictionary = await _snapshot()
		var survivors := _physical_particles(after)
		var delta := int(after.consumed_energy) - int(before.consumed_energy)
		var valid := survivors.size() == 32 and delta == 64 * SMALLER and _accounted(before, after) == 32 * (2 * SMALLER + RESIDUAL)
		for particle: Dictionary in survivors:
			valid = valid and int(particle.energy) == RESIDUAL and int(particle.team) == 0 and _velocity(particle).distance_to(Vector2(140, 0)) < 0.001
		all_valid = all_valid and valid
		rounds.append({"trial": trial, "survivors": survivors.size(), "remaining": _energy(after), "consumed_delta": delta, "expected_consumed_delta": 64 * SMALLER, "expected_low_word_carries": ((int(before.consumed_energy) & 0xffffffff) + 64 * SMALLER) >> 32, "accounted": _accounted(before, after), "valid": valid})
	check(all_valid, "32独立格并行u64原子加法进位与唯一配对", "8轮真实GPU同相位并发；每轮32敌我对、64次消费原子加法、每轮至少63次低word进位，残余9沿原向继续", {"rounds": rounds})

func _test_dead_command_energy_accounting() -> void:
	await _reset_fixture(0)
	world.debug_command({"op": 10, "team": 0, "energy": 0, "gun": 0, "state": 2})
	var before: Dictionary = await _snapshot()
	var energies := [11, 13, 17, 19, 23]
	for kind in range(5):
		world.output(0, kind, float(energies[kind]))
	await _advance(1, 0.001)
	var rejected: Dictionary = await _snapshot()
	var consumed_delta := int(rejected.consumed_energy) - int(before.consumed_energy)
	var rejected_delta := int(rejected.metrics[28]) - int(before.metrics[28])
	var team: Dictionary = rejected.teams[0]
	var stocks_empty := int(team.shield) == 0 and int(team.gun) == 0 and int(team.sniper) == 0 and int(team.storm) == 0
	check(_all_energy(rejected) == 0 and stocks_empty and consumed_delta == 83 and rejected_delta == 5 and int(team.state) == 2, "死队拒绝五类普通输出仍完整记录83能量损耗", "左球已输出的过期命令只能记显式损耗，不能生产攻击或从总账消失；优先槽+命令环合计五条", {"consumed_delta": consumed_delta, "rejected_delta": rejected_delta, "team": team, "particles": _physical_particles(rejected), "balls": rejected.get("balls", [])})
	await _advance(8, 0.001)
	var repeated: Dictionary = await _snapshot()
	check(int(repeated.consumed_energy) == int(rejected.consumed_energy) and int(repeated.metrics[28]) == int(rejected.metrics[28]), "清优先槽与后续空刷新不重复收费", "成功命令清a.x后，8个子步及调试空flush不再增加消费或拒绝计数", {"consumed": repeated.consumed_energy, "rejected": repeated.metrics[28]})
	world.death_balls(0, [29.0])
	await _advance(1, 0.001)
	var aftermath: Dictionary = await _snapshot()
	check(_energy(aftermath, true) == 29 and aftermath.get("balls", []).size() == 1 and int(aftermath.consumed_energy) == int(rejected.consumed_energy) and int(aftermath.metrics[28]) == int(rejected.metrics[28]), "带死亡标记的29能量余波仍正常出球且不收费", "op2 death豁免拒绝分支；死亡不生产普通武器的规则保持", {"balls": aftermath.get("balls", []), "consumed": aftermath.consumed_energy, "rejected": aftermath.metrics[28]})
	var due := sim_time + 0.004
	world.output(0, 1, 31.0, due)
	await _advance(1, 0.001)
	var early: Dictionary = await _snapshot()
	check(int(early.consumed_energy) == int(rejected.consumed_energy) and world._queued.size() == 1, "未来死队命令未到期不提前计损耗", "定时31能量仍留CPU队列，不能因队伍已死而提前吞掉未来输入", {"consumed": early.consumed_energy, "queued": world._queued.size(), "due": due, "sim_time": sim_time})
	await _advance(3, 0.001)
	var timed: Dictionary = await _snapshot()
	check(int(timed.consumed_energy) - int(rejected.consumed_energy) == 31 and int(timed.metrics[28]) - int(rejected.metrics[28]) == 1 and _energy(timed, true) == 29 and world._queued.is_empty(), "定时死队命令到期仅一次计31损耗", "31在实际生效时拒绝并计账，既有29死亡余波保持，总账不重复或丢失", {"consumed_delta": int(timed.consumed_energy) - int(rejected.consumed_energy), "rejected_delta": int(timed.metrics[28]) - int(rejected.metrics[28]), "balls": timed.get("balls", []), "queued": world._queued.size()})
