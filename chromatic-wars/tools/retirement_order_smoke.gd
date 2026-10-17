extends "res://tests/test_harness.gd"
## 正式主场景的同步退役顺序回归；真实GPU资源，不修改战斗配置。

func run_suite() -> void:
	if RenderingServer.get_current_rendering_driver_name() != "vulkan":
		record("NOT TESTED", "主场景退役顺序前提", "需要实际Vulkan窗口")
		finish()
		return
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var deadline := Time.get_ticks_msec() + 90000
	while not scene.world.active and scene.world.error_message.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	if not check(bool(scene.world.active), "主场景快速退役夹具启动", str(scene.world.error_message)):
		finish()
		return
	scene.paused = true
	for _restart in 3:
		scene._restart()
	deadline = Time.get_ticks_msec() + 90000
	while not scene.world.active and scene.world.error_message.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	scene.paused = true
	# 等真实释放，不把固定帧数当资源释放依据。
	var all_released := false
	deadline = Time.get_ticks_msec() + 90000
	while not all_released and Time.get_ticks_msec() < deadline:
		all_released = true
		for old: GPUWorld in scene.retired:
			all_released = all_released and old.is_shutdown_complete()
		if not all_released:
			await process_frame
	for _frame in 4:
		await process_frame
	var retired_states: Array[Dictionary] = []
	for old: GPUWorld in scene.retired:
		retired_states.append({"instance":old.get_instance_id(),"generation":old._generation,"shutting_down":old._shutting_down,"pending_readbacks":old.pending_readbacks,"release_confirmed":old.resource_release_confirmed,"resource_count":old._resource_rids.size(),"complete":old.is_shutdown_complete()})
	check(bool(scene.world.active) and all_released and scene.retired.is_empty(), "快速重开已释放的旧节点必须从retired移除", "主控不可在world仍指向旧对象时提前结束退役协程", {"retired_count":scene.retired.size(),"old_states":retired_states})
	var closing: Array = scene.retired.duplicate()
	closing.append(scene.world)
	for world: GPUWorld in closing:
		world.shutdown()
	for world: GPUWorld in closing:
		deadline = Time.get_ticks_msec() + 90000
		while not world.is_shutdown_complete() and Time.get_ticks_msec() < deadline:
			await process_frame
		check(world.is_shutdown_complete(), "主场景退役夹具资源关闭", "", {"pending":world.pending_readbacks,"released":world.resource_release_confirmed})
	scene.queue_free()
	finish()
