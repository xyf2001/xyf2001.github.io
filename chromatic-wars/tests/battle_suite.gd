extends "res://tests/test_harness.gd"
## 正式默认分辨率/真实弹药成本的左右系统长局。不得以旧64格/4096能量包冒充正常对局。
## --speed 1/2/4 为真实时钟目标倍率；软件Vulkan追不上时保留固定步，不跳过物理。
var world: GPUWorld
var pinball: PinballPhysics
var sim_time := 0.0
var rescue_events := 0
var death_events := 0
var runtime_error := ""
var snapshots: Dictionary = {}
var output_energy := 0.0
var output_count := 0
var maximum_ball_energy := 0

func run_suite() -> void:
	if RenderingServer.get_current_rendering_method() != "forward_plus" or RenderingServer.get_current_rendering_driver_name() != "vulkan":
		record("NOT TESTED", "完整GPU对局前提", "需要普通窗口Forward+ / Vulkan，不能headless")
		finish()
		return
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var config := GameSettings.defaults()
	config["particle_capacity"] = clampi(int(options.get("capacity", "10000")),64,1000000)
	config["grid_size"] = 512
	config["render_size"] = 768
	config["terrain_resolution"] = 512
	config["render_resolution"] = 768
	config["precision_mode"] = "exact"
	config["packet_energy"] = 1
	config["seed"] = int(options.get("seed", "20261017"))
	var speed := clampf(float(options.get("speed","1")),0.25,4.0)
	config["time_scale"]=speed
	var duration := float(options.get("duration","1200"))
	var wall_limit := float(options.get("wall_seconds","3600"))
	if not is_finite(duration) or duration<=0.0 or not is_finite(wall_limit) or wall_limit<=0.0:
		record("FAIL","长局参数","duration和wall_seconds必须为有限正数")
		finish()
		return
	pinball = PinballPhysics.new()
	pinball.position = Vector2(20,40)
	root.add_child(pinball)
	pinball.configure(config)
	pinball.reset(config.seed)
	world = GPUWorld.new()
	root.add_child(world)
	world.configure(config)
	world.failed.connect(func(message:String): runtime_error=message)
	world.debug_snapshot_ready.connect(func(data:Dictionary): snapshots[int(data.request_id)]=data)
	pinball.weapon_output.connect(func(t:int,k:int,e:float):
		output_energy += e
		output_count += 1
		world.output(t,k,e,sim_time))
	world.rescue_requested.connect(func(t:int):
		rescue_events += 1
		world.resolve_rescue(t,pinball.rescue(t)))
	world.team_eliminated.connect(func(t:int):
		death_events += 1
		world.death_balls(t,pinball.eliminate(t)))
	world.start()
	var began := Time.get_ticks_msec()
	while not world.active and runtime_error.is_empty() and Time.get_ticks_msec()-began<120000: await process_frame
	if not check(world.active,"长局GPU启动",runtime_error,{"effective_config":world.settings}):
		await _shutdown_world()
		finish()
		return
	var view := TextureRect.new()
	view.position = Vector2(530,112)
	view.size = Vector2(768,768)
	view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	view.texture = world.texture
	root.add_child(view)
	var frame_start := Engine.get_frames_drawn()
	var valid := true
	var natural_end := false
	var outcome:Dictionary={}
	var timed_out := false
	var next_progress := 10.0
	var next_wall_progress := 30.0
	var dt := 1.0/120.0
	var debt := 0.0
	var last_real := Time.get_ticks_usec()
	var play_began := last_real
	var frame_ms: Array = []
	var total_substeps := 0
	var maximum_active := 0
	var maximum_big := 0
	while sim_time+dt*0.5<duration and runtime_error.is_empty():
		var now := Time.get_ticks_usec()
		var real_dt := float(now-last_real)/1000000.0
		frame_ms.append(real_dt*1000.0)
		last_real = now
		debt += real_dt*speed
		var steps := 0
		while debt>=dt and steps<8 and sim_time+dt*0.5<duration:
			sim_time += dt
			pinball.step(dt,sim_time)
			for ball:Dictionary in pinball.balls: maximum_ball_energy=maxi(maximum_ball_energy,int(ball.value))
			world.step(dt,sim_time)
			debt -= dt
			steps += 1
			total_substeps += GPUCollisions.substep_count(dt,world.settings)
		world.flush()

		maximum_active = maxi(maximum_active,int(world.stats.get("active_particles",0)))
		maximum_big = maxi(maximum_big,int(world.stats.get("big_balls",0)))
		var wall_elapsed:=float(Time.get_ticks_usec()-play_began)/1000000.0
		if wall_elapsed>=next_wall_progress:
			var living_teams:Array=[]
			for team:Dictionary in world.stats.get("teams",[]):
				if bool(team.get("alive",false)):living_teams.append(int(team.get("team",-1)))
			print("BATTLE_WALL_PROGRESS "+JSON.stringify({"wall_seconds":wall_elapsed,"requested_speed":speed,"sim_seconds_scheduled":sim_time,"gpu_sim_seconds_completed":world.stats.get("sim_time",0),"active":world.stats.get("active_particles",0),"big":world.stats.get("big_balls",0),"living":living_teams,"outputs":pinball.output_events,"deaths":death_events,"rescues":rescue_events,"gpu_queue_commands":world.stats.get("queue_commands",0),"cpu_queue_commands":world._queued.size(),"overflow":world.stats.get("overflow_count",0),"runtime_error":runtime_error,"pinball_error":pinball.error}))
			next_wall_progress=wall_elapsed+30.0
		valid = valid and pinball.error.is_empty() and int(world.stats.get("overflow_count",0))==0
		if not valid: break
		outcome=_settled_outcome(world.stats)
		if bool(outcome.get("settled",false)):
			natural_end=true
			break
		if float(now-play_began)/1000000.0>wall_limit:
			timed_out=true
			break
		if sim_time>=next_progress:
			print("BATTLE_PROGRESS "+JSON.stringify({"sim_seconds":sim_time,"wall_seconds":float(now-play_began)/1000000.0,"requested_speed":speed,"outputs":pinball.output_events,"rescues":rescue_events,"deaths":death_events,"active":world.stats.get("active_particles",0),"big":world.stats.get("big_balls",0)}))
			next_progress += 60.0
		await process_frame
	var play_ended:=Time.get_ticks_usec()
	var frame_ended:=Engine.get_frames_drawn()
	# 显式小表快照是GPU完成栅栏，避免只看滞后的UI遥测误报长局完成。
	world.flush()
	var request: Dictionary = world.debug_readback("sample")
	var request_id := int(request.request_id)
	var fence_deadline := Time.get_ticks_msec()+120000
	while not snapshots.has(request_id) and Time.get_ticks_msec()<fence_deadline and runtime_error.is_empty(): await process_frame
	var final: Dictionary = snapshots.get(request_id,{})
	var elapsed := float(play_ended-play_began)/1000000.0
	var fence_wait_seconds:=float(Time.get_ticks_usec()-play_ended)/1000000.0
	var final_metrics:Array=final.get("metrics",[])
	var final_valid:bool=valid and runtime_error.is_empty() and pinball.error.is_empty() and final_metrics.size()>15 and int(final_metrics[15])==0 and absf(float(final.get("sim_time",-100.0))-sim_time)<=dt+0.0001
	if natural_end:
		var final_state:=world.stats.duplicate(true)
		final_state["teams"]=final.get("teams",[])
		final_state["diagnostics"]=final.get("diagnostics",{})
		final_state["queue_commands"]=(int(final_metrics[5]) if final_metrics.size()>5 else -1)+world._queued.size()
		final_state["command_head"]=int(final_metrics[4]) if final_metrics.size()>4 else -1
		outcome=_settled_outcome(final_state)
		final_valid=final_valid and bool(outcome.get("settled",false))
	var max_energy := 0
	for ball: Dictionary in pinball.balls: max_energy=maxi(max_energy,int(ball.value))
	frame_ms.sort()
	var fps := float(frame_ended-frame_start)/maxf(elapsed,0.001)
	var slow_count:=maxi(1,int(ceil(frame_ms.size()*0.01)))
	var slow_total:=0.0
	for sample in frame_ms.slice(maxi(0,frame_ms.size()-slow_count)):slow_total+=float(sample)
	var fps_low:=float(slow_count)*1000.0/maxf(slow_total,0.001)
	var data := {"natural_end":natural_end,"outcome":outcome,"target_duration_sim_seconds":duration,"completion_fence_wall_seconds":fence_wait_seconds,"final_validation_ok":final_valid,"runtime_error":runtime_error,"pinball_error":pinball.error,"timed_out":timed_out,"sim_seconds":sim_time,"gpu_sim_seconds":final.get("sim_time",-1),"requested_speed":speed,"cpu_scheduled_sim_seconds_per_wall_second":sim_time/maxf(elapsed,0.001),"achieved_completed_sim_seconds_per_wall_second":sim_time/maxf(elapsed+fence_wait_seconds,0.001),"wall_seconds":elapsed,"effective_config":world.settings,"gpu":world.stats,"gpu_final_metrics":final.get("metrics",[]),"pinball":pinball.snapshot(),"max_current_ammo":max_energy,"maximum_observed_ammo":maximum_ball_energy,"average_output_energy":output_energy/maxf(1.0,float(output_count)),"multiplier_triggers":pinball.multiplier_events,"unstuck_events":pinball.unstuck_events,"outputs":pinball.output_events,"rescues":rescue_events,"deaths":death_events,"observed_drawn_fps":fps,"drawn_fps_1pct_low":fps_low,"frame_time_sample_count":frame_ms.size(),"frame_p50_ms":_percentile(frame_ms,0.5),"frame_p95_ms":_percentile(frame_ms,0.95),"frame_p99_ms":_percentile(frame_ms,0.99),"gpu_substeps":total_substeps,"max_active_sampled":maximum_active,"max_big_sampled":maximum_big,"physical_gpu_claim":false}
	print("BATTLE_RESULT "+JSON.stringify(data))
	var path: String = str(options.get("artifact-dir","res://artifacts")).path_join("battle_%sx.json" % str(speed))
	var file := FileAccess.open(path,FileAccess.WRITE)
	if check(file!=null,"长局原始结果文件可写",path):
		file.store_string(JSON.stringify(data,"\t"))
		file.flush()
		check(file.get_error()==OK,"长局原始结果保存完成",path)
		file.close()
	check(final_valid,"长局最终物理与GPU完成状态","最终栅栏后重新核对GPU时钟、整数溢出、CPU弹球错误和运行时异常",{"sim_time":sim_time,"gpu_time":final.get("sim_time",-1),"gpu_overflow":final_metrics[15] if final_metrics.size()>15 else -1,"runtime_error":runtime_error,"pinball_error":pinball.error})
	if natural_end:
		check(final_valid,"真实模拟自然结局","全部核心死亡，或唯一幸存者且所有敌方实体、死队库存和待发队列均已清空；时长不决定胜负",outcome)
	var reached_requested:bool=sim_time+dt>=duration
	if final_valid and reached_requested:
		record("PASS","请求的对局模拟时长覆盖","实际完成所请求时长；不因时限宣布胜负",{"sim_seconds":sim_time,"requested":duration,"requested_speed":speed,"achieved_speed":sim_time/maxf(elapsed+fence_wait_seconds,0.001)})
	elif final_valid:
		record("NOT TESTED","请求的对局模拟时长覆盖","自然结局或真实时间预算提前结束；不把短局标为完整耐久通过",{"sim_seconds":sim_time,"requested":duration,"natural_end":natural_end,"timed_out":timed_out})
	if final_valid and sim_time+dt>=1200.0:
		record("PASS","20分钟完整左右系统耐久","正式分辨率和真实碰撞达到至少1200模拟秒",{"sim_seconds":sim_time,"requested_speed":speed})
	else:
		record("NOT TESTED","20分钟完整左右系统耐久","未达到1200模拟秒，或最终状态检查失败",{"sim_seconds":sim_time,"target":1200.0})

	await _shutdown_world()
	for index in 8: await process_frame
	finish()

