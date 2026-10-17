extends SceneTree
## Small, real RenderingDevice regression for allocation, reclamation and live
## dispatch counts. This is a correctness fixture, not a performance benchmark.

const World = preload("res://scripts/gpu_world.gd")
var world: GPUWorld
var snapshots: Dictionary = {}
var failures: Array[String] = []
var checks := 0
var observations: Array[Dictionary] = []
var clock := 0.0
var deadline := 0

func _initialize() -> void:
	call_deferred("run")

func _check(ok: bool, description: String) -> void:
	checks += 1
	if not ok:
		failures.append(description)
		push_error("POOL: " + description)

func _snapshot() -> Dictionary:
	var kind := "sample" if int(world.settings.particle_capacity) > 4096 else "all_particles"
	var request := world.debug_readback(kind)
	var id := int(request.request_id)
	while not snapshots.has(id) and Time.get_ticks_msec() < deadline:
		await process_frame
	if not snapshots.has(id):
		_check(false, "GPU readback timed out")
		return {}
	var data: Dictionary = snapshots[id]
	snapshots.erase(id)
	return data

func _submit(commands: Array, advance: bool = false) -> Dictionary:
	for command: Dictionary in commands:
		world.debug_command(command)
	if advance:
		clock += 1.0 / 120.0
		world.step(1.0 / 120.0, clock)
	world.flush()
	return await _snapshot()

func _pool_check(data: Dictionary, expected: int, capacity: int, description: String) -> void:
	if data.is_empty():
		return
	var header: Array = data.pool_header
	observations.append({"case":description, "capacity":capacity, "expected_live":expected, "pool_header":header.duplicate(), "diagnostics":data.diagnostics.duplicate(true)})
	_check(int(header[0]) == expected, description + ": live count")
	_check(int(header[0]) + int(header[1]) + int(header[2]) == capacity, description + ": every slot belongs to exactly one pool")
	var ids: Dictionary = {}
	for particle: Dictionary in data.particles:
		_check(not ids.has(particle.id), description + ": unique live physical ID")
		ids[particle.id] = true
	if str(data.kind) != "all_particles":
		for particle: Dictionary in data.snipers:
			_check(not ids.has(particle.id), description + ": reserved ID is separate from ordinary sample")
			ids[particle.id] = true
	_check(int(data.metrics[0]) == expected, description + ": exact GPU statistics agrees with live list")
	_check(data.diagnostics.active_by_team == [expected, 0, 0, 0], description + ": live faction counts include every particle")
	var sampled: int = expected if str(data.kind) == "all_particles" else mini(64, expected - data.snipers.size()) + data.snipers.size()
	_check(ids.size() == sampled, description + ": particle table agrees with live list")
	_check(int(data.diagnostics.normal_dispatch_groups) == maxi(1, (expected + 63) / 64), description + ": indirect ordinary dispatch")
	_check(int(data.diagnostics.motion_dispatch_groups) == maxi(1, (expected + 64 + 63) / 64), description + ": indirect motion dispatch")

