extends SceneTree
## 可复现吞吐夹具：GPU生成/保存粒子权威状态，仅小表异步读回作为完成栅栏。
## 它不是真实游戏平衡长局；显示帧率与固定模拟步吞吐分别报告。
const World = preload("res://scripts/gpu_world.gd")
const Settings = preload("res://scripts/game_settings.gd")

class BenchmarkWorld extends GPUWorld:
	var perf_id_base := 0
	# 独立测试标签用于绑定实际batch，禁止复用游戏界面的上一批GPU计时缓存。
	func _execute_rd(generation_id: int, batch: Array, upload: Array, rescues: Array, tail: int, request_stats: bool) -> void:
		var timed := not batch.is_empty() and generation_id == _generation and _rd != null and _pipeline.is_valid()
		var id := perf_id_base + int(round(float(batch.back().y) * 120.0)) if timed else -1
		if timed: _rd.capture_timestamp("PERF_BATCH_%d_START" % id)
		super._execute_rd(generation_id, batch, upload, rescues, tail, request_stats)
		if timed: _rd.capture_timestamp("PERF_BATCH_%d_END" % id)

var world
var snapshots: Dictionary = {}
var options: Dictionary = {}
var runtime_error := ""
var sim_time := 0.0
var deadline := 0
var results: Array = []
var failed := false
var timestamp_cache: Dictionary = {}

func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i + 1 < argv.size():
		options[argv[i].trim_prefix("--")] = argv[i + 1]
		i += 2
	call_deferred("run")

func run() -> void:
	Engine.max_fps = 0
	deadline = Time.get_ticks_msec() + int(options.get("timeout", "170")) * 1000
	if RenderingServer.get_current_rendering_method() != "forward_plus" or RenderingServer.get_current_rendering_driver_name() != "vulkan":
		_fail("必须使用正常窗口 Forward+ / Vulkan，不能 --headless")
		_finish()
		return
	for scenario in ["sparse_64", "full_10000", "full_10000_blocked_storm_sniper", "full_10000_shields_storm_sniper"]:
		if not await benchmark(scenario):
			break
	_finish()

func _fail(message: String) -> void:
	failed = true
	print("PERF_ERROR " + message)

func _finish() -> void:
	var data := {"godot": Engine.get_version_info()["string"], "driver": RenderingServer.get_current_rendering_driver_name(), "physical_gpu_claim": false, "fixture_not_real_battle": true, "failed": failed, "results": results}
	var output: String = str(options.get("json", "res://artifacts/performance_benchmark.json"))
	var file := FileAccess.open(output, FileAccess.WRITE)
	if file == null:
		_fail("无法写入结果 " + output)
	else:
		file.store_string(JSON.stringify(data, "\t"))
		file.close()
	print("PERF_COMPLETE " + JSON.stringify({"failed": failed, "scenarios": results.size(), "json": output}))
	quit(1 if failed else 0)

func _on_snapshot(data: Dictionary) -> void:
	snapshots[int(data.get("request_id", -1))] = data

func _expired() -> bool:
	return Time.get_ticks_msec() >= deadline or not runtime_error.is_empty()

func _snapshot() -> Dictionary:
	# 调试读回排在同一RenderingServer队列中待测compute之后；回调完成才结束计时。
	var request: Dictionary = world.debug_readback("sample")
	var id: int = request.get("request_id", -1)
	while not snapshots.has(id) and not _expired():
		# 每个渲染帧都收集一次，避免完成回调之后标签已被空白帧换掉。
		RenderingServer.call_on_render_thread(_collect_timestamps_rd.bind(world))
		await process_frame
	if not snapshots.has(id):
		_fail("GPU小表异步完成等待超时/失败：" + runtime_error)
		return {}
	var data: Dictionary = snapshots[id]
	snapshots.erase(id)
	return data

func _collect_timestamps_rd(target) -> void:
	var raw: Array = []
	var rd: RenderingDevice = target._rd
	if rd == null: return
	for index in rd.get_captured_timestamps_count():
		var label := rd.get_captured_timestamp_name(index)
		if label.begins_with("PERF_BATCH_"):
			raw.append({"label": label, "gpu_ns": rd.get_captured_timestamp_gpu_time(index)})
	if not raw.is_empty(): call_deferred("_timestamps_main", raw)

