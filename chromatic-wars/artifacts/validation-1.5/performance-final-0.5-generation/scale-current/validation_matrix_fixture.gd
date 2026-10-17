extends SceneTree
## 同一夹具可复制至冻结baseline运行。只上传初始条件，所有后续物理由正式GPU执行。
## 不读整池：每批4字节异步完成栅栏，初末读取正式sample小表。
const Settings = preload("res://scripts/game_settings.gd")
const Rules = preload("res://scripts/gpu_collisions.gd")

class MatrixWorld extends GPUWorld:
	var fixture: PackedByteArray
	var fixture_count := 0
	var batch_id := 0
	var pass_id := 0
	var stamp_cache: Dictionary = {}
	var completed_fences: Dictionary = {}
	var submissions: Dictionary = {}
	func install_fixture_rd(bytes: PackedByteArray, count: int) -> void:
		_rd.buffer_update(_buffers[0], 0, bytes.size(), bytes)
		if has_method("_debug_rebuild_pool_rd"):
			call("_debug_rebuild_pool_rd", count)
		_metrics_dirty_rd = true
	func _execute_rd(generation_id: int, batch: Array, upload: Array, rescues: Array, tail: int, request_stats: bool) -> void:
		var began := Time.get_ticks_usec()
		var measured := not batch.is_empty()
		if measured:
			batch_id += 1
			pass_id = 0
			_rd.capture_timestamp("M_%d_TOTAL_S" % batch_id)
		super._execute_rd(generation_id, batch, upload, rescues, tail, request_stats)
		if measured:
			_rd.capture_timestamp("M_%d_TOTAL_E" % batch_id)
			call_deferred("_submit_main", batch_id, float(Time.get_ticks_usec() - began) / 1000.0)
	func _dispatch(list: int, mode: int, elements: int, color: int, tail: int, dt: float, sim_time: float, flags: int = 0) -> void:
		var label := "M_%d_P%d-%d" % [batch_id, pass_id, mode]
		pass_id += 1
		_rd.capture_timestamp(label + "_S")
		super._dispatch(list, mode, elements, color, tail, dt, sim_time, flags)
		_rd.capture_timestamp(label + "_E")
	func _submit_main(id: int, elapsed: float) -> void:
		submissions[id] = elapsed
	func fence_rd(id: int) -> void:
		_rd.buffer_get_data_async(_buffers[6], _fence_callback.bind(id), 0, 4)
	func _fence_callback(_bytes: PackedByteArray, id: int) -> void:
		call_deferred("_fence_main", id)
	func _fence_main(id: int) -> void:
		completed_fences[id] = true
	func collect_rd() -> void:
		var captures: Array = []
		for index in _rd.get_captured_timestamps_count():
			var label := _rd.get_captured_timestamp_name(index)
			if label.begins_with("M_"):
				captures.append([label, _rd.get_captured_timestamp_gpu_time(index)])
		if not captures.is_empty(): call_deferred("_capture_main", captures)
	func _capture_main(captures: Array) -> void:
		for capture: Array in captures:
			stamp_cache[capture[0]] = int(capture[1])

var options: Dictionary = {}
var world: MatrixWorld
var snapshots: Dictionary = {}
var runtime_error := ""
var results: Array = []
var failed := false
var deadline := 0
var sim_time := 0.0
var frame_times: Array = []
var last_frame_us := 0
var sampling := false

func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i + 1 < argv.size():
		options[argv[i].trim_prefix("--")] = argv[i+1]
		i += 2
	call_deferred("run")

func _process(_delta: float) -> bool:
	var now := Time.get_ticks_usec()
	if sampling and last_frame_us > 0: frame_times.append(float(now - last_frame_us) / 1000.0)
	last_frame_us = now
	return false

