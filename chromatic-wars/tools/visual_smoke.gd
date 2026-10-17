extends SceneTree
## 独立图形烟测；get_image只用于明确的一次性截图，不是游戏渲染路径。
var scene: Node
var began := 0
var checkpoints: Dictionary = {}
var artifact_dir := "res://artifacts"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--artifact-dir": artifact_dir = args[i + 1]
	DirAccess.make_dir_recursive_absolute(artifact_dir)
	call_deferred("run")

func wait_frames(count: int) -> void:
	for i in count:
		await process_frame

func capture(name: String) -> void:
	await RenderingServer.frame_post_draw
	var path := artifact_dir.path_join(name + ".png")
	var result := root.get_texture().get_image().save_png(path)
	print("截图：", path, "，错误码：", result)

func run() -> void:
	began = Time.get_ticks_msec()
	scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	while not scene.world.active and scene.world.error_message.is_empty():
		if Time.get_ticks_msec() - began > 90000:
			print("FAIL：GPU启动超时")
			quit(1)
			return
		await process_frame
	if not scene.world.error_message.is_empty():
		print("FAIL：", scene.world.error_message)
		quit(1)
		return
	scene.paused = true
	await wait_frames(24)
	await capture("01_初始四象限")
	checkpoints["texture_shared"] = scene.battle_view.texture is Texture2DRD
	checkpoints["initial_balls"] = scene.pinball.balls.size()
	scene.world.output(0, 1, 100000.0)
	scene.world.output(1, 3, 1000.0)
	scene.world.output(2, 2, 256.0)
	scene.settings["time_scale"] = 4.0
	scene.paused = false
	while scene.elapsed < 5.0:
		if Time.get_ticks_msec() - began > 240000:
			print("FAIL：5秒模拟烟测超时，当前", scene.elapsed)
			quit(1)
			return
		await process_frame
	scene.paused = true
	await wait_frames(16)
	await capture("02_运动大球与粒子")
	checkpoints["sim_time"] = scene.elapsed
	checkpoints["stats"] = scene.world.stats
	checkpoints["pinball"] = scene.pinball.snapshot()
	scene.ui.emit_signal("step_pressed")
	var before: float = scene.elapsed
	await wait_frames(10)
	checkpoints["single_step_delta"] = scene.elapsed - before
	if absf((scene.elapsed - before) - scene.active_dt) > 0.000001:
		print("FAIL：单步没有恰好推进一个固定时间步：", scene.elapsed - before)
		quit(1)
		return
	var paused_time: float = scene.elapsed
	await wait_frames(12)
	if absf(scene.elapsed - paused_time) > 0.000001:
		print("FAIL：暂停时模拟仍前进")
		quit(1)
		return
	checkpoints["paused_freezes_simulation"] = true
	var file := FileAccess.open(artifact_dir.path_join("visual_smoke.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(checkpoints, "\t"))
	file.close()
	print("PASS：实际GPU共享纹理及5秒图形烟测；单步增量", scene.elapsed - before)
	scene.world.shutdown()
	await wait_frames(4)
	quit(0)