func _timestamps_main(raw: Array) -> void:
	for capture: Dictionary in raw:
		var parts: PackedStringArray = str(capture.label).split("_")
		if parts.size() != 4: continue
		var id := int(parts[2])
		if not timestamp_cache.has(id): timestamp_cache[id] = {}
		timestamp_cache[id][parts[3]] = int(capture.gpu_ns)

func _timestamps(id: int) -> Dictionary:
	var local_deadline := mini(deadline, Time.get_ticks_msec() + 2000)
	while Time.get_ticks_msec() < local_deadline:
		var captures: Dictionary = timestamp_cache.get(id, {})
		if captures.has("START") and captures.has("END") and int(captures.END) >= int(captures.START):
			return {"available": true, "batch_id": id, "gpu_ms": float(int(captures.END) - int(captures.START)) / 1000000.0, "raw": captures.duplicate()}
		RenderingServer.call_on_render_thread(_collect_timestamps_rd.bind(world))
		await process_frame
	return {"available": false, "batch_id": id, "gpu_ms": -1.0, "raw": {}, "reason": "matching per-batch timestamps unavailable; cached game timing was not reused"}

func _energy(data: Dictionary) -> Dictionary:
	var metrics: Array = data.get("metrics", [])
	if metrics.size() < 29:
		return {}
	var reserve := 0
	var shield := 0
	for team: Dictionary in data.get("teams", []):
		reserve += int(team.get("gun", 0)) + int(team.get("storm", 0)) + int(team.get("sniper", 0))
		shield += int(team.get("shield", 0))
	var active := int(metrics[23]) | (int(metrics[24]) << 32)
	var consumed := int(data.get("consumed_energy", 0))
	return {"active": int(metrics[0]), "active_energy": active, "reserve": reserve, "consumed": consumed, "shield": shield, "accounted_without_shield": active + reserve + consumed, "overflow": int(metrics[15]), "gpu_time": data.get("sim_time", -1), "max_cell_occupancy": int(metrics[6])}

func _percentile(values: Array, fraction: float) -> float:
	if values.is_empty(): return -1.0
	var copy := values.duplicate()
	copy.sort()
	return float(copy[mini(copy.size()-1, int(copy.size()*fraction))])

