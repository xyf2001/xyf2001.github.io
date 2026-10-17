extends SceneTree
## 实际主场景运行、倍速、暂停单步和资源重开检查。
## get_image 仅用于一次明确的验收截图，不参与正式战场渲染。

var scene: Node
var options: Dictionary = {}
var checks: Array[Dictionary] = []
var speed_runs: Array[Dictionary] = []
var frame_ms: Array[float] = []
var artifacts := "res://artifacts/validation-1.5/runtime"
var failed := false

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(0, args.size() - 1, 2):
		options[args[i].trim_prefix("--")] = args[i + 1]
	artifacts = str(options.get("artifact-dir", artifacts))
	DirAccess.make_dir_recursive_absolute(artifacts)
	call_deferred("run")

func check(ok: bool, title: String, details: Dictionary = {}) -> void:
	var result := {"status": "PASS" if ok else "FAIL", "name": title, "metrics": details}
	checks.append(result)
	failed = failed or not ok
	print("CHROMATIC_TEST " + JSON.stringify(result))

func frames(count: int) -> void:
	for _i in count:
		await process_frame

func capture_snapshot(data: Dictionary, context: Dictionary) -> void:
	if int(data.get("request_id", -1)) == int(context.request_id):
		context["data"] = data
		context["received"] = true

func gpu_snapshot() -> Dictionary:
	var target: GPUWorld = scene.world
	var context := {"request_id": -1, "received": false, "data": {}}
	var callback := capture_snapshot.bind(context)
	target.debug_snapshot_ready.connect(callback)
	var began := Time.get_ticks_usec()
	context.request_id = int(target.debug_readback("sample").get("request_id", -1))
	while not bool(context.received) and Time.get_ticks_usec() - began < 120000000:
		if not target.error_message.is_empty(): break
		await process_frame
	if target.debug_snapshot_ready.is_connected(callback):
		target.debug_snapshot_ready.disconnect(callback)
	if not bool(context.received): return {}
	var result: Dictionary = context.data
	result["validation_fence_wall_ms"] = float(Time.get_ticks_usec() - began) / 1000.0
	return result

func ready_world() -> bool:
	var deadline := Time.get_ticks_msec() + 240000
	while not scene.world.active or scene.world.stats.get("teams", []).size() != 4:
		if not scene.world.error_message.is_empty() or Time.get_ticks_msec() > deadline:
			return false
		await process_frame
	return true

func percentile(values: Array[float], fraction: float) -> float:
	if values.is_empty(): return -1.0
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(int(ceil(fraction * sorted.size())) - 1, 0, sorted.size() - 1)]

