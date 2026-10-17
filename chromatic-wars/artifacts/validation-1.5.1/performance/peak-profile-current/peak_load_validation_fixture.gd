extends "res://tools/validation_matrix.gd"
## Independent synthetic pulse fixture. Every warmup and measured pulse restores
## the complete physical input, then runs production compute for one fixed step.
## Reset uploads and before/after statistics probes are outside TOTAL timestamps.

class PeakWorld extends MatrixWorld:
	func reset_pulse_rd(particles: PackedByteArray, count: int, territory: PackedByteArray, teams: PackedByteArray, weapons: PackedByteArray) -> void:
		# Full capacity plus big tail is cleared, including prior split children.
		_rd.buffer_update(_buffers[0], 0, particles.size(), particles)
		_debug_rebuild_pool_rd(count)
		_rd.buffer_update(_buffers[2], 0, territory.size(), territory)
		_rd.buffer_update(_buffers[1], 0, teams.size(), teams)
		_rd.buffer_update(_buffers[9], 0, weapons.size(), weapons)
		var areas := PackedByteArray()
		areas.resize(16)
		areas.encode_u32(0, int(_rt_settings.grid_size) * int(_rt_settings.grid_size))
		_rd.buffer_update(_buffers[6], 8 * 4, areas.size(), areas)
		# Per-pulse occupancy and step clock are reset; consumed energy and pair
		# counters remain cumulative so each pulse must reconcile a real delta.
		var zeroes := PackedByteArray()
		zeroes.resize(8)
		_rd.buffer_update(_buffers[6], 6 * 4, 8, zeroes)
		_rd.buffer_update(_buffers[6], 19 * 4, 4, zeroes)
		_metrics_dirty_rd = true

func run() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	if RenderingServer.get_current_rendering_method() != "forward_plus" or RenderingServer.get_current_rendering_driver_name() != "vulkan":
		failed = true
		print("PEAK_ERROR normal Forward+ / Vulkan window required")
		finish()
		return
	var specifications: String = str(options.get("cases", "dense_pulse:1000:10000,dense_pulse:5000:10000,sniper_wall_pulse:1000:10000"))
	for specification: String in specifications.split(","):
		var parts := specification.split(":")
		if parts.size() != 3:
			failed = true
			continue
		await peak_case(parts[0], int(parts[1]), int(parts[2]))
	finish()

func peak_particles(count: int, capacity: int, scenario: String, radius: float) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize((capacity + GPUWorld.BIG_CAPACITY) * GPUWorld.PARTICLE_STRIDE)
	var columns := int(ceil(sqrt(float(count))))
	for index: int in count:
		var position: Vector2
		var velocity: Vector2
		var team_id := index % 4
		var type_id := 1
		if scenario == "dense_pulse":
			var spacing := 48.0 / float(columns)
			position = Vector2(488.0, 488.0) + Vector2(float(index % columns) + 0.5, float(index / columns) + 0.5) * spacing
			velocity = (Vector2(512.0, 512.0) - position).normalized() * 140.0
			if velocity.length_squared() < 0.00001:
				velocity = Vector2(140.0, 0.0)
		else:
			# Large top/bottom margins exclude a second real wall contact after
			# the first 70/30 split; no rule is disabled to force the count.
			position = Vector2(1022.7, lerpf(64.0, 960.0, float(index) / float(maxi(count - 1, 1))))
			velocity = Vector2(2000.0, 0.0)
			team_id = 0
			type_id = 2
		var offset := index * GPUWorld.PARTICLE_STRIDE
		for pair: Array in [[0, position.x], [4, position.y], [8, velocity.x], [12, velocity.y], [32, radius], [36, velocity.length()], [40, position.x], [44, position.y]]:
			bytes.encode_float(offset + int(pair[0]), float(pair[1]))
		bytes.encode_u32(offset + 16, 100)
		bytes.encode_u32(offset + 24, team_id)
		bytes.encode_u32(offset + 28, type_id)
		bytes.encode_u32(offset + 52, 1 if type_id == 2 else index * 241 + 17)
	return bytes