func run() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	if RenderingServer.get_current_rendering_method() != "forward_plus" or RenderingServer.get_current_rendering_driver_name() != "vulkan":
		failed = true
		print("MATRIX_ERROR Vulkan normal window required")
		finish()
		return
	var cases: String = str(options.get("cases", "uniform:1000:10000,uniform:10000:10000,uniform:1000:100000,uniform:10000:100000,uniform:1000:1000000,uniform:10000:1000000,uniform:5000:10000,uniform:30000:30000,uniform:50000:50000,uniform:100000:100000,dense_crossing:1000:10000,fast_sniper:1000:10000,four_storm:1000:10000"))
	for specification: String in cases.split(","):
		var parts := specification.split(":")
		if parts.size() != 3:
			failed = true
			continue
		await benchmark(parts[0], int(parts[1]), int(parts[2]))
	finish()

func finish() -> void:
	var data := {"version":2,"project_version":ProjectSettings.get_setting("application/config/version", "unknown"),"driver":RenderingServer.get_current_rendering_driver_name(),"fixture":"deterministic initial state upload, production compute thereafter","fixture_not_real_battle":true,"production_telemetry_suppressed_during_samples":true,"stats_readback_initial_final_only":true,"sample_fence_bytes":4,"physical_gpu_claim":false,"affinity_expected":"0-3","LP_NUM_THREADS":OS.get_environment("LP_NUM_THREADS"),"throughput_note":"completed_fixed_steps_per_wall_second = measured sample count / entire measured wall interval including timestamp collection frames; median_batch_completion_rate_per_wall_second separately inverts batch p50", "fps_note":"drawn FPS includes async fence wait; completed fixed-step throughput separately reported; software Vulkan is not RTX 5060 Ti performance","candidate_note":"baseline has no candidate counter; unavailable values are null","counter_scope":"particle-pair and big-contact candidates/confirmed contacts (including sniper-kind-big); excludes complete wall/terrain-DDA and shield/core geometry query counts","explicit_blocking_gpu_sync_calls":0,"driver_internal_cpu_wait_ms":null,"completion_fence_wait_note":"wall time includes asynchronous queueing and frame scheduling, not exact CPU blocked-on-GPU time","physical_vram_bytes":null,"physical_vram_note":"RenderingDevice allocations are not measured VRAM residency","profiling_enabled":str(options.get("profiling","false"))=="true","sampling_note":"1%low comes from actual drawn frame intervals; sample count is reported, not a hardware FPS guarantee","failed":failed,"results":results}
	var path: String = str(options.get("json", "res://artifacts/validation/matrix.json"))
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data,"\t"))
		file.flush()
		if file.get_error()!=OK:failed=true
		file.close()
	else: failed = true
	print("MATRIX_COMPLETE " + JSON.stringify({"failed":failed,"cases":results.size(),"json":path}))
	quit(1 if failed else 0)

func expired() -> bool:
	return Time.get_ticks_msec() >= deadline or not runtime_error.is_empty()

func snapshot() -> Dictionary:
	var request: Dictionary = world.debug_readback("sample")
	var id := int(request.get("request_id", -1))
	while not snapshots.has(id) and not expired():
		RenderingServer.call_on_render_thread(world.collect_rd)
		await process_frame
	if not snapshots.has(id): return {}
	var value: Dictionary = snapshots[id]
	snapshots.erase(id)
	return value

func percentile(values: Array, fraction: float) -> float:
	if values.is_empty(): return -1.0
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[clampi(int(ceil(sorted.size()*fraction))-1,0,sorted.size()-1)])