func run() -> void:
	var target_seconds := float(options.get("sim-seconds-per-speed", "3"))
	if not is_finite(target_seconds) or target_seconds <= 0.0:
		check(false, "主场景倍速测试参数", {"sim-seconds-per-speed":str(options.get("sim-seconds-per-speed", "3")),"required":"有限正数"})
		finish()
		return
	if RenderingServer.get_current_rendering_driver_name() != "vulkan":
		check(false, "实际主场景Vulkan前提")
		finish()
		return
	scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	if not await ready_world():
		check(false, "主场景首次启动", {"error": scene.world.error_message})
		finish()
		return
	# 用真实默认配置运行，不继承此前用户保存的调试参数。
	scene.settings = GameSettings.defaults()
	scene.settings["fps_limit"] = 0
	scene.ui.sync_editor_config(scene.settings)
	scene._restart()
	if not await ready_world():
		check(false, "默认配置重开", {"error": scene.world.error_message})
		finish()
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	scene.paused = true
	await frames(12)
	var initial: Dictionary = await gpu_snapshot()
	var initial_ok: bool = scene.pinball.balls.size() == 16 and scene.world.texture.texture_rd_rid.is_valid() and scene.battle_view.texture is Texture2DRD
	initial_ok = initial_ok and initial.get("teams", []).size() == 4
	for team: Dictionary in initial.get("teams", []):
		initial_ok = initial_ok and bool(team.alive) and int(team.shield) == 1000000
	check(initial_ok, "左右主场景、16球、四核心和GPU共享纹理", {"device": scene.world.stats.get("device", ""), "config": {"capacity": scene.settings.particle_capacity, "grid": scene.settings.grid_size, "render": scene.settings.render_size}})
	for speed in [1.0, 2.0, 4.0]:
		scene.settings["time_scale"] = speed
		scene.ui.sync_editor_config(scene.settings)
		scene.accumulator = 0.0
		var sim_start: float = scene.elapsed
		var target := target_seconds
		var began := Time.get_ticks_usec()
		var previous := began
		var first_frame := Engine.get_frames_drawn()
		frame_ms.clear()
		scene.paused = false
		while scene.elapsed - sim_start < target and Time.get_ticks_usec() - began < 240000000:
			await process_frame
			var now := Time.get_ticks_usec()
			frame_ms.append(float(now - previous) / 1000.0)
			previous = now
			if not scene.pinball.error.is_empty() or not scene.world.error_message.is_empty(): break
		scene.paused = true
		var wall_seconds := float(Time.get_ticks_usec() - began) / 1000000.0
		var measured := {"target_speed": speed, "sim_seconds": scene.elapsed - sim_start, "wall_seconds": wall_seconds, "rendered_frames": Engine.get_frames_drawn() - first_frame, "average_drawn_fps": float(Engine.get_frames_drawn() - first_frame) / maxf(wall_seconds, 0.001), "p50_frame_ms": percentile(frame_ms, 0.50), "p95_frame_ms": percentile(frame_ms, 0.95), "p99_frame_ms": percentile(frame_ms, 0.99), "one_percent_low_fps": 1000.0 / maxf(percentile(frame_ms, 0.99), 0.001), "time_backlog_sim_seconds": scene.accumulator, "active_particles": scene.world.stats.get("active_particles", -1), "gpu_ms": scene.world.stats.get("gpu_ms", -1), "overflow": scene.world.stats.get("overflow_count", -1)}
		var completed: Dictionary = await gpu_snapshot()
		measured["gpu_completed_sim_seconds"] = completed.get("sim_time", -1)
		measured["completion_fence_wall_ms"] = completed.get("validation_fence_wall_ms", -1)
		measured["active_particles"] = int(completed.get("metrics", [0])[0]) if not completed.is_empty() else -1
		measured["overflow"] = int(completed.get("metrics", [])[15]) if completed.get("metrics", []).size() > 15 else -1
		speed_runs.append(measured)
		check(scene.elapsed - sim_start >= target and scene.pinball.error.is_empty() and scene.world.error_message.is_empty() and int(measured.overflow) == 0 and float(measured.gpu_completed_sim_seconds) + scene.active_dt * 0.51 >= scene.elapsed, "主场景 %.0f倍速短程连续运行与GPU完成栅栏" % speed, measured)
		if failed: break
	# 明确的人工调试极端场景，不能冒充自然对局结果。
	for team in 4:
		scene.world.output(team, 3, 1000000.0)
		scene.world.output(team, 1, 200000.0)
		scene.world.output(team, 2, 100000.0)
	var complex_start: float = scene.elapsed
	var complex_deadline := Time.get_ticks_msec() + 240000
	scene.paused = false
	while scene.elapsed - complex_start < 1.0 and Time.get_ticks_msec() < complex_deadline:
		await process_frame
		if not scene.world.error_message.is_empty() or not scene.pinball.error.is_empty(): break
	scene.paused = true
	await frames(12)
	var complex_completed: Dictionary = await gpu_snapshot()
	var complex_valid: bool = complex_completed.get("metrics", []).size() > 15
	complex_valid = complex_valid and int(complex_completed.metrics[15]) == 0 and float(complex_completed.get("sim_time", -1)) + scene.active_dt * 0.51 >= scene.elapsed
	check(complex_valid and scene.elapsed - complex_start >= 1.0 and scene.world.error_message.is_empty() and scene.pinball.error.is_empty(), "四阵营风暴、大球和狙击同时运行", {"sim_seconds": scene.elapsed - complex_start, "gpu_completed_sim_time": complex_completed.get("sim_time", -1), "stats": scene.world.stats})
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var image_result := image.save_png(artifacts.path_join("main_scene.png"))
	check(image_result == OK and image.get_width() > 0, "真实主窗口截图", {"path": artifacts.path_join("main_scene.png")})
	var paused_time: float = scene.elapsed
	await frames(12)
	check(is_equal_approx(scene.elapsed, paused_time), "暂停冻结模拟时间")
	scene.one_step = true
	await frames(12)
	var step_completed: Dictionary = await gpu_snapshot()
	var step_metrics: Array = step_completed.get("metrics", [])
	var step_overflow := int(step_metrics[15]) if step_metrics.size() > 15 else -1
	var step_valid: bool = step_metrics.size() > 15 and step_overflow == 0 and scene.world.error_message.is_empty() and scene.pinball.error.is_empty()
	check(step_valid and absf(scene.elapsed - paused_time - scene.active_dt) < 0.000001 and float(step_completed.get("sim_time", -1)) + scene.active_dt * 0.51 >= scene.elapsed, "单步恰好一个固定时间步且GPU完成", {"sim_time_before":paused_time,"sim_time_after":scene.elapsed,"fixed_dt":scene.active_dt,"gpu_completed_sim_seconds":step_completed.get("sim_time", -1),"gpu_overflow":step_overflow,"gpu_error":scene.world.error_message,"pinball_error":scene.pinball.error,"completion_fence_wall_ms":step_completed.get("validation_fence_wall_ms", -1),"active_particles":int(step_metrics[0]) if not step_metrics.is_empty() else -1})
	var retired_worlds: Array = []
	for _i in 3:
		retired_worlds.append(scene.world)
		scene._restart()
	if await ready_world():
		scene.paused = true
		var retirement_deadline := Time.get_ticks_msec() + 120000
		while not scene.retired.is_empty() and Time.get_ticks_msec() < retirement_deadline:
			await process_frame
		var resources_ok: bool = scene.pinball.balls.size() == 16 and scene.retired.is_empty()
		for old in retired_worlds:
			if is_instance_valid(old): resources_ok = resources_ok and old.is_shutdown_complete() and old._resource_rids.is_empty()
		check(resources_ok, "连续快速重开释放旧GPU资源并复位16球", {"retired_nodes": scene.retired.size(), "new_allocated_bytes": scene.world._memory_bytes})
	else:
		check(false, "连续快速重开后恢复", {"error": scene.world.error_message})
	scene.world.shutdown()
	var release_deadline := Time.get_ticks_msec() + 120000
	while not scene.world.is_shutdown_complete() and Time.get_ticks_msec() < release_deadline:
		await process_frame
	check(scene.world.is_shutdown_complete() and scene.world.pending_readbacks == 0 and scene.world._resource_rids.is_empty(), "最终关闭释放RD资源与异步回调", {"pending_readbacks": scene.world.pending_readbacks, "release_confirmed": scene.world.resource_release_confirmed})
	finish()

func finish() -> void:
	var report := {"status": "FAIL" if failed else "PASS", "godot": Engine.get_version_info()["string"], "driver": RenderingServer.get_current_rendering_driver_name(), "physical_gpu_claim": false, "speed_runs": speed_runs, "checks": checks}
	var file := FileAccess.open(artifacts.path_join("runtime_results.json"), FileAccess.WRITE)
	if file == null:
		print("RUNTIME_VALIDATION FAIL：无法保存实际测试结果")
		quit(1)
		return
	file.store_string(JSON.stringify(report, "\t"))
	print("RUNTIME_VALIDATION " + JSON.stringify({"status": report.status, "checks": checks.size(), "artifact_dir": artifacts}))
	quit(1 if failed else 0)