func peak_teams(configuration: Dictionary) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(4 * GPUWorld.TEAM_STRIDE)
	for team_id: int in 4:
		var offset := team_id * GPUWorld.TEAM_STRIDE
		# Dead cores are omitted as targets. Synthetic particles remain live
		# and use all ordinary collision and territory rules unchanged.
		bytes.encode_u32(offset + 32, 2)
		bytes.encode_u32(offset + 44, 0xffffffff)
		bytes.encode_u32(offset + 64, 0xffffffff)
		bytes.encode_float(offset + 56, float(team_id) * TAU / 4.0)
		bytes.encode_float(offset + 80, float(configuration.get("core_%d_x" % team_id, 768.0 if team_id % 2 else 256.0)))
		bytes.encode_float(offset + 84, float(configuration.get("core_%d_y" % team_id, 768.0 if team_id >= 2 else 256.0)))
		bytes.encode_float(offset + 88, 12.0)
	return bytes

func peak_weapons() -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(GPUWorld.WEAPON_STATE_BYTES)
	var weapon_stride: int = bytes.size() / 4
	for team_id: int in 4:
		var offset := team_id * weapon_stride
		bytes.encode_u32(offset, 1)
		bytes.encode_u32(offset + 8, 0xffffffff)
		bytes.encode_float(offset + 80, 1000000.0)
	return bytes

func pulse_stages(id: int) -> Dictionary:
	var prefix := "M_%d_" % id
	var sums: Dictionary = {}
	var matched := 0
	var excluded_statistics := 0
	for key: String in world.stamp_cache:
		if not key.begins_with(prefix) or not key.ends_with("_S"):
			continue
		var end := key.trim_suffix("_S") + "_E"
		if not world.stamp_cache.has(end):
			continue
		var elapsed := float(int(world.stamp_cache[end]) - int(world.stamp_cache[key])) / 1000000.0
		if elapsed < 0.0:
			continue
		var stage := key.trim_prefix(prefix).trim_suffix("_S")
		if stage.begins_with("P"):
			stage = "mode_" + stage.split("-")[1]
		if stage == "mode_7":
			excluded_statistics += 1
			continue
		sums[stage] = float(sums.get(stage, 0.0)) + elapsed
		matched += 1
	var physics_ms := 0.0
	for mode: int in [1, 2, 3, 4, 5, 6, 11, 12]:
		physics_ms += float(sums.get("mode_%d" % mode, 0.0))
	return {"available":sums.has("TOTAL"), "matched_timestamp_pairs":matched, "gpu_ms_by_mode":sums, "physics_modes_sum_ms":physics_ms, "excluded_mode7_probe_pairs":excluded_statistics, "mode7_probe_excluded":true, "total_scope":"one production fixed-step batch, all substeps plus normal output rendering; excludes reset uploads and before/after statistics probes"}

func pulse_remaining(state: Dictionary) -> int:
	return int(state.get("normal_energy", 0)) + int(state.get("big_energy", 0)) + int(state.get("reserve_energy", 0))

func peak_state(data: Dictionary) -> Dictionary:
	var state := small_state(data)
	if state.is_empty():
		return state
	state["big_count"] = int(data.metrics[1])
	var splits := 0
	for weapon_state: Dictionary in data.get("weapons", []):
		splits += int(weapon_state.get("sniper_split_count", 0))
	state["sniper_split_count"] = splits
	return state

func pulse_delta(after: Variant, before: Variant) -> Variant:
	if after == null or before == null:
		return null
	return (int(after) - int(before)) & 0xffffffff