func fixture_bytes(count: int, scenario: String, radius: float) -> PackedByteArray:
	var bytes := PackedByteArray()
	bytes.resize(count * 64)
	var columns := int(ceil(sqrt(float(count))))
	var extent := 128.0 if scenario == "dense_crossing" else 1024.0
	var spacing := extent / float(columns)
	for i in count:
		var pos := Vector2((float(i%columns)+0.5)*spacing,(float(i/columns)+0.5)*spacing)
		if scenario == "dense_crossing": pos += Vector2(448.0,448.0)
		pos = pos.clamp(Vector2(radius+0.01,radius+0.01),Vector2(1023.99-radius,1023.99-radius))
		var team := 0 if scenario in ["uniform","uniform140"] else i % 4
		if scenario == "four_storm":
			var local_columns := int(ceil(sqrt(ceil(float(count)/4.0))))
			var local_spacing := 512.0/float(local_columns)
			var local_index := i/4
			pos = Vector2((float(local_index%local_columns)+0.5)*local_spacing,(float(local_index/local_columns)+0.5)*local_spacing)+Vector2(float(team%2)*512.0,float(team/2)*512.0)
		var velocity := Vector2(30.0,17.0)
		if scenario == "uniform140": velocity = velocity.normalized()*140.0
		var type := 1
		if scenario == "dense_crossing": velocity = (Vector2(512,512)-pos).normalized()*140.0
		if scenario == "fast_sniper":
			type = 2
			velocity = Vector2(2000.0 if i%2==0 else -2000.0,0.0)
		var offset := i * 64
		for pair: Array in [[0,pos.x],[4,pos.y],[8,velocity.x],[12,velocity.y],[32,radius],[36,velocity.length()],[40,pos.x],[44,pos.y]]:
			bytes.encode_float(offset+int(pair[0]),float(pair[1]))
		bytes.encode_u32(offset+16,1)
		bytes.encode_u32(offset+24,team)
		bytes.encode_u32(offset+28,type)
		bytes.encode_u32(offset+52,i*241+17)
	return bytes

