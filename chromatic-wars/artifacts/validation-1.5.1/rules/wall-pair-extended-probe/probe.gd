extends "res://tests/gpu_suite.gd"
var probe_cases:Array=[]

func run_suite() -> void:
	Engine.max_fps=0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	world=World.new()
	world.configure({"particle_capacity":1024,"grid_size":64,"render_size":256,"seed":20261016,"gun_rate":0.0,"gun_start":0.0,"gun_end":0.0,"precision_mode":"exact","particle_radius":1.2,"particle_speed":140.0,"sniper_speed":620.0,"friendly_particle_collisions":true,"gun_rotation_speed":0.1,"gun_discharge_duration":10.0})
	world.debug_snapshot_ready.connect(_on_snapshot)
	world.failed.connect(func(message:String):runtime_error=message)
	root.add_child(world)
	world.start()
	var deadline:=Time.get_ticks_msec()+240000
	while not world.active and runtime_error.is_empty() and Time.get_ticks_msec()<deadline:await process_frame
	if not check(world.active,"extended real Vulkan probe initialized",runtime_error):
		await _shutdown_world()
		finish()
		return
	await _pair_case("enemy reflected wall min64 exactly once",Vector2(1022.6,500),Vector2(140,0),10,Vector2(1020.15,500),Vector2(0,140),4,1,620.0,false)
	var diagonal:=Vector2.ONE.normalized()*140.0
	await _pair_case("friendly two-axis corner",Vector2(1022.6,1022.6),diagonal,10,Vector2(1020.85,1020.85),diagonal,10,0,620.0,false)
	await _pair_case("supported fast reflected CCD nonoverlapping endpoints",Vector2(1022.6,500),Vector2(2000,0),10,Vector2(1020.15,500),Vector2(0,2000),10,0,2000.0,true)
	# Deliberate overspeed fixture exercises production fast-particle fallback and
	# four real wall folds in one substep; it is not representative default play.
	await _pair_case("synthetic overspeed multiple-wall fallback",Vector2(1022.6,500),Vector2(1000000,0),10,Vector2(1020.15,500),Vector2(0,1000000),10,0,620.0,true)
	await _mg_birth_case()
	var result:Dictionary={"cases":probe_cases,"runtime_error":runtime_error,"fixture":"production Compute; no uploaded evolution; synthetic overspeed explicitly labelled"}
	var path:String=str(options.get("artifact-dir","res://artifacts")).path_join("probe_result.json")
	var file:=FileAccess.open(path,FileAccess.WRITE)
	if check(file!=null,"extended probe evidence writable",path):
		file.store_string(JSON.stringify(result,"\t"));file.flush();check(file.get_error()==OK,"extended probe evidence saved",path);file.close()
	await _shutdown_world()
	finish()

func _reset_probe() -> void:
	await _reset_fixture(0)
	for team in [1,2,3]:world.debug_command({"op":10,"team":team,"energy":0,"gun":0,"state":2})
	world.flush()
	await process_frame
	await process_frame