func one_pulse(particles: PackedByteArray, count: int, scenario: String, territory: PackedByteArray, teams: PackedByteArray, weapons: PackedByteArray) -> Dictionary:
	var began := Time.get_ticks_usec()
	RenderingServer.call_on_render_thread(Callable(world, "reset_pulse_rd").bind(particles, count, territory, teams, weapons))
	var before := peak_state(await snapshot())
	if before.is_empty():
		return {"valid":false, "reason":"pre-pulse statistics probe failed: " + runtime_error}
	var input_energy := count * 100
	if int(before.get("active", -1)) != count or pulse_remaining(before) != input_energy or int(before.get("big_count", -1)) != 0:
		return {"valid":false, "reason":"reset did not establish the full requested physical input", "initial":before}
	var dt := 1.0 / 120.0
	# The previous pulse and its probes have completed, so this value is stable
	# until the following flush enqueues exactly one nonempty production batch.
	var id := world.batch_id + 1
	var enqueue_started := Time.get_ticks_usec()
	world.step(dt, dt)
	world._stats_clock = -1000000.0
	world.flush()
	var enqueue_ms := float(Time.get_ticks_usec() - enqueue_started) / 1000.0
	# Read the actual batch ID for the fence only on the render thread after
	# queued _execute_rd, rather than adding one after flush may have run.
	RenderingServer.call_on_render_thread(_queue_peak_fence_rd)
	var wait_started := Time.get_ticks_usec()
	while not world.completed_fences.has(id) and not expired():
		RenderingServer.call_on_render_thread(world.collect_rd)
		await process_frame
	if not world.completed_fences.has(id):
		return {"valid":false, "reason":"timed pulse completion fence expired", "id":id, "initial":before}
	RenderingServer.call_on_render_thread(world.collect_rd)
	await process_frame
	var after := peak_state(await snapshot())
	var stages := pulse_stages(id)
	while not bool(stages.available) and not expired():
		RenderingServer.call_on_render_thread(world.collect_rd)
		await process_frame
		stages = pulse_stages(id)
	var consumed_delta := int(after.get("consumed_energy", -1)) - int(before.get("consumed_energy", 0))
	var remaining := pulse_remaining(after)
	var valid := not after.is_empty() and remaining + consumed_delta == input_energy and int(after.get("overflow", 1)) == 0 and bool(stages.available)
	var shape_valid := true
	if scenario == "sniper_wall_pulse":
		shape_valid = int(after.get("active", -1)) == count * 2 and remaining == input_energy and consumed_delta == 0 and int(after.get("sniper_split_count", -1)) == count and Rules.substep_count(dt, world.settings) == 6
	else:
		# Energy accounting alone could pass a quiet/empty-tail fixture. A dense
		# pulse must actually execute pair contacts and remove live entities.
		shape_valid = int(after.get("active", count)) < count and consumed_delta > 0 and int(pulse_delta(after.get("collisions_metric", 0), before.get("collisions_metric", 0))) > 0
	valid = valid and shape_valid
	return {"id":id, "valid":valid, "reason":"" if valid else "missing timestamps, integer conservation, expected single-wall split, overflow, or runtime error: " + runtime_error, "expected_input_energy":input_energy, "initial":before, "final":after, "initial_active":int(before.get("active", -1)), "final_active":int(after.get("active", -1)), "remaining_energy":remaining, "consumed_delta":consumed_delta, "integer_conservation_valid":remaining + consumed_delta == input_energy, "pulse_shape_valid":shape_valid, "collision_metric_delta":pulse_delta(after.get("collisions_metric"), before.get("collisions_metric")), "collision_candidate_delta":pulse_delta(after.get("candidate_count"), before.get("candidate_count")), "actual_contact_delta":pulse_delta(after.get("contact_count"), before.get("contact_count")), "stages":stages, "fixed_steps":1, "gpu_substeps":Rules.substep_count(dt, world.settings), "enqueue_cpu_ms":enqueue_ms, "render_thread_submit_cpu_ms":world.submissions.get(id, null), "completion_and_post_probe_wall_ms":float(Time.get_ticks_usec() - wait_started) / 1000.0, "wall_ms":float(Time.get_ticks_usec() - began) / 1000.0, "wall_scope":"includes full reset upload, pre/post statistics, async completion and timestamp collection; not normal-game FPS"}

func _queue_peak_fence_rd() -> void:
	world.fence_rd(world.batch_id)