func benchmark(scenario: String, count: int, capacity: int) -> void:
	var case_began:=Time.get_ticks_usec()
	deadline = Time.get_ticks_msec() + int(options.get("case-timeout","120"))*1000
	runtime_error = ""
	snapshots.clear()
	sim_time = 0.0
	world = MatrixWorld.new()
	var config := Settings.defaults()
	config.merge({"particle_capacity":capacity,"grid_size":512,"render_size":768,"gun_rate":0.0,"gun_target_switch_cd":0.5,"gun_start":0.0,"gun_end":0.0,"intro_gun":0.0,"intro_shield":0.0,"initial_gun":0.0,"initial_shield":0.0,"precision_mode":"exact","packet_energy":1,"fps_limit":0,"seed":20261016,"gpu_profiling":str(options.get("profiling","false"))=="true","time_scale":1.0,"storm_ring_particles":360},true)
	if scenario == "fast_sniper": config["sniper_speed"] = 2000.0
	world.configure(config)
	world.debug_snapshot_ready.connect(func(data:Dictionary): snapshots[int(data.get("request_id",-1))]=data)
	world.failed.connect(func(message:String): runtime_error=message)
	root.add_child(world)
	var view := TextureRect.new()
	view.position = Vector2(16,16)
	view.size = Vector2(768,768)
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.texture = world.texture
	root.add_child(view)
	world.start()
	while not world.active and not expired(): await process_frame
	var uniform_scene := scenario in ["uniform","uniform140"]
	var initial_velocity := Vector2(30.0,17.0).normalized()*140.0 if scenario=="uniform140" else Vector2(30.0,17.0)
	var output := {"scenario":scenario,"strict_same_workload_expected":uniform_scene,"initial_normal_velocity_xy": [initial_velocity.x,initial_velocity.y] if uniform_scene else null,"initial_normal_speed":initial_velocity.length() if uniform_scene else null,"requested_active_is_initial_fixture":true,"requested_active":count,"capacity":capacity,"config":config,"effective_config":world.settings.duplicate(true),"status":"FAIL","samples":[],"reason":""}
	if world.active:
		if scenario != "four_storm": world.debug_command({"op":16,"team":0})
		if uniform_scene:
			for team in range(1,4): world.debug_command({"op":10,"team":team,"energy":0,"gun":0,"state":2})
		world.flush()
		RenderingServer.call_on_render_thread(world.install_fixture_rd.bind(fixture_bytes(count,scenario,float(world.settings.particle_radius)),count))
		var initial := await snapshot()
		output["initial"] = small_state(initial)
		output["initialization_and_fixture_completion_wall_ms"]=float(Time.get_ticks_usec()-case_began)/1000.0
		if not initial.is_empty() and int(initial.metrics[0]) == count:
			if scenario == "four_storm":
				for team in 4: world.output(team,3,1080.0)
			var sample_count := int(options.get("samples","60"))
			var warmup := int(options.get("warmup","10"))
			var dt := 1.0/120.0
			var frames_start := Engine.get_frames_drawn()
			var wall_start := Time.get_ticks_usec()
			frame_times.clear()
			last_frame_us = 0
			sampling = false
			for sample_index in sample_count+warmup:
				if sample_index == warmup:
					frames_start = Engine.get_frames_drawn()
					wall_start = Time.get_ticks_usec()
					frame_times.clear()
					last_frame_us = 0
					sampling = true
				if expired(): break
				var began := Time.get_ticks_usec()
				var enqueue_start := Time.get_ticks_usec()
				sim_time += dt
				world.step(dt,sim_time)
				world._stats_clock = -1000000.0
				world.flush()
				var enqueue_ms := float(Time.get_ticks_usec()-enqueue_start)/1000.0
				var id := sample_index+1
				RenderingServer.call_on_render_thread(world.fence_rd.bind(id))
				var wait_start := Time.get_ticks_usec()
				while not world.completed_fences.has(id) and not expired():
					RenderingServer.call_on_render_thread(world.collect_rd)
					await process_frame
				var wall_ms := float(Time.get_ticks_usec()-began)/1000.0
				var wait_ms := float(Time.get_ticks_usec()-wait_start)/1000.0
				if not world.completed_fences.has(id): break
				# Await just one frame so captured GPU tags can enter main-thread cache.
				RenderingServer.call_on_render_thread(world.collect_rd)
				await process_frame
				if sample_index >= warmup:
					output.samples.append({"id":id,"wall_ms":wall_ms,"enqueue_cpu_ms":enqueue_ms,"completion_fence_wait_wall_ms":wait_ms,"render_thread_submit_cpu_ms":world.submissions.get(id,null),"stages":stage_times(id),"fixed_steps":1,"gpu_substeps":Rules.substep_count(dt,world.settings)})
			sampling = false
			var wall_seconds := float(Time.get_ticks_usec()-wall_start)/1000000.0
			output["drawn_frames"] = Engine.get_frames_drawn()-frames_start
			output["drawn_fps_average"] = float(output.drawn_frames)/maxf(wall_seconds,0.001)
			output["frame_time_p50_ms"] = percentile(frame_times,0.5)
			output["frame_time_p95_ms"] = percentile(frame_times,0.95)
			output["frame_time_p99_ms"] = percentile(frame_times,0.99)
			var slow := frame_times.duplicate()
			slow.sort()
			var slow_count := maxi(1,int(ceil(slow.size()*0.01)))
			var slow_sum := 0.0
			for value in slow.slice(maxi(0,slow.size()-slow_count)): slow_sum += float(value)
			output["drawn_fps_1pct_low"] = float(slow_count)*1000.0/maxf(slow_sum,0.001)
			output["wall_seconds_measured_excluding_warmup"] = wall_seconds
			output["warmup_fixed_steps_excluded"] = warmup
			output["frame_time_sample_count"] = frame_times.size()
			output["final"] = small_state(await snapshot())
			output["profiled_fixed_steps_including_warmup"] = warmup+sample_count
			if output.initial.get("candidate_count")!=null and output.final.get("candidate_count")!=null:
				output["collision_candidate_delta"] = int(output.final.candidate_count)-int(output.initial.candidate_count)
				output["actual_contact_delta"] = int(output.final.contact_count)-int(output.initial.contact_count)
			else:
				output["collision_candidate_delta"] = null
				output["actual_contact_delta"] = null
			output["allocated_resource_bytes"] = world._memory_bytes
			output["physical_vram_bytes"] = null
			output["device"] = world.stats.get("device","unknown")
			var completed: bool = output.samples.size()==sample_count
			var uniform_valid := not uniform_scene or (int(output.final.get("active",-1))==count and int(output.final.get("normal_energy",-1))==count)
			var expected_accounted:=count+(4320 if scenario=="four_storm" else 0)
			var energy_valid:bool=int(output.final.get("accounted_energy",-1))==expected_accounted
			output["expected_accounted_energy"]=expected_accounted
			output["integer_conservation_valid"]=energy_valid
			output["status"] = "PASS" if completed and uniform_valid and energy_valid and runtime_error.is_empty() else "FAIL"
			output["reason"] = "" if output.status=="PASS" else "timeout, invalid count/energy, or runtime error: "+runtime_error
			var walls: Array = []
			for sample: Dictionary in output.samples: walls.append(sample.wall_ms)
			output["step_batch_p50_ms"] = percentile(walls,0.5)
			output["step_batch_p95_ms"] = percentile(walls,0.95)
			output["median_batch_completion_rate_per_wall_second"] = 1000.0/maxf(percentile(walls,0.5),0.001)
			output["completed_fixed_steps_per_wall_second"] = float(output.samples.size())/maxf(wall_seconds,0.001)
		else: output["reason"] = "Fixture not established: "+JSON.stringify(small_state(initial))
	else: output["reason"] = "Initialization failed: "+runtime_error
	if output.status!="PASS": failed=true
	results.append(output)
	print("MATRIX_CASE " + JSON.stringify(output))
	print("CHROMATIC_TEST " + JSON.stringify({"status":output.status,"name":"GPU matrix %s active=%d capacity=%d" % [scenario,count,capacity],"detail":output.reason,"metrics":{"path":"matrix.json","samples":output.samples.size()}}))
	world.shutdown()
	if world.has_method("is_shutdown_complete"):
		var release_deadline:=Time.get_ticks_msec()+90000
		while not bool(world.call("is_shutdown_complete")) and Time.get_ticks_msec()<release_deadline:await process_frame
		if not bool(world.call("is_shutdown_complete")):
			failed=true
			print("CHROMATIC_TEST "+JSON.stringify({"status":"FAIL","name":"matrix GPU shutdown","detail":"90秒仍有pending读回，不提前释放"}))
			return
	world.queue_free()
	view.queue_free()
	for i in 4: await process_frame

