extends SceneTree
## 实际四队风暴发射夹具：默认1万容量/512²领土/768²画面，真实发射至满载后采样。
## 此工具不以均匀注入替代真实风暴，也不代表RTX或Windows性能实测。
## Godot禁止在已有dispatch的compute list内捕获时间戳，因此仅分析阶段拆成独立列表。
## 拆分保留pass顺序与依赖，但改变调度成本；profile数值仅用于判断热点占比。

const Settings = preload("res://scripts/game_settings.gd")

class ProfiledWorld extends GPUWorld:
	signal profile_ready(sequence: int, data: Dictionary)
	var _profile_sequence := -1
	var _profile_dispatch_index := 0
	var _profile_results: Dictionary = {}

	func begin_profile(sequence: int) -> void:
		RenderingServer.call_on_render_thread(_begin_profile_rd.bind(sequence))

	func _begin_profile_rd(sequence: int) -> void:
		_profile_sequence = sequence
		_profile_dispatch_index = 0
		_profile_results[sequence] = {"expected": -1, "segments": {}}

	func end_profile() -> void:
		RenderingServer.call_on_render_thread(_end_profile_rd)

	func _end_profile_rd() -> void:
		if _profile_results.has(_profile_sequence):
			_profile_results[_profile_sequence]["expected"] = _profile_dispatch_index
		_profile_sequence = -1
		_cache_profile_rd()

	func request_profile(sequence: int) -> void:
		RenderingServer.call_on_render_thread(_request_profile_rd.bind(sequence))

	func _request_profile_rd(sequence: int) -> void:
		_cache_profile_rd()
		var data: Dictionary = _profile_results.get(sequence, {}).duplicate(true)
		call_deferred("_profile_ready_main", sequence, data)

	func _profile_ready_main(sequence: int, data: Dictionary) -> void:
		profile_ready.emit(sequence, data)

	func _update_timestamp() -> void:
		_cache_profile_rd()
		super._update_timestamp()

	func _cache_profile_rd() -> void:
		if _rd == null:
			return
		for index: int in _rd.get_captured_timestamps_count():
			var label: String = _rd.get_captured_timestamp_name(index)
			if not label.begins_with("CWSTORM|"):
				continue
			var parts: PackedStringArray = label.split("|")
			if parts.size() != 6:
				continue
			var sequence: int = int(parts[1])
			if not _profile_results.has(sequence):
				continue
			var dispatch_index: int = int(parts[2])
			var result: Dictionary = _profile_results[sequence]
			var segments: Dictionary = result["segments"]
			if not segments.has(dispatch_index):
				segments[dispatch_index] = {"mode": int(parts[3]), "color": int(parts[4])}
			segments[dispatch_index][parts[5]] = _rd.get_captured_timestamp_gpu_time(index)

	func _dispatch(list: int, mode: int, elements: int, color: int, tail: int, dt: float, sim_time: float, flags: int = 0) -> void:
		if _profile_sequence < 0:
			super._dispatch(list, mode, elements, color, tail, dt, sim_time, flags)
			return
		var label := "CWSTORM|%d|%d|%d|%d|" % [_profile_sequence, _profile_dispatch_index, mode, color]
		_profile_dispatch_index += 1
		# 结束调用者当前列表，独立记录本pass；最后恢复空列表以保持基类调用约定。
		_rd.compute_list_end()
		_rd.capture_timestamp(label + "start")
		var measured: int = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(measured, _pipeline)
		_rd.compute_list_bind_uniform_set(measured, _uniform_set, 0)
		super._dispatch(measured, mode, elements, color, tail, dt, sim_time, flags)
		_rd.compute_list_end()
		_rd.capture_timestamp(label + "end")
		var restored: int = _rd.compute_list_begin()
		_rd.compute_list_bind_compute_pipeline(restored, _pipeline)
		_rd.compute_list_bind_uniform_set(restored, _uniform_set, 0)

var world: ProfiledWorld
var snapshots: Dictionary = {}
var profiles: Dictionary = {}
var options: Dictionary = {}
var runtime_error := ""
var sim_time := 0.0
var deadline := 0
var failed := false
var results: Dictionary = {}