func _pair_case(label:String,a:Vector2,av:Vector2,ae:int,b:Vector2,bv:Vector2,be:int,bt:int,declared_speed:float,nonoverlap:bool) -> void:
	world.update_settings({"gun_rate":0.0,"sniper_speed":declared_speed})
	await _reset_probe()
	_inject(0,float(ae),a,av)
	_inject(bt,float(be),b,bv)
	var before:Dictionary=await _snapshot()
	var dt:=1.0/240.0
	await _advance(1,dt)
	var after:Dictionary=await _snapshot()
	var live:Array=after.get("particles",[])
	var pairs:=int(after.metrics[2])-int(before.metrics[2])
	var spent:=int(after.consumed_energy)-int(before.consumed_energy)
	var separation:float=-1.0
	var radii:float=-1.0
	var valid:bool=runtime_error.is_empty() and _energy(after)+spent==ae+be
	if bt==1:
		valid=valid and live.size()==1 and _energy(after)==ae-be and spent==2*be and pairs==1
	else:
		valid=valid and live.size()==2 and _energy(after)==ae+be and spent==0 and pairs>0
		if live.size()==2:
			separation=Vector2(float(live[0].x),float(live[0].y)).distance_to(Vector2(float(live[1].x),float(live[1].y)))
			radii=float(live[0].radius)+float(live[1].radius)
			for particle:Dictionary in live:
				var speed:=Vector2(float(particle.vx),float(particle.vy)).length()
				valid=valid and absf(speed-av.length())<maxf(0.01,av.length()*0.00001) and is_finite(float(particle.x)) and is_finite(float(particle.y)) and float(particle.x)>=float(particle.radius)-0.001 and float(particle.x)<=1024.0-float(particle.radius)+0.001 and float(particle.y)>=float(particle.radius)-0.001 and float(particle.y)<=1024.0-float(particle.radius)+0.001
			if nonoverlap:valid=valid and separation>=radii-0.001
	var evidence:Dictionary={"name":label,"valid":valid,"before":before,"after":after,"pair_contact_delta":pairs,"consumed_delta":spent,"dt":dt,"substeps":SpaceRules.substep_count(dt,world.settings),"separation":separation,"radii":radii,"synthetic_overspeed":av.length()>declared_speed,"input_positions":[a,b],"input_velocities":[av,bv],"input_energy":ae+be}
	probe_cases.append(evidence)
	print("EXTENDED_WALL_PROBE "+JSON.stringify(evidence))
	check(valid,label,"Actual GPU collision, integer ledger, speed preservation and finite geometry",{"pair_delta":pairs,"consumed_delta":spent,"remaining":_energy(after),"particles":live,"distance":separation,"radii":radii})

func _mg_birth_case() -> void:
	world.update_settings({"gun_rate":0.0,"sniper_speed":2000.0,"gun_rotation_speed":0.1,"gun_discharge_duration":10.0})
	await _reset_probe()
	# rate0 in all preceding cases leaves the real cadence phase at its startup0.
	world.update_settings({"gun_rate":241.0})
	var dt:=1.0/240.0
	var substeps:=SpaceRules.substep_count(dt,world.settings)
	var muzzle_x:=256.0+12.0+1.2+3.0
	var initial_y:=256.0-2000.0*(2.0*dt/3.0)
	_inject(0,10.0,Vector2(muzzle_x,initial_y),Vector2(0,2000))
	world.output(0,4,24100.0)
	var before:Dictionary=await _snapshot()
	await _advance(1,dt)
	var after:Dictionary=await _snapshot()
	var live:Array=after.get("particles",[])
	var pairs:=int(after.metrics[2])-int(before.metrics[2])
	var spent:=int(after.consumed_energy)-int(before.consumed_energy)
	var valid:bool=substeps==3 and live.size()==2 and pairs==0 and spent==0 and _energy(after)==20 and int(after.teams[0].gun)==24090
	var found_original:=false
	for particle:Dictionary in live:
		if absf(float(particle.birth_scale)-2000.0)<0.01:
			found_original=true
			valid=valid and absf(float(particle.vx))<0.001 and absf(float(particle.vy)-2000.0)<0.01
	valid=valid and found_original
	var evidence:Dictionary={"name":"real MG birth excludes prebirth overlap","valid":valid,"before":before,"after":after,"pair_contact_delta":pairs,"consumed_delta":spent,"dt":dt,"substeps":substeps,"initial_y":initial_y,"configured_rate":241,"input_energy":24110,"explanation":"Original friendly particle crosses future muzzle at start of third substep; the first actual MG shot is born near its end, after separation exceeds2r. No valid common-time collision exists."}
	probe_cases.append(evidence)
	print("EXTENDED_WALL_PROBE "+JSON.stringify(evidence))
	check(valid,"real MG newborn common-time CCD","Real fixed-rate gun firing; cannot collide with the original particle before its own birth",{"particles":live,"pair_delta":pairs,"spent":spent,"gun_remaining":after.teams[0].gun,"before_phase":before.teams[0].gun_phase,"after_phase":after.teams[0].gun_phase})