func small_state(data: Dictionary) -> Dictionary:
	var reserve:=0
	var big_energy:=0
	for team:Dictionary in data.get("teams",[]):reserve+=int(team.get("gun",0))+int(team.get("storm",0))+int(team.get("sniper",0))+int(team.get("shield",0))
	for ball:Dictionary in data.get("balls",[]):big_energy+=int(ball.get("energy",0))
	var metrics: Array = data.get("metrics",[])
	if metrics.size()<29: return {}
	return {"active":int(metrics[0]),"normal_energy":int(metrics[23])|(int(metrics[24])<<32),"reserve_energy":reserve,"big_energy":big_energy,"accounted_energy":(int(metrics[23])|(int(metrics[24])<<32))+reserve+big_energy+int(data.get("consumed_energy",0)),"collisions_metric":int(metrics[2]),"candidate_count":data.get("diagnostics",{}).get("collision_candidates",null) if bool(data.get("diagnostics",{}).get("profiling_enabled",false)) else null,"contact_count":data.get("diagnostics",{}).get("actual_contacts",null) if bool(data.get("diagnostics",{}).get("profiling_enabled",false)) else null,"overflow":int(metrics[15]),"max_cell_occupancy":int(metrics[6]),"consumed_energy":data.get("consumed_energy",0),"sim_time":data.get("sim_time",0),"diagnostics":data.get("diagnostics",{})}

func stage_times(id: int) -> Dictionary:
	var prefix := "M_%d_" % id
	var sums: Dictionary = {}
	var matched := 0
	for key: String in world.stamp_cache:
		if not key.begins_with(prefix) or not key.ends_with("_S"): continue
		var end := key.trim_suffix("_S")+"_E"
		if not world.stamp_cache.has(end): continue
		var elapsed := float(int(world.stamp_cache[end])-int(world.stamp_cache[key]))/1000000.0
		if elapsed < 0.0: continue
		var stage := key.trim_prefix(prefix).trim_suffix("_S")
		if stage.begins_with("P"): stage = "mode_"+stage.split("-")[1]
		sums[stage] = float(sums.get(stage,0.0))+elapsed
		matched += 1
	return {"available":matched>0,"matched_timestamp_pairs":matched,"gpu_ms_by_mode":sums,"mode_1":"prepare commands and weapons","mode_7":"statistics (outside timed samples)","mode_3":"space reset","mode_4":"space index build","mode_5":"colored collision","mode_6":"serial events and big contacts","mode_2":"motion","mode_8_9_10":"render background particles composite","mode_11_12":"active ID compaction and indirect group maintenance"}
