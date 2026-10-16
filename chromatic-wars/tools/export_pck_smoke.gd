extends SceneTree
## 由Linux Godot直接装载Windows EXE内嵌PCK，再从工程外指定本脚本。
## 只证明导出资源/Compute/共享纹理可工作，不证明Windows系统启动。
var game: Node
var phase := "waiting"
var started := Time.get_ticks_msec()
var report: Dictionary = {}
var artifact_dir := "/tmp/chromatic-export-smoke"

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	for i in range(args.size() - 1):
		if args[i] == "--artifact-dir": artifact_dir = args[i + 1]
	DirAccess.make_dir_recursive_absolute(artifact_dir)
	report["raw_glsl_present"] = FileAccess.file_exists("res://shaders/battle.glsl")
	var shader_file = load("res://shaders/battle.glsl")
	report["shader_class"] = shader_file.get_class() if shader_file != null else "NULL"
	if not shader_file is RDShaderFile:
		_fail("内嵌PCK缺少RDShaderFile")
		return
	report["spirv_error"] = shader_file.get_spirv().get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not str(report.spirv_error).is_empty():
		_fail("导出SPIR-V编译错误")
		return
	call_deferred("_boot")

func _boot() -> void:
	game = load("res://scenes/main.tscn").instantiate()
	root.add_child(game)
	game.paused = true

func _process(_delta: float) -> bool:
	if phase == "done": return false
	if Time.get_ticks_msec() - started > 180000:
		_fail("180秒内未完成导出资源检查")
	if game == null or game.world == null: return false
	var world: Node = game.world
	if not world.error_message.is_empty():
		_fail(world.error_message)
		return false
	if phase == "waiting" and world.active and world.stats.get("teams", []).size() == 4:
		phase = "initial"
		world.debug_snapshot_ready.connect(_snapshot, CONNECT_ONE_SHOT)
		world.debug_readback("sample")
	elif phase == "running" and game.elapsed >= 0.05:
		phase = "moved"
		game.paused = true
		world.debug_snapshot_ready.connect(_snapshot, CONNECT_ONE_SHOT)
		world.debug_readback("sample")
	return false

func _snapshot(data: Dictionary) -> void:
	if phase == "initial":
		var valid: bool = data.get("teams", []).size() == 4 and game.pinball.balls.size() == 16
		for team: Dictionary in data.get("teams", []):
			valid = valid and bool(team.alive) and int(team.shield) == 1000000 and int(team.gun) == 1000000
		var metrics: Array = data.get("metrics", [])
		var cells: int = int(game.settings.grid_size) * int(game.settings.grid_size) / 4
		for i in 4: valid = valid and metrics.size() > 11 and int(metrics[8 + i]) == cells
		valid = valid and game.world.texture.texture_rd_rid.is_valid()
		report["initial"] = {"valid":valid,"teams":data.get("teams", []),"shared_texture":game.world.texture.texture_rd_rid.is_valid(),"left_balls":game.pinball.balls.size()}
		if not valid:
			_fail("导出开局状态/共享纹理不正确")
			return
		phase = "running"
		game.paused = false
	elif phase == "moved":
		var valid: bool = float(data.get("sim_time", 0.0)) >= 0.04 and int(data.metrics[0]) > 0
		report["movement"] = {"valid":valid,"cpu_sim_time":game.elapsed,"gpu_sim_time":data.get("sim_time", 0.0),"active_particles":data.metrics[0]}
		if not valid:
			_fail("导出Compute没有实际推进/发射粒子")
			return
		phase = "capturing"
		await RenderingServer.frame_post_draw
		var screenshot := root.get_texture().get_image()
		var scale: Vector2 = Vector2(screenshot.get_size()) / root.get_visible_rect().size
		var colors: Array[Color] = []
		for f in [Vector2(.15,.15),Vector2(.85,.15),Vector2(.15,.85),Vector2(.85,.85)]:
			colors.append(screenshot.get_pixelv(Vector2i((game.battle_view.get_global_transform_with_canvas() * (game.battle_view.size * f)) * scale)))
		valid = colors[0].r > colors[0].g * 1.3 and colors[1].g > colors[1].r * 1.3 and colors[2].b > colors[2].r * 1.3 and colors[3].r > colors[3].b * 1.3 and colors[3].g > colors[3].b * 1.3
		var saved := screenshot.save_png(artifact_dir.path_join("export_pck.png"))
		report["pixels"] = str(colors)
		if not valid or saved != OK:
			_fail("导出实际画面象限/截图检查失败")
			return
		report["status"] = "PASS"
		_write_report()
		phase = "done"
		game.world.shutdown()
		for i in 8: await process_frame
		quit()

func _write_report() -> void:
	var file := FileAccess.open(artifact_dir.path_join("export_pck.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  ") + "\n")
	print("PCK_RESULT ", JSON.stringify(report))

func _fail(message: String) -> void:
	report["status"] = "FAIL"
	report["reason"] = message
	_write_report()
	phase = "done"
	quit(1)
