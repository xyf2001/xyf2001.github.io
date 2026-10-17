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
	report["execution_os"] = OS.get_name()
	report["execution_mode"] = "host_godot_loads_embedded_pck"
	report["native_windows_exe_execution"] = "NOT TESTED"
	var engine_args := OS.get_cmdline_args()
	# Godot消费--main-pack后不会保留在get_cmdline_args()中。Linux外部装包工具
	# 读取当前进程的真实argv绑定实际文件；不能仅相信另传一个未经核对的文件名。
	report["main_pack_identity_source"] = "OS.get_cmdline_args"
	var process_args := FileAccess.open("/proc/self/cmdline", FileAccess.READ)
	if process_args != null:
		var raw_args := process_args.get_buffer(65536)
		process_args.close()
		engine_args = PackedStringArray()
		var token := PackedByteArray()
		for byte in raw_args:
			if byte == 0:
				engine_args.append(token.get_string_from_utf8())
				token.clear()
			else:
				token.append(byte)
		if not token.is_empty(): engine_args.append(token.get_string_from_utf8())
		report["main_pack_identity_source"] = "linux_proc_self_cmdline"
	var pack_path := ""
	for i in engine_args.size():
		if engine_args[i] == "--main-pack" and i + 1 < engine_args.size():
			pack_path = engine_args[i + 1]
		elif engine_args[i].begins_with("--main-pack="):
			pack_path = engine_args[i].trim_prefix("--main-pack=")
	var pack := FileAccess.open(pack_path, FileAccess.READ) if not pack_path.is_empty() else null
	if pack == null:
		_fail("必须通过--main-pack实际加载待交付EXE，才能记录其SHA256")
		return
	report["main_pack_path"] = pack.get_path_absolute()
	pack.close()
	report["main_pack_sha256"] = FileAccess.get_sha256(str(report.main_pack_path))
	if str(report.main_pack_sha256).length() != 64:
		_fail("无法计算实际内嵌PCK所在EXE的SHA256")
		return
	report["raw_glsl_present"] = FileAccess.file_exists("res://shaders/battle.glsl")
	var raw_code := FileAccess.get_file_as_string("res://shaders/battle.glsl") if bool(report.raw_glsl_present) else ""
	report["compute_shader_source"] = "raw_glsl" if raw_code.contains("#version") else "embedded_spirv"
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
	if phase == "done" or phase == "failing": return false
	if Time.get_ticks_msec() - started > 180000:
		_fail("180秒内未完成导出资源检查")
		return false
	if game == null or game.world == null: return false
	var world: Node = game.world
	if not world.error_message.is_empty():
		_fail(world.error_message)
		return false
	if not game.pinball.error.is_empty():
		_fail(str(game.pinball.error))
		return false
	if phase == "waiting" and world.active and world.stats.get("teams", []).size() == 4:
		phase = "initial"
		world.debug_snapshot_ready.connect(_snapshot, CONNECT_ONE_SHOT)
		world.debug_readback("sample")
	elif phase == "running" and game.elapsed >= 0.05:
		phase = "moved"
		game.paused = true
		world.debug_snapshot_ready.connect(_snapshot, CONNECT_ONE_SHOT)
		# 明确的一次性导出验收读回；正式运行路径仍不读取普通粒子表。
		world.debug_readback("all_particles")
	return false

func _snapshot(data: Dictionary) -> void:
	if phase == "initial":
		report["device"] = game.world.stats.get("device", "UNKNOWN")
		var valid: bool = data.get("teams", []).size() == 4 and game.pinball.balls.size() == 16
		for team: Dictionary in data.get("teams", []):
			valid = valid and bool(team.alive) and int(team.shield) == 1000000 and int(team.gun) == 1000000
		var metrics: Array = data.get("metrics", [])
		var cells: int = int(game.settings.grid_size) * int(game.settings.grid_size) / 4
		for i in 4: valid = valid and metrics.size() > 11 and int(metrics[8 + i]) == cells
		valid = valid and game.world.texture.texture_rd_rid.is_valid()
		var target_switch_cd: float = float(game.world.settings.get("gun_target_switch_cd", -1.0))
		valid = valid and is_equal_approx(target_switch_cd, 0.5)
		report["initial"] = {"valid":valid,"teams":data.get("teams", []),"shared_texture":game.world.texture.texture_rd_rid.is_valid(),"left_balls":game.pinball.balls.size(),"gun_target_switch_cd":target_switch_cd}
		if not valid:
			_fail("导出开局状态/共享纹理不正确")
			return
		phase = "running"
		game.paused = false
	elif phase == "moved":
		var metrics: Array = data.get("metrics", [])
		var valid: bool = metrics.size() > 15 and int(metrics[15]) == 0 and float(data.get("sim_time", 0.0)) >= 0.04 and int(metrics[0]) > 0 and float(data.get("sim_time", -1)) + game.active_dt * 0.51 >= game.elapsed
		var entities: Dictionary = _validate_all_entities(data)
		valid = valid and bool(entities.valid)
		report["movement"] = {"valid":valid,"cpu_sim_time":game.elapsed,"gpu_sim_time":data.get("sim_time", 0.0),"active_particles":metrics[0] if not metrics.is_empty() else -1,"overflow":metrics[15] if metrics.size() > 15 else -1,"entity_validation":entities}
		if not valid:
			_fail("导出Compute推进、实体完整性或generation检查失败")
			return
		phase = "capturing"
		await RenderingServer.frame_post_draw
		if phase != "capturing": return
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
		phase = "closing"
		var released: bool = await _close_game()
		if phase != "closing": return
		if not released:
			_fail("导出资源关闭后异步读回或RD资源未排空")
			return
		report["shutdown"] = {"pending_readbacks":game.world.pending_readbacks,"release_confirmed":game.world.resource_release_confirmed,"remaining_rids":game.world._resource_rids.size()}
		report["status"] = "PASS"
		if not _write_report():
			_fail("无法完整保存导出PCK验证报告")
			return
		phase = "done"
		quit()

