extends "res://tests/gpu_suite.gd"
## 使用GPU自身生成有实际位置/能量的满容量粒子，再运行正式空间与事件pass。
## 这是可重复的稀疏基准，不冒充拥挤战局或真实显卡60 FPS。

func run_suite() -> void:
	if RenderingServer.get_current_rendering_method() != "forward_plus" or RenderingServer.get_current_rendering_driver_name() != "vulkan":
		record("NOT TESTED", "Vulkan压力测试前提", "必须普通窗口 Forward+ / Vulkan")
		finish()
		return
	var capacities: Array[int] = [10000, 50000, 100000]
	var extra: int = int(options.get("capacity", "10000"))
	if extra > 100000:
		capacities.append(clampi(extra, 100001, 1000000))
	for capacity in capacities:
		await _benchmark(capacity)
	if extra <= 100000:
		record("NOT TESTED", "300k与1M实际活跃粒子压力", "本环境为llvmpipe软件Vulkan；请在真实显卡用 --suite stress --capacity 300000 或1000000单独执行。未运行大规模不能报告PASS")
	finish()

func _benchmark(capacity: int) -> void:
	world = World.new()
	runtime_error = ""
	sim_time = 0.0
	world.configure({"particle_capacity": capacity, "grid_size": 64, "render_size": 256, "seed": int(options.get("seed", "20261016")), "gun_start": 0.0, "gun_end": 0.0, "intro_gun": 0.0, "intro_shield": 0.0, "precision_mode": "exact"})
	world.debug_snapshot_ready.connect(_on_snapshot)
	world.failed.connect(func(message: String): runtime_error = message)
	root.add_child(world)
	world.start()
	var deadline: int = Time.get_ticks_msec() + 30000
	while not world.active and runtime_error.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if not world.active:
		record("FAIL", "%d实际活跃粒子基准" % capacity, runtime_error if not runtime_error.is_empty() else "30秒初始化超时")
		world.shutdown()
		world.queue_free()
		await process_frame
		return
	world.debug_command({"op": 16, "team": 0})
	world.debug_command({"op": 17, "team": 0})
	var filled: Dictionary = await _snapshot()
	var metrics: Array = filled.get("metrics", [])
	var initial_count: int = int(metrics[0]) if metrics.size() > 24 else -1
	check(initial_count == capacity, "%d粒子实际填满" % capacity, "由GPU测试命令生成完整实际活跃粒子，不是只分配空缓冲", {"active_particles": initial_count, "capacity": capacity})
	await _advance(2)
	var before: Dictionary = await _snapshot()
	var begin: int = Time.get_ticks_usec()
	var begin_frames: int = Engine.get_frames_drawn()
	for _step in range(12):
		await _advance()
	var final: Dictionary = await _snapshot()
	var elapsed: float = float(Time.get_ticks_usec() - begin) / 1000000.0
	var frames: int = Engine.get_frames_drawn() - begin_frames
	var end_metrics: Array = final.get("metrics", [])
	var active: int = int(end_metrics[0]) if end_metrics.size() > 24 else -1
	var energy: int = (int(end_metrics[23]) | (int(end_metrics[24]) << 32)) if end_metrics.size() > 24 else -1
	var overflow: int = int(end_metrics[15]) if end_metrics.size() > 24 else -1
	var consumed_delta: int = int(final.get("consumed_energy", 0)) - int(before.get("consumed_energy", 0))
	var data := {"capacity": capacity, "active_particles": active, "particle_energy": energy, "fixed_steps": 12, "sim_seconds": 12.0 / 120.0, "wall_seconds": elapsed, "observed_viewport_fps": float(frames) / maxf(elapsed, 0.001), "sim_steps_per_wall_second": 12.0 / maxf(elapsed, 0.001), "gpu_ms": float(world.stats.get("gpu_ms", -1.0)), "estimated_memory_mb": float(world.stats.get("memory_mb", -1.0)), "overflow_count": overflow, "max_cell_occupancy": int(end_metrics[6]) if end_metrics.size() > 6 else -1, "device": world.stats.get("device", "未知"), "scenario": "同队均匀二维点阵，真实空间/碰撞/领土/渲染pass", "hardware_fps_claim": false}
	print("GPU_BENCHMARK " + JSON.stringify(data))
	check(active == capacity and energy == capacity and consumed_delta == 0 and overflow == 0, "%d实际粒子移动/守恒/无溢出" % capacity, "12步正式GPU模拟，记录软件Vulkan实际吞吐；此稀疏基准不证明拥挤战局性能", data)
	world.shutdown()
	world.queue_free()
	await process_frame
	await process_frame