func _percentile(values:Array,fraction:float)->float:
	return -1.0 if values.is_empty() else float(values[clampi(int(ceil(values.size()*fraction))-1,0,values.size()-1)])

func _settled_outcome(state:Dictionary)->Dictionary:
	var teams:Array=state.get("teams",[])
	if teams.size()!=4:return {"settled":false}
	var living:Array=[]
	for t in 4:
		if bool(teams[t].get("alive",false)):living.append(t)
	if living.is_empty():return {"settled":true,"kind":"all_cores_dead_draw","winner":-1}
	if living.size()!=1:return {"settled":false,"living":living}
	var survivor:int=living[0]
	var diagnostics:Dictionary=state.get("diagnostics",state)
	var counts:Array=diagnostics.get("active_by_team",[])
	if counts.size()!=4:return {"settled":false,"provisional_leader":survivor,"reason":"missing live per-team counts"}
	for t in 4:
		if t==survivor:continue
		if int(counts[t])>0 or int(teams[t].get("storm",0))>0 or int(teams[t].get("sniper",0))>0:return {"settled":false,"provisional_leader":survivor,"reason":"enemy aftermath still in flight or reserve"}
	if not world._queued.is_empty() or not world._resolutions.is_empty() or int(state.get("queue_commands",-1))!=0 or world._ring_tail!=int(state.get("command_head",world._ring_head)):return {"settled":false,"provisional_leader":survivor,"reason":"pending commands"}
	return {"settled":true,"kind":"survivor_after_all_enemy_aftermath","winner":survivor,"active_by_team":counts}

func _shutdown_world() -> void:
	if world==null:return
	world.shutdown()
	if world.has_method("is_shutdown_complete"):
		var deadline:=Time.get_ticks_msec()+90000
		while not bool(world.call("is_shutdown_complete")) and Time.get_ticks_msec()<deadline:await process_frame
		if not bool(world.call("is_shutdown_complete")):
			record("FAIL","长局GPU释放完成","90秒后异步回读仍未排空，未提前queue_free")
			return
	world.queue_free()
	await process_frame
