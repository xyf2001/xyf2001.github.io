extends SceneTree
func _initialize() -> void:
	call_deferred("run")
func run() -> void:
	var scene: Node = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	var began := Time.get_ticks_msec()
	while scene.world.error_message.is_empty() and Time.get_ticks_msec()-began < 30000:
		await process_frame
	for index in 20: await process_frame
	var valid: bool = not scene.world.active and not scene.world.error_message.is_empty() and scene.ui._error.visible and scene.elapsed == 0.0
	if valid:
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("res://artifacts/03_不支持Vulkan时的中文提示.png")
		print("PASS：无RenderingDevice时中文诊断可见、模拟时间为0、没有CPU战场回退。")
	else:
		print("FAIL：缺少Vulkan时没有正确停止并显示原因。")
	scene.world.shutdown()
	for index in 4: await process_frame
	quit(0 if valid else 1)
