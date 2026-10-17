extends "res://tests/gpu_suite.gd"

func run_suite() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	world = World.new()
	world.configure({"particle_capacity":1024,"grid_size":64,"render_size":256,"seed":20261016,"gun_rate":0.0,"gun_start":0.0,"gun_end":0.0,"precision_mode":"exact","particle_radius":1.4,"particle_speed":140.0,"sniper_speed":620.0,"friendly_particle_collisions":true})
	world.debug_snapshot_ready.connect(_on_snapshot)
	world.failed.connect(func(message: String): runtime_error = message)
	root.add_child(world)
	world.start()
	var deadline := Time.get_ticks_msec()+240000
	while not world.active and runtime_error.is_empty() and Time.get_ticks_msec()<deadline:await process_frame
	if not check(world.active,"wall-pair probe actual Vulkan startup",runtime_error):
		await _shutdown_world()
		finish()
		return
	await _reset_fixture(0)
	_inject(0,10.0,Vector2(500.0,100.0),Vector2(140.0,0.0))
	_inject(0,10.0,Vector2(500.2,102.795),Vector2(-140.0,0.0))
	var before:Dictionary=await _snapshot()
	var dt:=1.0/240.0
	await _advance(1,dt)
	var after:Dictionary=await _snapshot()
	var live:Array=after.get("particles",[])
	var distance:float=-1.0
	var radius_sum:float=-1.0
	if live.size()==2:
		distance=Vector2(float(live[0].x),float(live[0].y)).distance_to(Vector2(float(live[1].x),float(live[1].y)))
		radius_sum=float(live[0].radius)+float(live[1].radius)
	var pair_contacts:=int(after.metrics[2])-int(before.metrics[2])
	var evidence:Dictionary={"dt":dt,"substeps":SpaceRules.substep_count(dt,world.settings),"effective_config":world.settings,"before":before,"after":after,"final_pair_distance":distance,"radius_sum":radius_sum,"pair_contact_delta":pair_contacts,"expected_reflected_free_endpoints":[[500.5833333333,100.0],[499.6166666667,102.795]],"fixture_kind":"real production GPU; same team; all territory team0; radius1.4; one1/240step"}
	print("NO_WALL_PAIR_MECHANICAL_PROBE "+JSON.stringify(evidence))
	var path:String=str(options.get("artifact-dir","res://artifacts")).path_join("probe_result.json")
	var file:=FileAccess.open(path,FileAccess.WRITE)
	if check(file!=null,"wall-pair probe evidence writable",path):
		file.store_string(JSON.stringify(evidence,"\t"))
		file.flush()
		check(file.get_error()==OK,"wall-pair probe evidence saved",path)
		file.close()
	var mechanical_valid:bool=live.size()==2 and _energy(after)==20 and pair_contacts==1
	if live.size()==2:
		for particle:Dictionary in live:
			mechanical_valid=mechanical_valid and absf(float(particle.vy))>0.01 and absf(Vector2(float(particle.vx),float(particle.vy)).length()-140.0)<0.001
	check(mechanical_valid,"translated no-wall grazing collision creates transverse velocity","Legal start, identical birth speed140 and energy20; translated no-wall control has the same first mechanical contact. Both outgoing velocities must have nonzeroY, while scalar speed and energy stay fixed",{"distance":distance,"radius_sum":radius_sum,"pair_contact_delta":pair_contacts,"particles":live})
	await _shutdown_world()
	finish()