func benchmark(scenario: String) -> bool:
	runtime_error = ""
	sim_time = 0.0
	snapshots.clear()
	timestamp_cache.clear()
	world = BenchmarkWorld.new()
	world.perf_id_base = (results.size() + 1) * 100000
	var config := Settings.defaults()
	config["particle_capacity"] = 10000
	config["grid_size"] = 512
	config["render_size"] = 768
	config["intro_gun"] = 0.0
	config["intro_shield"] = 1000000.0 if scenario.contains("shields") else 0.0
	config["gun_start"] = 0.0
	config["gun_end"] = 0.0
	config["precision_mode"] = "exact"
	config["packet_energy"] = 1
	config["fps_limit"] = 0
	world.configure(config)
	world.debug_snapshot_ready.connect(_on_snapshot)
	world.failed.connect(func(message: String): runtime_error = message)
	root.add_child(world)
	world.start()
	while not world.active and not _expired(): await process_frame
	if not world.active:
		_fail("GPU启动失败 " + runtime_error)
		return false
	world.debug_command({"op": 16, "team": 0})
	if scenario.begins_with("sparse"):
		for i in 64:
			world.debug_command({"op": 11, "team": 0, "energy": 1.0, "x": 40.0 + float(i%8)*125.0, "y": 40.0 + float(i/8)*125.0, "vx": 30.0, "vy": 17.0})
	else:
		world.debug_command({"op": 17, "team": 0})
	if scenario.contains("storm_sniper"):
		for team in 4:
			world.output(team, 3, 100000.0)
			world.output(team, 2, 100000.0)
	world.flush()
	var initial: Dictionary = await _snapshot()
	if initial.is_empty(): return false
	var initial_energy := _energy(initial)
	var expected_count := 64 if scenario.begins_with("sparse") else 10000
	var expected_energy := expected_count + (800000 if scenario.contains("storm_sniper") else 0)
	if int(initial_energy.get("active", -1)) != expected_count or int(initial_energy.get("accounted_without_shield", -1)) != expected_energy:
		_fail("夹具未实际建立 " + scenario + " " + JSON.stringify(initial_energy))
		return false
	var samples: Array = []
	var before := initial_energy
	var warmups: int = int(options.get("warmup", "2"))
	var sample_count: int = int(options.get("samples", "10"))
	var steps_per_batch: int = int(options.get("batch-steps", "1"))
	for sample_index in warmups + sample_count:
		if _expired():
			_fail("总时限已到 " + scenario)
			return false
		var begin := Time.get_ticks_usec()
		var begin_frames := Engine.get_frames_drawn()
		for step in steps_per_batch:
			sim_time += 1.0 / 120.0
			world.step(1.0 / 120.0, sim_time)
		# 复现掉帧时每批均到达0.25秒统计间隔的情况，确定性包含领土归约成本。
		world._stats_clock = 1.0
		world.flush()
		var after: Dictionary = await _snapshot()
		var wall_ms := float(Time.get_ticks_usec() - begin) / 1000.0
		var frames := Engine.get_frames_drawn() - begin_frames
		if after.is_empty(): return false
		var energy := _energy(after)
		var gpu: Dictionary = await _timestamps(world.perf_id_base + int(round(sim_time * 120.0)))
		var snapshot := {"index": sample_index - warmups, "warmup": sample_index < warmups, "wall_ms_including_small_snapshot": wall_ms, "gpu_ms": gpu.get("gpu_ms", -1), "captured_timestamps": gpu.get("raw", {}), "gpu_timestamp_available": gpu.get("available", false), "timestamp_batch_id": gpu.get("batch_id", -1), "fixed_steps": steps_per_batch, "expected_gpu_substeps": 2*steps_per_batch, "sim_steps_per_wall_second": float(steps_per_batch)*1000.0/maxf(wall_ms,0.001), "sim_seconds_per_wall_second": float(steps_per_batch)/120.0*1000.0/maxf(wall_ms,0.001), "viewport_fps_including_async_wait": float(frames)*1000.0/maxf(wall_ms,0.001), "frames_during_wait": frames, "energy": energy}
		if sample_index >= warmups:
			samples.append(snapshot)
		print("PERF_SAMPLE " + JSON.stringify({"scenario": scenario, "sample": snapshot}))
		if int(energy.get("overflow", -1)) != 0 or (not scenario.contains("shields") and int(energy.get("accounted_without_shield", -1)) != expected_energy):
			_fail("能量守恒/溢出失败 " + scenario)
			return false
		before = energy
	var walls: Array = []
	var gpu_ms: Array = []
	for sample: Dictionary in samples:
		walls.append(sample.wall_ms_including_small_snapshot)
		if float(sample.gpu_ms) >= 0.0: gpu_ms.append(sample.gpu_ms)
	var result := {"scenario": scenario, "device": world.stats.get("device", "未知"), "config": config, "fixed_dt": 1.0/120.0, "warmup_batches_excluded": warmups, "measured_batches": samples.size(), "steps_per_batch": steps_per_batch, "actual_gpu_substeps_per_fixed_step": 2, "statistics_every_batch": true, "small_snapshot_is_completion_fence": true, "strict_particle_reserve_consumption_conservation": not scenario.contains("shields"), "initial_energy": initial_energy, "final_energy": before, "median_wall_ms": _percentile(walls,0.5), "p90_wall_ms": _percentile(walls,0.9), "matched_gpu_timestamp_samples": gpu_ms.size(), "median_gpu_ms": _percentile(gpu_ms,0.5), "p90_gpu_ms": _percentile(gpu_ms,0.9), "samples": samples}
	results.append(result)
	print("PERF_SCENARIO " + JSON.stringify(result))
	world.shutdown()
	world.queue_free()
	await process_frame
	await process_frame
	return true
