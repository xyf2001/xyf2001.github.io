extends "res://tests/gpu_suite.gd"
## 正式Compute武器契约：读少量team/weapon/sniper槽，绝不CPU代算战斗结果。

func run_suite() -> void:
	if RenderingServer.get_current_rendering_method()!="forward_plus" or RenderingServer.get_current_rendering_driver_name()!="vulkan":
		record("NOT TESTED","武器GPU验证前提","需要普通窗口Forward+ / Vulkan")
		finish()
		return
	Engine.max_fps=0
	world=World.new()
	world.configure({"particle_capacity":4096,"grid_size":64,"render_size":256,"seed":20261017,"gun_rate":0.0,"intro_gun":0.0,"intro_shield":0.0,"particle_cost_delay":0.0,"particle_cost_growth":0.0,"sniper_speed":620.0,"ball_speed":92.0,"friendly_particle_collisions":true})
	world.debug_snapshot_ready.connect(_on_snapshot)
	world.failed.connect(func(message:String):runtime_error=message)
	root.add_child(world)
	world.start()
	var deadline:=Time.get_ticks_msec()+120000
	while not world.active and runtime_error.is_empty() and Time.get_ticks_msec()<deadline:await process_frame
	if not check(world.active,"武器真实Compute初始化",runtime_error):
		await _shutdown_world()
		finish()
		return
	await _test_gun_lock_and_cadence()
	await _test_gun_aim_and_switch()
	await _test_storm_circles()
	await _test_sniper_integer_split()
	await _test_shield_growth_and_paint()
	await _test_zero_entities()
	await _shutdown_world()
	for i in 8:await process_frame
	if str(options.get("include-gpu","false"))=="true":
		world=null
		runtime_error=""
		sim_time=0.0
		await super.run_suite()
		return
	finish()

func reset_weapons() -> void:
	sim_time=0.0
	await _reset_fixture(0,0.0)
	# 单武器夹具隔离敌核心命中；敌方物理接触另由contact_energy专项覆盖。
	for team in range(1,4):world.debug_command({"op":10,"team":team,"energy":0,"gun":0,"state":2})
	world.flush()
	await process_frame

func weapon(data:Dictionary,team:int=0)->Dictionary:
	var states:Array=data.get("weapons",[])
	return states[team] if states.size()>team else {}

func normal_energy(data:Dictionary)->int:
	var m:Array=data.get("metrics",[])
	return (int(m[23])|(int(m[24])<<32)) if m.size()>24 else -1

func accounted(data:Dictionary)->int:
	var e:=normal_energy(data)+int(data.get("consumed_energy",0))
	for state:Dictionary in data.get("teams",[]):
		e+=int(state.get("gun",0))+int(state.get("storm",0))+int(state.get("sniper",0))+int(state.get("shield",0))
	for ball:Dictionary in data.get("balls",[]): e+=int(ball.energy)
	return e

func _test_gun_lock_and_cadence()->void:
	await reset_weapons()
	world.update_settings({"gun_rate":1200.0,"particle_cost_delay":0.0,"particle_cost_growth":1.0})
	sim_time=100.0
	var before:Dictionary=await _snapshot()
	var baseline:=accounted(before)
	world.output(0,4,50000.0)
	await _advance(12)
	var first:Dictionary=await _snapshot()
	var first_count:=int(first.get("metrics",[0])[0])
	check(int(weapon(first).get("gun_shot_energy",-1))==101 and first_count==120,"机枪固定1200发每模拟秒且库存持续发射","0.1模拟秒实际生成120颗，不按风暴或进程提高射速",{"active":first_count,"weapon":weapon(first),"team":first.get("teams",[])[0]})
	check(accounted(first)-baseline==50000,"机枪发射整数总能量守恒","在场+剩余枪库存+累计消耗增量等于50000",{"accounted_delta":accounted(first)-baseline})
	sim_time=200.0
	await _advance()
	var progressed:Dictionary=await _snapshot()
	check(int(weapon(progressed).get("gun_shot_energy",-1))==101,"机枪单发能量补弹前锁定","世界进程跨越100模拟秒，既有库存单发成本仍101",{"weapon":weapon(progressed)})
	world.output(0,4,1000.0)
	await _advance()
	var refilled:Dictionary=await _snapshot()
	check(int(weapon(refilled).get("gun_shot_energy",-1))==201,"机枪补弹重算当前单发能量","新补弹按201锁定整个当前库存批次",{"weapon":weapon(refilled)})
	await reset_weapons()
	sim_time=300.0
	world.output(0,4,1.0)
	await _advance()
	var tail:Dictionary=await _snapshot()
	check(int(tail.teams[0].gun)==0 and normal_energy(tail)==1,"机枪不足整发成本的末发仍发出","库存1、当时成本301；末发携带1能量，枪不因尾数永久停火",{"team":tail.teams[0],"particles":tail.get("particles",[])})
	world.update_settings({"gun_rate":0.0,"particle_cost_growth":0.0})