func _initialize() -> void:
	var argv: PackedStringArray = OS.get_cmdline_user_args()
	var index := 0
	while index + 1 < argv.size():
		options[argv[index].trim_prefix("--")] = argv[index + 1]
		index += 2
	call_deferred("run")

func _expired() -> bool:
	return Time.get_ticks_msec() >= deadline or not runtime_error.is_empty()

func _fail(message: String) -> void:
	failed = true
	print("STORM_PROFILE_ERROR " + message)

func _on_snapshot(data: Dictionary) -> void:
	snapshots[int(data.get("request_id", -1))] = data

func _on_profile(sequence: int, data: Dictionary) -> void:
	profiles[sequence] = data

func _snapshot() -> Dictionary:
	var request: Dictionary = world.debug_readback("sample")
	var sequence: int = int(request.get("request_id", -1))
	while not snapshots.has(sequence) and not _expired():
		await process_frame
	if not snapshots.has(sequence):
		_fail("等待小表快照失败/超时：" + runtime_error)
		return {}
	var data: Dictionary = snapshots[sequence]
	snapshots.erase(sequence)
	return data

func _profile(sequence: int) -> Dictionary:
	while not _expired():
		profiles.erase(sequence)
		world.request_profile(sequence)
		while not profiles.has(sequence) and not _expired():
			await process_frame
		var data: Dictionary = profiles.get(sequence, {})
		var segments: Dictionary = data.get("segments", {})
		var complete := int(data.get("expected", -1)) > 0 and segments.size() == int(data.get("expected", -1))
		for segment: Dictionary in segments.values():
			complete = complete and segment.has("start") and segment.has("end")
		if complete:
			return data
		await process_frame
	_fail("等待GPU分段时间戳失败/超时")
	return {}

func _energy(data: Dictionary) -> Dictionary:
	var metrics: Array = data.get("metrics", [])
	if metrics.size() < 29:
		return {}
	var reserves := 0
	var shields := 0
	for team: Dictionary in data.get("teams", []):
		reserves += int(team.get("gun", 0)) + int(team.get("storm", 0)) + int(team.get("sniper", 0))
		shields += int(team.get("shield", 0))
	var active: int = int(metrics[23]) | (int(metrics[24]) << 32)
	return {"active": int(metrics[0]), "active_energy": active, "big": int(metrics[1]), "reserves": reserves, "shields": shields, "consumed": int(data.get("consumed_energy", 0)), "overflow": int(metrics[15]), "cumulative_peak_cell_occupancy": int(metrics[6]), "sim_time": data.get("sim_time", -1), "accounted": active + reserves + shields + int(data.get("consumed_energy", 0))}

func _advance(steps: int) -> void:
	for _step: int in steps:
		sim_time += 1.0 / 120.0
		world.step(1.0 / 120.0, sim_time)
	world._stats_clock = 1.0
	world.flush()

func _profile_groups(profile: Dictionary) -> Dictionary:
	var groups := {"prepare": 0.0, "move_hash": 0.0, "collision": 0.0, "events": 0.0, "statistics": 0.0, "render": 0.0}
	var dispatches: Array = []
	for index: int in int(profile.get("expected", 0)):
		var segment: Dictionary = profile["segments"][index]
		var mode: int = int(segment["mode"])
		var duration := float(int(segment["end"]) - int(segment["start"])) / 1000000.0
		var group := "move_hash"
		if mode == 1: group = "prepare"
		elif mode == 5: group = "collision"
		elif mode == 6: group = "events"
		elif mode == 7 or mode == 11: group = "statistics"
		elif mode >= 8 and mode <= 10: group = "render"
		groups[group] += duration
		dispatches.append({"index": index, "mode": mode, "color": segment["color"], "gpu_ms": duration})
	return {"groups_gpu_ms": groups, "dispatches": dispatches}