func run() -> void:
	deadline = Time.get_ticks_msec() + 180000
	if RenderingServer.get_current_rendering_driver_name() != "vulkan":
		_check(false, "normal Forward+ / Vulkan window required")
		_finish()
		return
	for capacity: int in [128, 4096, 1000000, 128]:
		world = World.new()
		world.configure({"particle_capacity":capacity, "grid_size":64, "render_size":256, "intro_shield":0, "intro_gun":0, "gun_rate":0, "gpu_profiling":true})
		root.add_child(world)
		world.debug_snapshot_ready.connect(func(data: Dictionary): snapshots[int(data.request_id)] = data)
		world.failed.connect(func(message: String): _check(false, message))
		world.start()
		while not world.active and world.error_message.is_empty() and Time.get_ticks_msec() < deadline:
			await process_frame
		if not world.active:
			_check(false, "GPU initialization failed")
			break
		_pool_check(await _snapshot(), 0, capacity, "initial %d" % capacity)
		var data := await _submit([{"op":17, "team":0, "count":48, "energy":19, "vx":17, "vy":11}, {"op":16, "team":0}])
		_pool_check(data, 48, capacity, "partial fixture %d" % capacity)
		if not data.is_empty():
			_check(int(data.metrics[23]) == 48 * 19, "fixture exact integer energy")
		data = await _submit([], true)
		_pool_check(data, 48, capacity, "same-step indirect motion %d" % capacity)
		if not data.is_empty():
			var particle: Dictionary = data.particles[0]
			var initial_x := 1024.0 / ceil(sqrt(48.0)) * 0.5
			_check(absf(float(particle.x) - initial_x - 17.0 / 120.0) < 0.001, "new live ID moves without a count readback or one-step delay")
		# Turning every cell hostile makes each ordinary particle claim exactly
		# one cell and leave physics during the next real GPU event pass.
		data = await _submit([{"op":16, "team":1}], true)
		_pool_check(data, 0, capacity, "reclaimed %d" % capacity)
		if not data.is_empty():
			_check(int(data.consumed_energy) == 48 * 19, "reclamation preserves consumed-energy accounting")
		# New allocations must reuse reclaimed physical IDs without duplicates.
		var commands: Array = [{"op":16, "team":0}]
		for k: int in 24:
			commands.append({"op":11, "team":0, "energy":7, "x":100 + k * 5, "y":200, "vx":30, "vy":0})
		data = await _submit(commands)
		_pool_check(data, 24, capacity, "reuse %d" % capacity)
		data = await _submit([{"op":12, "team":0, "energy":31, "x":300, "y":400, "vx":600, "vy":0}])
		_pool_check(data, 25, capacity, "sniper reserve %d" % capacity)
		if not data.is_empty():
			var reserved_snipers := 0
			for particle: Dictionary in data.snipers:
				if int(particle.type) == 2 and int(particle.id) >= capacity - 8:
					reserved_snipers += 1
			_check(reserved_snipers == 1, "reserved sniper slot is in live list")
		_pool_check(await _submit([{"op":14}]), 0, capacity, "debug reset %d" % capacity)
		if capacity == 128:
			for cycle: int in 3:
				commands = [{"op":17, "team":0, "count":120, "energy":19, "vx":17, "vy":11}]
				for k: int in 8:
					commands.append({"op":12, "team":0, "energy":31, "x":200 + k * 8, "y":400, "vx":600, "vy":0})
				data = await _submit(commands)
				_pool_check(data, 128, capacity, "fill ordinary and reserved %d" % cycle)
				if not data.is_empty():
					_check(int(data.pool_header[1]) == 0 and int(data.pool_header[2]) == 0, "both free stacks exhausted independently")
					_check(data.snipers.size() == 8, "all eight sniper reserve slots remain usable")
					_check(int(data.metrics[23]) == 120 * 19 + 8 * 31, "full pool energy exact")
				_pool_check(await _submit([{"op":14}]), 0, capacity, "repeated reclaim %d" % cycle)
		if capacity == 1000000:
			data = await _submit([{"op":17, "team":0, "count":1000, "energy":1, "vx":17, "vy":11}])
			_pool_check(data, 1000, capacity, "one million capacity only one thousand active")
			_pool_check(await _submit([{"op":14}]), 0, capacity, "large pool reset")
		world.shutdown()
		var release_deadline := Time.get_ticks_msec() + 90000
		while not world.is_shutdown_complete() and Time.get_ticks_msec() < release_deadline:
			await process_frame
		_check(world.is_shutdown_complete(), "render-thread resources and outstanding async reads released before node disposal")
		world.queue_free()
		await process_frame
		await process_frame
		if not failures.is_empty():
			break
	_finish()

func _finish() -> void:
	var output := "res://artifacts/pool_integrity_suite.json"
	var arguments := OS.get_cmdline_user_args()
	var output_index := arguments.find("--json")
	if output_index >= 0 and output_index + 1 < arguments.size():
		output = arguments[output_index + 1]
	else:
		var artifact_index := arguments.find("--artifact-dir")
		if artifact_index >= 0 and artifact_index + 1 < arguments.size():
			output = arguments[artifact_index + 1].path_join("pool_integrity_suite.json")
	if checks <= 0:
		failures.append("No physical pool checks executed")
	var result := {"checks":checks, "failures":failures, "failed":not failures.is_empty(), "backend":RenderingServer.get_current_rendering_driver_name(), "fixture_not_benchmark":true, "cases":observations, "artifact_path":output}
	var file := FileAccess.open(output, FileAccess.WRITE)
	var saved := false
	if file != null:
		file.store_string(JSON.stringify(result, "\t"))
		file.flush()
		saved = file.get_error() == OK
		file.close()
	if not saved:
		failures.append("Pool evidence could not be opened, written and flushed: " + output)
		result["failed"] = true
		push_error(failures.back())
	print("GPU_POOL_SUITE " + JSON.stringify(result))
	var passed := checks > 0 and failures.is_empty() and saved
	print("CHROMATIC_TEST " + JSON.stringify({"status":"PASS" if passed else "FAIL", "name":"GPU pool allocation/reclamation/indirect regression", "detail":"Aggregate of real per-entity checks; raw observations retained", "metrics":{"checks":checks,"failures":failures.size(),"observations":observations.size(),"artifact_saved":saved,"path":output}}))
	quit(0 if passed else 1)