func _test_gun_aim_and_switch()->void:
	await reset_weapons()
	world.update_settings({"gun_rate":1200.0,"particle_cost_delay":0.0,"particle_cost_growth":0.0,"gun_target_switch_cd":0.08})
	world.output(0,4,10000.0)
	await _advance()
	var safe:Dictionary=await _snapshot()
	check(float(safe.teams[0].get("gun_mode",-1))<0.5,"机枪周围安全时连续自由旋转","全图己色且没有威胁，防御/补地模式不误触发",{"team":safe.teams[0]})
	var missing_cell:=16*64+23
	world.debug_command({"op":15,"team":1,"energy":missing_cell,"count":1})
	await _advance()
	var paint:Dictionary=await _snapshot("terrain:%d:1" % missing_cell)
	var mode:=float(paint.teams[0].get("gun_mode",0))
	var recolored:bool=paint.get("terrain",[])==[0]
	check((mode>=0.5 and mode<2.0) or recolored,"机枪发现离散射线之间的周围单格缺口","非16射线格在完整扫描周期内进入补地或已被真实粒子染色；不能仅挪格让夹具通过",{"team":paint.teams[0],"weapon":weapon(paint),"terrain":paint.get("terrain",[]),"cell":missing_cell})
	_inject(1,1000.0,Vector2(456,256),Vector2(-40,0),13)
	await _advance()
	var first:Dictionary=await _snapshot()
	var first_target:=int(weapon(first).get("gun_target",-1))
	check(first_target>=4096 and float(first.teams[0].get("gun_mode",0))>=2.0,"机枪迫近大球防御优先于补地","真实敌球进入近防范围，锁定其physical ID并切换防御模式",{"weapon":weapon(first),"team":first.teams[0]})
	_inject(2,1000.0,Vector2(256,61),Vector2(0,40),13)
	await _advance()
	var during_cd:Dictionary=await _snapshot()
	check(int(weapon(during_cd).get("gun_target",-2))==first_target and sim_time<float(weapon(first).get("target_switch_ready",0)),"机枪轻微评分差遵守目标切换CD","略近的第二目标在0.08模拟秒内不导致来回跳锁",{"first":weapon(first),"during_cd":weapon(during_cd),"sim_time":sim_time})
	await _advance(12)
	var switched:Dictionary=await _snapshot()
	var second_target:=int(weapon(switched).get("gun_target",-1))
	var angle:=wrapf(float(switched.teams[0].gun_angle),-PI,PI)
	check(second_target!=first_target and second_target>=4096 and angle< -0.01,"机枪CD后切换目标且炮口连续跟踪","更高评分目标在北侧，炮口实际朝北转动，未锁死旧角度",{"weapon":weapon(switched),"team":switched.teams[0],"wrapped_angle":angle})
	var previous_ready:=float(weapon(switched).get("target_switch_ready",0))
	_inject(3,1000.0,Vector2(256,316),Vector2(0,-500),13)
	await _advance()
	var urgent:Dictionary=await _snapshot()
	check(int(weapon(urgent).get("gun_target",-1))!=second_target and sim_time<previous_ready,"机枪紧迫威胁可抢占切换CD","新目标近且高速逼近，评分提升超过0.35，立即改变锁定",{"weapon":weapon(urgent),"previous_ready":previous_ready,"sim_time":sim_time})
	world.update_settings({"gun_rate":0.0})

func _test_storm_circles()->void:
	for energy in [1,359,360,361,719,720,721,1079,1080,1000001]:
		await reset_weapons()
		var before:Dictionary=await _snapshot()
		var baseline:=accounted(before)
		world.output(0,3,float(energy))
		await _advance()
		var first:Dictionary=await _snapshot()
		var first_state:=weapon(first)
		var total:=mini(1080,energy)
		if total>=360:total=int(total/360)*360
		var rings:=int((total+359)/360)
		var valid_plan:=int(first_state.get("storm_total_shots",0))==total or int(first_state.get("storm_completed_events",0))==1
		check(valid_plan,"风暴%d整数规划最多三圈"%energy,"每圈至多360，输入不足360时只一圈",{"weapon":first_state,"expected_shots":total,"expected_rings":rings})
		var previous_circle:=int(first_state.get("storm_ring",0))
		var ready_time:=float(first_state.get("next_ring_time",0.0))
		var interval_valid:=true
		var state:Dictionary=first
		for i in 96:
			if int(weapon(state).get("storm_completed_events",0))>=1:break
			await _advance()
			state=await _snapshot()
			var w:=weapon(state)
			var circle:=int(w.get("storm_ring",0))
			if circle>previous_circle:
				interval_valid=interval_valid and absf(float(w.get("next_ring_time",0.0))-float(w.get("last_ring_complete_time",-100.0))-0.10)<0.00001
				previous_circle=circle
				ready_time=float(w.get("next_ring_time",0.0))
			elif circle>0 and int(w.get("storm_next_shot",0))>circle*360 and sim_time+0.00001<ready_time:
				interval_valid=false
		var last:=weapon(state)
		check(int(last.get("storm_completed_events",0))==1 and int(last.get("storm_completed_rings",0))==rings and int(state.teams[0].storm)==0 and int(state.metrics[0])==total,"风暴%d发射圈数及库存清空"%energy,"正式GPU持续发射直至事件完成；无额外第四圈",{"weapon":last,"active":state.metrics[0]})
		check(accounted(state)-baseline==energy and normal_energy(state)==energy,"风暴%d整数分配守恒"%energy,"整数商加余数逐发分配，所有真实粒子能量和等于输入",{"accounted_delta":accounted(state)-baseline,"active_energy":normal_energy(state)})
		check(interval_valid,"风暴%d圈间模拟时间间隔"%energy,"下一圈不得早于上一圈完成后的0.10模拟秒",{"sim_time":sim_time,"last_ready":ready_time})

