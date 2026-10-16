extends "res://tests/test_harness.gd"
## 完整两系统长局工具：显式小容量/64²地图/4096能量包验证模式，不代表默认画质或逐粒子结果。
var world: GPUWorld
var pinball: PinballPhysics
var sim_time := 0.0
var rescue_events := 0
var death_events := 0
var runtime_error := ""

func run_suite() -> void:
	if RenderingServer.get_current_rendering_driver_name() != "vulkan":
		record("NOT TESTED", "完整GPU对局前提", "需要普通窗口Vulkan，不能headless")
		finish()
		return
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var config := GameSettings.defaults()
	config["particle_capacity"] = clampi(int(options.get("capacity", "64")), 64, 1000000)
	config["grid_size"] = 64
	config["render_size"] = 256
	config["precision_mode"] = "packed"
	config["packet_energy"] = 4096
	config["seed"] = int(options.get("seed", "20261016"))
	pinball = PinballPhysics.new()
	root.add_child(pinball)
	pinball.configure(config)
	pinball.reset(config.seed)
	world = GPUWorld.new()
	root.add_child(world)
	world.configure(config)
	world.failed.connect(func(message: String): runtime_error = message)
	pinball.weapon_output.connect(func(t: int, k: int, e: float): world.output(t, k, e, sim_time))
	world.rescue_requested.connect(func(t: int):
		rescue_events += 1
		world.resolve_rescue(t, pinball.rescue(t))
	)
	world.team_eliminated.connect(func(t: int):
		death_events += 1
		world.death_balls(t, pinball.eliminate(t))
	)
	world.start()
	var began := Time.get_ticks_msec()
	while not world.active and runtime_error.is_empty() and Time.get_ticks_msec() - began < 60000:
		await process_frame
	if not check(world.active, "长局GPU启动", runtime_error):
		finish()
		return
	var view := TextureRect.new()
	view.position = Vector2(530, 112)
	view.size = Vector2(512, 512)
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.texture = world.texture
	root.add_child(view)
	var duration := float(options.get("duration", "1200"))
	var frame_start := Engine.get_frames_drawn()
	var valid := true
	var natural_end := false
	var next_progress := 10.0
	var max_wall := int(options.get("wall_seconds", "3600")) * 1000
	var dt := 1.0 / 120.0
	while sim_time + dt * 0.5 < duration and runtime_error.is_empty():
		for index in 8:
			if sim_time + dt * 0.5 >= duration: break
			sim_time += dt
			pinball.step(dt, sim_time)
			world.step(dt, sim_time)
		world.flush()
		var teams: Array = world.stats.get("teams", [])
		if teams.size() == 4:
			var living := 0
			for team: Dictionary in teams:
				if bool(team.alive): living += 1
			if living == 0:
				natural_end = true
				break
		valid = valid and pinball.error.is_empty() and int(world.stats.get("overflow_count", 0)) == 0
		if not valid or Time.get_ticks_msec() - began > max_wall: break
		if sim_time >= next_progress:
			print("BATTLE_PROGRESS " + JSON.stringify({"sim_seconds":sim_time,"wall_seconds":float(Time.get_ticks_msec()-began)/1000.0,"outputs":pinball.output_events,"rescues":rescue_events,"deaths":death_events,"active":world.stats.get("active_particles",0),"big":world.stats.get("big_balls",0)}))
			next_progress += 60.0
		await process_frame
	for index in 24:
		world.flush()
		await process_frame
	var elapsed := float(Time.get_ticks_msec() - began) / 1000.0
	var data := {"natural_end_all_cores_dead":natural_end,"sim_seconds":sim_time,"gpu_sim_seconds":world.stats.get("sim_time",0),"wall_seconds":elapsed,"capacity":config.particle_capacity,"grid":64,"packet_energy":4096,"mode":"小规模能量包长局","seed":config.seed,"outputs":pinball.output_events,"rescues":rescue_events,"deaths":death_events,"pinball_active":pinball.balls.size(),"gpu":world.stats,"observed_fps":float(Engine.get_frames_drawn()-frame_start)/maxf(elapsed,0.001)}
	print("BATTLE_RESULT " + JSON.stringify(data))
	check(valid and runtime_error.is_empty() and (natural_end or sim_time + dt >= duration) and float(world.stats.get("sim_time",0)) + dt >= sim_time, "完整对局自然结束" if natural_end else "左右两系统完整时长运行", "固定步长、真实弹球输出、GPU保命与死亡余波；仅声明当前明确配置及实际时长",data)
	world.shutdown()
	for index in 8: await process_frame
	finish()
