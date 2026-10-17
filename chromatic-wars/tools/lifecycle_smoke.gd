extends "res://tests/test_harness.gd"
## 实际GPU读回完成后暂缓回调归还，显式制造比固定8帧更晚的旧代回调。
## 这是生命周期夹具；不替代正常分辨率对局或性能基准。

class RetirementProbe extends GPUWorld:
	var hold_callbacks := false
	var held_callbacks: Array[Dictionary] = []
	var held_seen := false
	var timestamp_updates := 0

	func arm_probe_rd() -> void:
		hold_callbacks = true
		_schedule_stats_read(_generation)
		_debug_read_rd(_generation, "sample", 991)

	func _read_part(bytes: PackedByteArray, key: String, combined: Dictionary) -> void:
		if hold_callbacks:
			held_callbacks.append({"bytes":bytes,"key":key,"combined":combined})
			call_deferred("mark_held_main")
		else:
			super._read_part(bytes, key, combined)

	func mark_held_main() -> void:
		held_seen = true

	func release_probe_rd() -> void:
		hold_callbacks = false
		var callbacks := held_callbacks.duplicate()
		held_callbacks.clear()
		for entry: Dictionary in callbacks:
			super._read_part(entry.bytes, entry.key, entry.combined)

	func _update_timestamp() -> void:
		timestamp_updates += 1
		super._update_timestamp()

var old_events := 0
var snapshots: Dictionary = {}

func wait_active(world: GPUWorld) -> bool:
	var deadline := Time.get_ticks_msec() + 90000
	while not world.active and world.error_message.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	return world.active

func wait_released(world: GPUWorld) -> bool:
	var deadline := Time.get_ticks_msec() + 90000
	while not world.is_shutdown_complete() and Time.get_ticks_msec() < deadline:
		await process_frame
	return world.is_shutdown_complete()

func snapshot(world: GPUWorld) -> Dictionary:
	var request := world.debug_readback("sample")
	var id := int(request.request_id)
	var deadline := Time.get_ticks_msec() + 90000
	while not snapshots.has(id) and world.error_message.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	return snapshots.get(id, {})

func run_suite() -> void:
	if RenderingServer.get_current_rendering_driver_name() != "vulkan" or RenderingServer.get_current_rendering_method() != "forward_plus":
		record("NOT TESTED", "GPU异步生命周期前提", "需要实际 Forward+ / Vulkan 窗口")
		finish()
		return
	var config := GameSettings.defaults()
	config.merge({"particle_capacity":64,"grid_size":64,"render_size":256,"gun_rate":0.0}, true)
	var old := RetirementProbe.new()
	root.add_child(old)
	old.configure(config)
	old.stats_updated.connect(func(_data: Dictionary): old_events += 1)
	old.debug_snapshot_ready.connect(func(_data: Dictionary): old_events += 1)
	old.start()
	if not check(await wait_active(old), "退役夹具GPU启动", old.error_message):
		old.shutdown()
		await wait_released(old)
		finish()
		return
	old.step(1.0 / 120.0, 1.0 / 120.0)
	old.flush()
	RenderingServer.call_on_render_thread(old.arm_probe_rd)
	var deadline := Time.get_ticks_msec() + 90000
	while not old.held_seen and Time.get_ticks_msec() < deadline:
		await process_frame
	check(old.held_seen and old.pending_readbacks > 0, "真实读回回调处于待归还状态", "实际GPU回读后由测试夹具延迟派发，不伪造GPU数据", {"pending":old.pending_readbacks})
	var generation_before := old._generation
	var resource_count_before := old._resource_rids.size()
	var output_before := old.texture.texture_rd_rid
	old.start()
	for _frame in 2:
		await process_frame
	check(old._generation == generation_before and old._resource_rids.size() == resource_count_before and old.texture.texture_rd_rid == output_before and old.active and old.pending_readbacks > 0, "未归还读回时拒绝复用同一GPUWorld", "start()只发出明确警告；不创建新一代、不释放原资源、不清空原纹理", {"generation_before":generation_before,"generation_after":old._generation,"resources_before":resource_count_before,"resources_after":old._resource_rids.size(),"pending":old.pending_readbacks})
	var timestamp_before := old.timestamp_updates
	old.shutdown()
	for _frame in 12:
		await process_frame
	check(not old.resource_release_confirmed and old.pending_readbacks > 0 and not old._resource_rids.is_empty(), "旧节点超过8帧仍保留待读回资源", "退役不再依赖固定帧数")
	var current := GPUWorld.new()
	root.add_child(current)
	current.configure(config)
	current.debug_snapshot_ready.connect(func(data: Dictionary): snapshots[int(data.request_id)] = data)
	current.start()
	if not check(await wait_active(current), "旧回调未归还时新一代正常启动", current.error_message):
		RenderingServer.call_on_render_thread(old.release_probe_rd)
		await wait_released(old)
		current.shutdown()
		await wait_released(current)
		finish()
		return
	var before := await snapshot(current)
	RenderingServer.call_on_render_thread(old.release_probe_rd)
	check(await wait_released(old), "最后旧回调归还后确认RD释放", old.error_message, {"pending":old.pending_readbacks,"released":old.resource_release_confirmed})
	for _frame in 4:
		await process_frame
	check(old_events == 0 and old.timestamp_updates == timestamp_before, "旧代回调不发统计且不读取时间戳", "旧回调仅归还pending计数，不产生新的数据/读回工作", {"events":old_events,"timestamp_before":timestamp_before,"timestamp_after":old.timestamp_updates})
	var after := await snapshot(current)
	check(not before.is_empty() and not after.is_empty() and before.teams == after.teams and float(after.sim_time) == 0.0 and current.error_message.is_empty(), "迟到旧回调不会污染新局核心库存与模拟时间")
	check(old._resource_rids.is_empty() and old.pending_readbacks == 0, "旧代GPU资源与回调全部回收")
	old.queue_free()
	current.shutdown()
	if check(await wait_released(current), "当前代关闭也获得释放确认"):
		current.queue_free()
	finish()