func peak_case(scenario: String, count: int, capacity: int) -> void:
	deadline = Time.get_ticks_msec() + int(options.get("case-timeout", "600")) * 1000
	runtime_error = ""
	snapshots.clear()
	var output := {"scenario":scenario, "requested_active":count, "capacity":capacity, "status":"FAIL", "samples":[], "warmup_pulses":[], "reason":"", "fixture_not_real_battle":true, "each_pulse_reloads_input":true, "actual_input_energy_per_pulse":count * 100}
	if scenario not in ["dense_pulse", "sniper_wall_pulse"] or count < 1 or capacity < count * (2 if scenario == "sniper_wall_pulse" else 1) + 8:
		output.reason = "invalid pulse scenario/count/capacity"
		failed = true
		results.append(output)
		return
	world = PeakWorld.new()
	var configuration := Settings.defaults()
	configuration.merge({"particle_capacity":capacity, "grid_size":512, "render_size":768, "particle_radius":1.2, "particle_speed":140.0, "sniper_speed":2000.0 if scenario == "sniper_wall_pulse" else 620.0, "gun_rate":0.0, "gun_target_switch_cd":0.5, "intro_gun":0, "intro_shield":0, "initial_gun":0, "initial_shield":0, "seed":20261016, "fps_limit":0, "time_scale":1.0, "gpu_profiling":str(options.get("profiling", "false")) == "true", "friendly_particle_collisions":true}, true)
	world.configure(configuration)
	world.debug_snapshot_ready.connect(func(data: Dictionary): snapshots[int(data.get("request_id", -1))] = data)
	world.failed.connect(func(message: String): runtime_error = message)
	root.add_child(world)
	var view := TextureRect.new()
	view.position = Vector2(16, 16)
	view.size = Vector2(768, 768)
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.texture = world.texture
	root.add_child(view)
	world.start()
	while not world.active and not expired():
		await process_frame
	if world.active:
		var particles := peak_particles(count, capacity, scenario, float(world.settings.particle_radius))
		var territory := PackedByteArray()
		territory.resize(int(world.settings.grid_size) * int(world.settings.grid_size) * 4)
		var teams := peak_teams(world.settings)
		var weapons := peak_weapons()
		var reset_hash := HashingContext.new()
		reset_hash.start(HashingContext.HASH_SHA256)
		for reset_bytes: PackedByteArray in [particles, territory, teams, weapons]:
			reset_hash.update(reset_bytes)
		output["physical_reset_sha256"] = reset_hash.finish().hex_encode()
		output["reset_particle_bytes"] = particles.size()
		output["reset_territory_bytes"] = territory.size()
		output["geometry"] = {"center": [512, 512], "width":48, "height":48, "initial_velocity":"inward 140", "factions":4, "initial_overlap_is_intentional":true} if scenario == "dense_pulse" else {"x":1022.7, "y_min":64, "y_max":960, "initial_velocity":[2000, 0], "factions":1, "expected_contacts":"one right-wall touch per initial sniper; children continue later substeps"}
		var sample_count := int(options.get("samples", "20"))
		var warmup_count := int(options.get("warmup", "3"))
		var measured_start := 0
		var drawn_start := 0
		for pulse: int in sample_count + warmup_count:
			if expired():
				break
			if pulse == warmup_count:
				measured_start = Time.get_ticks_usec()
				drawn_start = Engine.get_frames_drawn()
				frame_times.clear()
				last_frame_us = 0
				sampling = true
			var sample := await one_pulse(particles, count, scenario, territory, teams, weapons)
			if pulse < warmup_count:
				output.warmup_pulses.append(sample)
			else:
				output.samples.append(sample)
			if not bool(sample.get("valid", false)):
				output.reason = str(sample.get("reason", "pulse failed"))
				break
		sampling = false
		var wall_seconds := float(Time.get_ticks_usec() - measured_start) / 1000000.0 if measured_start > 0 else 0.0
		output["drawn_frames"] = Engine.get_frames_drawn() - drawn_start if measured_start > 0 else 0
		output["drawn_fps_average"] = float(output.drawn_frames) / maxf(wall_seconds, 0.001)
		output["frame_time_sample_count"] = frame_times.size()
		output["frame_time_p50_ms"] = percentile(frame_times, 0.5)
		output["frame_time_p95_ms"] = percentile(frame_times, 0.95)
		output["frame_time_p99_ms"] = percentile(frame_times, 0.99)
		var slow := frame_times.duplicate()
		slow.sort()
		var slow_count := mini(slow.size(), maxi(1, int(ceil(slow.size() * 0.01))))
		var slow_sum := 0.0
		for value: Variant in slow.slice(maxi(0, slow.size() - slow_count)):
			slow_sum += float(value)
		output["drawn_fps_1pct_low"] = float(slow_count) * 1000.0 / maxf(slow_sum, 0.001) if slow_count > 0 else null
		var walls: Array = []
		for sample: Dictionary in output.samples:
			walls.append(float(sample.get("wall_ms", 0.0)))
		output["step_batch_p50_ms"] = percentile(walls, 0.5)
		output["step_batch_p95_ms"] = percentile(walls, 0.95)
		output["wall_seconds_measured_excluding_warmup"] = wall_seconds
		output["initial"] = output.samples[0].initial if not output.samples.is_empty() else {}
		output["final"] = output.samples.back().final if not output.samples.is_empty() else {}
		output["device"] = world.stats.get("device", "unknown")
		output["allocated_resource_bytes"] = world._memory_bytes
		output["config"] = configuration
		output["effective_config"] = world.settings.duplicate(true)
		output["status"] = "PASS" if output.samples.size() == sample_count and output.warmup_pulses.size() == warmup_count and output.reason == "" and runtime_error.is_empty() else "FAIL"
		if output.status != "PASS" and output.reason == "":
			output.reason = "timeout or incomplete pulse samples: " + runtime_error
	else:
		output.reason = "initialization failed: " + runtime_error
	if output.status != "PASS":
		failed = true
	results.append(output)
	print("PEAK_CASE " + JSON.stringify(output))
	print("CHROMATIC_TEST " + JSON.stringify({"status":output.status, "name":"GPU peak pulse %s active=%d capacity=%d" % [scenario, count, capacity], "detail":output.reason, "metrics":{"samples":output.samples.size(), "warmup":output.warmup_pulses.size()}}))
	world.shutdown()
	var release_deadline := Time.get_ticks_msec() + 90000
	while not world.is_shutdown_complete() and Time.get_ticks_msec() < release_deadline:
		await process_frame
	if not world.is_shutdown_complete():
		failed = true
		print("PEAK_ERROR pending readbacks or GPU resource release did not finish")
		return
	world.queue_free()
	view.queue_free()
	for index: int in 4:
		await process_frame