func _test_sniper_integer_split()->void:
	await reset_weapons()
	_inject(0,100.0,Vector2(1022.7,400.0),Vector2(620.0,0.0),12)
	await _advance()
	var first:Dictionary=await _snapshot()
	var energies:Array=[]
	var level_ok:=true
	for shot:Dictionary in first.get("snipers",[]):
		energies.append(int(shot.energy))
		level_ok=level_ok and int(shot.get("sniper_level",-1))==2
	energies.sort()
	check(energies==[30,70] and level_ok,"狙击第一次墙碰70/30整数分裂","100变70+30，父子均二级，读取保留狙击槽",{"snipers":first.get("snipers",[])})
	for i in 60:await _advance(4)
	var second:Dictionary=await _snapshot()
	energies.clear()
	level_ok=true
	for shot:Dictionary in second.get("snipers",[]):
		energies.append(int(shot.energy))
		level_ok=level_ok and int(shot.get("sniper_level",-1))==3
	energies.sort()
	check(energies==[9,21,21,49] and level_ok,"狙击第二次碰撞进入三级且守恒","70→49+21、30→21+9，总能量100；三级最多四颗",{"snipers":second.get("snipers",[])})
	for i in 60:await _advance(4)
	var capped:Dictionary=await _snapshot()
	var total_energy:=0
	for shot:Dictionary in capped.get("snipers",[]):total_energy+=int(shot.energy)
	check(capped.get("snipers",[]).size()==4 and total_energy==100,"三级狙击后续墙碰不再分裂","再运行2模拟秒，保持4颗和整数总能量100",{"snipers":capped.get("snipers",[])})
	await reset_weapons()
	_inject(0,3.0,Vector2(1022.7,400.0),Vector2(620.0,0.0),12)
	await _advance()
	var tiny:Dictionary=await _snapshot()
	var shots:Array=tiny.get("snipers",[])
	check(shots.size()==1 and int(shots[0].energy)==3 and int(shots[0].get("sniper_level",-1))==2,"狙击小能量不制造零能子体","floor(3×3/10)=0；不产生0能量实体",{"snipers":shots})

func _test_shield_growth_and_paint()->void:
	await reset_weapons()
	world.debug_command({"op":10,"team":0,"energy":1000000.0,"gun":0.0,"state":0})
	var before:Dictionary=await _snapshot()
	var radius:=float(before.teams[0].shield_radius)
	sim_time=1800.0
	await _advance()
	var later:Dictionary=await _snapshot()
	check(absf(float(later.teams[0].shield_radius)-radius)<0.001 and int(later.teams[0].shield)==1000000,"护盾不会因世界成长自动收缩","相同能量跨至1800模拟秒，参考能量出生锁定",{"before_radius":radius,"after_radius":later.teams[0].shield_radius})
	await reset_weapons()
	world.debug_command({"op":16,"team":1})
	var initial:Dictionary=await _snapshot()
	var consumed_before:=int(initial.get("consumed_energy",0))
	world.output(0,0,1000.0)
	await _advance(16)
	var painted:Dictionary=await _snapshot("terrain:1040:1")
	var gained:=int(painted.metrics[8])-int(initial.metrics[8])
	var spent:=1000-int(painted.teams[0].shield)
	var consumed_delta:=int(painted.get("consumed_energy",0))-consumed_before
	check(gained>0 and spent==gained and consumed_delta==gained and painted.get("terrain",[])==[0],"护盾从核心向外逐格染色且每格1能量","初始整图敌色，中心格被染，实际新增领土=护盾消耗=累计消耗",{"painted_cells":gained,"shield_spent":spent,"consumed_delta":consumed_delta,"center":painted.get("terrain",[])})

func _test_zero_entities()->void:
	await reset_weapons()
	for op in [11,12,13]:_inject(0,0.0,Vector2(200,200),Vector2(100,0),op)
	await _advance()
	var empty:Dictionary=await _snapshot()
	check(int(empty.metrics[0])==0 and int(empty.metrics[1])==0 and empty.get("snipers",[]).is_empty(),"零能实体不进入物理系统","普通/狙击/大球能量0注入全部拒绝；没有零能碰撞实体",{"metrics":empty.metrics})