func run() -> void:
	Engine.max_fps = 0
	deadline = Time.get_ticks_msec() + int(options.get("timeout", "90")) * 1000
	if RenderingServer.get_current_rendering_method() != "forward_plus" or RenderingServer.get_current_rendering_driver_name() != "vulkan":
		_fail("必须正常窗口Forward+/Vulkan，不能使用--headless")
		_finish()
		return
	world = ProfiledWorld.new()
	var config: Dictionary = Settings.defaults()
	config["particle_capacity"] = 10000
	config["grid_size"] = 512
	config["render_size"] = 768
	config["precision_mode"] = "exact"
	config["packet_energy"] = 1
	world.configure(config)
	world.debug_snapshot_ready.connect(_on_snapshot)
	world.profile_ready.connect(_on_profile)
	world.failed.connect(func(message: String): runtime_error = message)
	root.add_child(world)
	var view := TextureRect.new()
	view.position = Vector2(16, 16)
	view.size = Vector2(768, 768)
	view.texture = world.texture
	root.add_child(view)
	world.start()
	while not world.active and not _expired(): await process_frame
	if not world.active:
		_fail("GPU初始化失败/超时：" + runtime_error)
		_finish()
		return
	# 与真实风暴使用完全相同output API，仅绕过左侧等待时间来重复建立负载。
	for team: int in 4:
		world.output(team, 3, 100000.0)
	world.flush()
	var first: Dictionary = await _snapshot()
	if first.is_empty():
		_finish()
		return
	var initial_energy: Dictionary = _energy(first)
	var initial_accounted: int = int(initial_energy.get("accounted", -1))
	results = {"configuration": config, "fixture": "四队经正式output/prepare真实发射风暴，逐粒子模式；未使用debug粒子填充", "first_energy": initial_energy, "warmup": [], "samples": [], "profile_changes_compute_list_boundaries": true, "physical_gpu_claim": false}
	var warm_limit: int = int(options.get("warmup-batches", "40"))
	var full := false
	var last: Dictionary = initial_energy
	for warm: int in warm_limit:
		await _advance(2)
		var snapshot: Dictionary = await _snapshot()
		if snapshot.is_empty(): break
		last = _energy(snapshot)
		results["warmup"].append({"batch": warm, "fixed_steps": (warm + 1) * 2, "energy": last})
		print("STORM_WARMUP " + JSON.stringify({"batch": warm, "energy": last}))
		if int(last.get("overflow", -1)) != 0 or int(last.get("accounted", -1)) != initial_accounted:
			_fail("真实发射阶段能量不守恒/溢出")
			break
		if int(last.get("active", 0)) == 10000:
			full = true
			break
		if _expired(): break
	results["actually_reached_full_capacity"] = full
	results["before_sampling"] = last
	if not full:
		_fail("限定warmup内未实际达到10000活跃粒子；不以分配容量冒充满载")
	else:
		var count: int = int(options.get("samples", "3"))
		for sample: int in count:
			if _expired():
				_fail("采样总时限已到")
				break
			var begin: int = Time.get_ticks_usec()
			world.begin_profile(sample)
			await _advance(1)
			world.end_profile()
			var snapshot: Dictionary = await _snapshot()
			var profile: Dictionary = await _profile(sample)
			if snapshot.is_empty() or profile.is_empty(): break
			last = _energy(snapshot)
			var data: Dictionary = _profile_groups(profile)
			data["sample"] = sample
			data["wall_ms_including_snapshot_and_profile_wait"] = float(Time.get_ticks_usec() - begin) / 1000.0
			data["fixed_steps"] = 1
			data["gpu_substeps"] = 2
			data["energy"] = last
			results["samples"].append(data)
			print("STORM_PROFILE_SAMPLE " + JSON.stringify(data))
			if int(last.get("overflow", -1)) != 0 or int(last.get("accounted", -1)) != initial_accounted:
				_fail("采样阶段能量不守恒/溢出")
				break
	results["device"] = world.stats.get("device", "未知")
	results["final_energy"] = last
	_finish()

func _finish() -> void:
	results["failed"] = failed
	results["godot"] = Engine.get_version_info()["string"]
	results["driver"] = RenderingServer.get_current_rendering_driver_name()
	var path: String = str(options.get("json", "res://artifacts/storm_profile.json"))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_fail("无法写入结果：" + path)
	else:
		file.store_string(JSON.stringify(results, "\t"))
		file.close()
	print("STORM_PROFILE_COMPLETE " + JSON.stringify({"failed": failed, "json": path, "samples": results.get("samples", []).size()}))
	if world != null:
		world.shutdown()
		await process_frame
		await process_frame
	quit(1 if failed else 0)