func finish() -> void:
	var report := {"version":3, "fixture_schema_version":3, "intended_current_rule_version":"1.5.1-energy-magazine", "comparison_note":"current-rule peak and integer-ledger validation only; historical cost-rule peak is not a same-rules optimization baseline", "project_version":ProjectSettings.get_setting("application/config/version", "unknown"), "driver":RenderingServer.get_current_rendering_driver_name(), "fixture_not_real_battle":true, "physical_gpu_claim":false, "fixture":"full-capacity reset before every synthetic peak pulse; production compute after reset", "reset_outside_TOTAL":true, "statistics_probes_outside_TOTAL":true, "mode7_probe_excluded_from_stage_sums":true, "consumed_energy_preserved_between_pulses":true, "normal_game_fps_claim":false, "fps_note":"drawn FPS and wall times include full reset uploads and pre/post probes; they are synthetic harness rates, not normal-game FPS", "profiling_enabled":str(options.get("profiling", "false")) == "true", "candidate_note":"null when optional counters are off; pair/confirmed counters use uint32 modulo deltas", "LP_NUM_THREADS":OS.get_environment("LP_NUM_THREADS"), "physical_vram_bytes":null, "failed":failed, "results":results}
	var path: String = str(options.get("json", "res://artifacts/validation/peak-load.json"))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		failed = true
	else:
		file.store_string(JSON.stringify(report, "\t"))
		file.flush()
		if file.get_error() != OK:
			failed = true
		file.close()
	print("PEAK_COMPLETE " + JSON.stringify({"failed":failed, "cases":results.size(), "json":path}))
	quit(1 if failed else 0)