func _validate_all_entities(data: Dictionary) -> Dictionary:
	var normal_count := 0
	var sniper_count := 0
	var big_count := 0
	var invalid_finite := 0
	var invalid_energy := 0
	var invalid_generation := 0
	var invalid_ids: Array[Dictionary] = []
	for table: String in ["particles", "balls"]:
		for entity: Dictionary in data.get(table, []):
			var type := int(entity.get("type", 0))
			if type == 3:
				big_count += 1
			else:
				normal_count += 1
				if type == 2: sniper_count += 1
			var finite := true
			for field: String in ["x", "y", "vx", "vy", "radius"]:
				finite = finite and is_finite(float(entity.get(field, NAN)))
			var positive_energy := int(entity.get("energy", 0)) > 0
			var generation_valid := type != 1 and type != 2 or int(entity.get("particle_generation", entity.get("generation", 0))) > 0
			if not finite: invalid_finite += 1
			if not positive_energy: invalid_energy += 1
			if not generation_valid: invalid_generation += 1
			if (not finite or not positive_energy or not generation_valid) and invalid_ids.size() < 16:
				invalid_ids.append({"table":table,"id":int(entity.get("id", -1)),"finite":finite,"positive_energy":positive_energy,"generation_positive":generation_valid})
	var metrics: Array = data.get("metrics", [])
	var metric_normal := int(metrics[0]) if not metrics.is_empty() else -1
	var metric_big := int(metrics[1]) if metrics.size() > 1 else -1
	return {"valid":normal_count > 0 and normal_count == metric_normal and big_count == metric_big and invalid_finite == 0 and invalid_energy == 0 and invalid_generation == 0,"snapshot_kind":"all_particles","observed_nonbig_count":normal_count,"observed_sniper_count":sniper_count,"observed_big_count":big_count,"metric_nonbig_count":metric_normal,"metric_big_count":metric_big,"invalid_finite_count":invalid_finite,"invalid_energy_count":invalid_energy,"invalid_generation_count":invalid_generation,"invalid_id_examples":invalid_ids}

func _close_game() -> bool:
	if game == null: return true
	var closing: Array = game.retired.duplicate()
	if game.world != null: closing.append(game.world)
	for target in closing:
		if is_instance_valid(target): target.shutdown()
	var release_deadline := Time.get_ticks_msec() + 120000
	while Time.get_ticks_msec() < release_deadline:
		var complete := true
		for target in closing:
			if is_instance_valid(target) and not target.is_shutdown_complete(): complete = false
		if complete: return true
		await process_frame
	return false

func _write_report() -> bool:
	var file := FileAccess.open(artifact_dir.path_join("export_pck.json"), FileAccess.WRITE)
	if file == null:
		print("PCK_REPORT_WRITE_ERROR 无法创建报告：", FileAccess.get_open_error())
		return false
	file.store_string(JSON.stringify(report, "  ") + "\n")
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK:
		print("PCK_REPORT_WRITE_ERROR 无法完整写入报告：", error_string(error))
		return false
	print("PCK_RESULT ", JSON.stringify(report))
	return true

func _fail(message: String) -> void:
	if phase == "done" or phase == "failing": return
	phase = "failing"
	report["status"] = "FAIL"
	report["reason"] = message
	report["failure_shutdown_complete"] = await _close_game()
	_write_report()
	phase = "done"
	quit(1)
