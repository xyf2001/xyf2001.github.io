extends "res://tests/gpu_suite.gd"
## 正式Compute武器契约：读少量team/weapon/sniper槽，绝不CPU代算战斗结果。
var _wrap_fixture_written:=false

func run_suite() -> void:
	if RenderingServer.get_current_rendering_method()!="forward_plus" or RenderingServer.get_current_rendering_driver_name()!="vulkan":
		record("NOT TESTED","武器GPU验证前提","需要普通窗口Forward+ / Vulkan")
		finish()
		return
	Engine.max_fps=0
	world=World.new()
	world.configure({"particle_capacity":4096,"grid_size":64,"render_size":256,"seed":20261017,"gun_rate":0.0,"intro_gun":0.0,"intro_shield":0.0,"sniper_speed":620.0,"ball_speed":92.0,"friendly_particle_collisions":true})
	world.debug_snapshot_ready.connect(_on_snapshot)
	world.failed.connect(func(message:String):runtime_error=message)
	root.add_child(world)
	world.start()
	var deadline:=Time.get_ticks_msec()+240000
	while not world.active and runtime_error.is_empty() and Time.get_ticks_msec()<deadline:await process_frame
	if not check(world.active,"武器真实Compute初始化",runtime_error):
		await _shutdown_world()
		finish()
		return
	await _test_gun_lock_and_cadence()
	await _test_gun_sparse_and_large_integer()
	await _test_gun_refill_phase_and_deadline()
	await _test_gun_full_pool_backpressure()
	await _test_gun_aim_and_switch()
	await _test_gun_target_invalidation_and_reuse()
	await _test_storm_circles()
	await _test_sniper_integer_split()
	await _test_sniper_full_pool_retry()
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
	check(is_equal_approx(float(world.settings.get("gun_discharge_duration",-1.0)),10.0),"机枪库存分摊默认周期为10模拟秒","读取真实默认配置，不以缺失键的测试默认值替代",{"duration":world.settings.get("gun_discharge_duration",-1.0)})
	world.update_settings({"gun_rate":1200.0,"gun_discharge_duration":10.0})
	sim_time=100.0
	var before:Dictionary=await _snapshot()
	var baseline:=accounted(before)
	world.debug_command({"op":5,"team":0,"energy":50003})
	# 首个真实子步建立库存计划，之后独立量测连续射频，不混入命令生效边界。
	await _advance(1,1.0/480.0)
	await _advance(12)
	var first:Dictionary=await _snapshot()
	var first_count:=int(first.get("metrics",[0])[0])
	check(int(weapon(first).get("gun_plan_slots",-1))==12000 and int(weapon(first).get("gun_shot_energy",-1))==4 and int(weapon(first).get("gun_plan_remainder",-1))==2003 and first_count==120,"机枪固定1200射频按库存和T分摊整数能量","E50003、T10、N12000，商4余2003；0.1模拟秒实际发120颗",{"active":first_count,"weapon":weapon(first)})
	check(accounted(first)-baseline==50003,"机枪发射整数总能量守恒","在场+剩余枪库存+累计消耗增量等于50003",{"accounted_delta":accounted(first)-baseline})
	var plan_deadline:=float(weapon(first).get("gun_plan_deadline",-1.0))
	await _advance(120)
	var progressed:Dictionary=await _snapshot()
	check(int(weapon(progressed).get("gun_plan_energy",-1))==50003 and int(weapon(progressed).get("gun_plan_slots",-1))==12000 and int(weapon(progressed).get("gun_shot_energy",-1))==4 and int(weapon(progressed).get("gun_plan_remainder",-1))==2003 and is_equal_approx(float(weapon(progressed).get("gun_plan_deadline",-2.0)),plan_deadline),"机枪无新补给时不随世界进程重新定价","跨越1模拟秒只推进既有计划，原总E/N/商余/截止时刻保持",{"first":weapon(first),"later":weapon(progressed)})
	await reset_weapons()
	world.update_settings({"gun_rate":30.0,"gun_discharge_duration":10.0})
	before=await _snapshot();baseline=accounted(before)
	world.debug_command({"op":5,"team":0,"energy":903})
	await _advance()
	var planned:Dictionary=await _snapshot()
	check(int(weapon(planned).get("gun_plan_slots",-1))==300 and int(weapon(planned).get("gun_shot_energy",-1))==3 and int(weapon(planned).get("gun_plan_remainder",-1))==3,"机枪默认10秒周期实际规划完整库存","低射频30用于隔离容量背压，903均匀分给300个固定时间槽",{"weapon":weapon(planned)})
	await _advance(1200)
	var drained:Dictionary=await _snapshot()
	var energies_valid:=true;var plus_one:=0
	for particle:Dictionary in drained.get("particles",[]):
		energies_valid=energies_valid and int(particle.energy) in [3,4]
		if int(particle.energy)==4:plus_one+=1
	check(int(drained.teams[0].gun)==0 and int(drained.metrics[0])==300 and normal_energy(drained)==903 and energies_valid and plus_one==3,"机枪真实10模拟秒内完整发完903库存","全部300颗保持正整数3或4，仅3颗携带余数，场内总能量903",{"weapon":weapon(drained),"active":drained.metrics[0],"energy":normal_energy(drained),"extra_energy_shots":plus_one,"sim_time":sim_time})
	check(accounted(drained)-baseline==903,"机枪完整默认周期整数总量守恒","没有删除已发实体腾槽；真实模拟10秒后场内+消耗仍为903",{"accounted_delta":accounted(drained)-baseline})
	var stopped_spawn:=int(drained.metrics[16])
	await _advance(12)
	var no_refill:Dictionary=await _snapshot()
	check(int(no_refill.teams[0].gun)==0 and int(no_refill.metrics[16])==stopped_spawn,"机枪库存耗尽不会自动补能或重新开价","无新输入再运行0.1秒，不额外发射或产生新库存",{"spawn_before":stopped_spawn,"spawn_after":no_refill.metrics[16]})
	world.update_settings({"gun_rate":0.0,"gun_discharge_duration":10.0})

func _test_gun_sparse_and_large_integer()->void:
	await reset_weapons()
	world.update_settings({"gun_rate":1200.0,"gun_discharge_duration":0.1})
	var before:Dictionary=await _snapshot();var baseline:=accounted(before)
	world.debug_command({"op":5,"team":0,"energy":7})
	await _advance(6)
	var middle:Dictionary=await _snapshot()
	check(int(weapon(middle).get("gun_plan_slots",-1))==120 and int(weapon(middle).get("gun_shot_energy",-1))==0 and int(weapon(middle).get("gun_plan_remainder",-1))==7 and normal_energy(middle)>0 and normal_energy(middle)<7 and int(middle.teams[0].gun)>0,"机枪E小于计划发数时均匀稀疏发射正能量","E7/N120，周期一半时只发部分正能量，不能前七槽提前耗光或创建0能粒子",{"weapon":weapon(middle),"active_energy":normal_energy(middle),"gun":middle.teams[0].gun})
	await _advance(7)
	var sparse:Dictionary=await _snapshot();var all_positive:=true
	for particle:Dictionary in sparse.get("particles",[]):all_positive=all_positive and int(particle.energy)==1
	check(int(sparse.teams[0].gun)==0 and int(sparse.metrics[0])==7 and normal_energy(sparse)==7 and all_positive and accounted(sparse)-baseline==7,"机枪稀疏计划截止后恰有七颗1能实体","空时间槽不占物理池，全部7能量在T窗分配，没有零能实体或尾数丢失",{"active":sparse.metrics[0],"energy":normal_energy(sparse),"gun":sparse.teams[0].gun,"accounted_delta":accounted(sparse)-baseline})
	await reset_weapons()
	world.update_settings({"gun_rate":1200.0,"gun_discharge_duration":0.1})
	before=await _snapshot();baseline=accounted(before)
	var huge:int=(1<<53)+12345
	var expected_q:int=huge/120;var expected_r:int=huge%120
	# 必须走整数命令编码，不能先传入World.output的float接口而抹掉低位。
	world.debug_command({"op":5,"team":0,"energy":huge})
	await _advance()
	var huge_plan:Dictionary=await _snapshot()
	check(int(weapon(huge_plan).get("gun_plan_energy",-1))==huge and int(weapon(huge_plan).get("gun_shot_energy",-1))==expected_q and int(weapon(huge_plan).get("gun_plan_remainder",-1))==expected_r,"机枪超过2的53次方整数库存精确商余规划","E=2^53+12345直接按u64命令上传，N120的商余不得经过float舍入",{"expected_energy":huge,"expected_q":expected_q,"expected_r":expected_r,"weapon":weapon(huge_plan)})
	await _advance(12)
	var huge_end:Dictionary=await _snapshot();var huge_valid:=true;var plus_one:=0
	for particle:Dictionary in huge_end.get("particles",[]):
		huge_valid=huge_valid and int(particle.energy) in [expected_q,expected_q+1]
		if int(particle.energy)==expected_q+1:plus_one+=1
	check(int(huge_end.teams[0].gun)==0 and int(huge_end.metrics[0])==120 and normal_energy(huge_end)==huge and huge_valid and plus_one==expected_r and accounted(huge_end)-baseline==huge,"机枪64位库存全部发完仍逐发整数守恒","120颗各为商或商加1，余数颗数精确匹配，总和仍包含2^53以上低位",{"active":huge_end.metrics[0],"energy":normal_energy(huge_end),"expected_energy":huge,"extra_energy_shots":plus_one,"expected_r":expected_r,"accounted_delta":accounted(huge_end)-baseline})
	world.update_settings({"gun_rate":0.0,"gun_discharge_duration":10.0})

func _test_gun_refill_phase_and_deadline()->void:
	var locked:Dictionary=await _gun_target_fixture(Vector2(456,256),Vector2(-40,0))
	# 相位属于连续射击，不假设前一夹具恰好以0结束；用真实短步推进到0.5。
	var phase_to_half:=fposmod(0.5-float(locked.teams[0].get("gun_phase",-1000.0)),1.0)
	if phase_to_half>0.000001:await _advance(1,phase_to_half/1200.0)
	var aimed:Dictionary=await _snapshot();var before_phase:=float(aimed.teams[0].get("gun_phase",-1000.0));var before_spawn:=int(aimed.metrics[16])
	world.debug_command({"op":5,"team":0,"energy":1000})
	await _advance(1,1.0/480.0)
	var refilled_aim:Dictionary=await _snapshot()
	var expected_phase:=fposmod(before_phase+1200.0/480.0,1.0)
	check(absf(before_phase-0.5)<0.0001 and absf(float(refilled_aim.teams[0].get("gun_phase",-1000.0))-expected_phase)<0.0001 and int(refilled_aim.metrics[16])-before_spawn==3,"机枪补弹不重置连续射击小数相位","phase0.5再推进2.5槽应发3颗并回0；若补弹清phase只会错误发2颗",{"before_phase":before_phase,"after_phase":refilled_aim.teams[0].get("gun_phase",-1000.0),"spawn_delta":int(refilled_aim.metrics[16])-before_spawn})
	check(int(weapon(refilled_aim).get("gun_target",-1))==int(weapon(aimed).get("gun_target",-2)) and int(weapon(refilled_aim).get("gun_target_generation",-1))==int(weapon(aimed).get("gun_target_generation",-2)) and is_equal_approx(float(weapon(refilled_aim).get("target_switch_ready",0)),float(weapon(aimed).get("target_switch_ready",-1))),"机枪补弹重规划库存不重置瞄准身份和CD","补弹仅更换库存分摊计划，当前有效目标与0.5秒切换期限保留",{"before":weapon(aimed),"after":weapon(refilled_aim)})
	await reset_weapons()
	world.update_settings({"gun_rate":1200.0,"gun_discharge_duration":0.1})
	var initial:Dictionary=await _snapshot();var baseline:=accounted(initial)
	world.debug_command({"op":5,"team":0,"energy":903})
	await _advance(1,1.0/480.0)
	var before:Dictionary=await _snapshot();var remaining:=int(before.teams[0].gun);before_spawn=int(before.metrics[16])
	world.debug_command({"op":5,"team":0,"energy":600})
	await _advance(1,1.0/480.0)
	var planned:Dictionary=await _snapshot();var old_step_energy:=normal_energy(planned)-normal_energy(before);var total:=remaining+600-old_step_energy
	check(int(weapon(planned).get("gun_plan_energy",-1))==total and int(weapon(planned).get("gun_plan_slots",-1))==120 and int(weapon(planned).get("gun_shot_energy",-1))==int(total/120) and int(weapon(planned).get("gun_plan_remainder",-1))==total%120 and float(weapon(planned).get("gun_plan_deadline",0))>float(weapon(before).get("gun_plan_deadline",0)),"机枪补弹按剩余库存加新输入重新分摊并重启T窗","已经发出的粒子不回收；只对当前剩余加600重算120槽商余和新截止",{"remaining_before":remaining,"input":600,"expected_total":total,"before":weapon(before),"after":weapon(planned)})
	var new_plan_spawn:=int(planned.metrics[16])
	await _advance(13)
	var ended:Dictionary=await _snapshot()
	check(int(ended.teams[0].gun)==0 and int(ended.metrics[16])-new_plan_spawn==120 and normal_energy(ended)==1503 and accounted(ended)-baseline==1503,"机枪重新分摊的全部余量在新T窗内发完","补弹子步先完成旧计划到期发射；随后新计划恰发120颗，总能量仍903+600",{"weapon":weapon(ended),"new_plan_spawn_delta":int(ended.metrics[16])-new_plan_spawn,"old_step_spawn_delta":new_plan_spawn-before_spawn,"old_step_energy":old_step_energy,"energy":normal_energy(ended),"accounted_delta":accounted(ended)-baseline})
	world.update_settings({"gun_rate":0.0,"gun_discharge_duration":10.0})

func _test_gun_full_pool_backpressure()->void:
	await reset_weapons()
	world.update_settings({"gun_rate":1200.0,"gun_discharge_duration":0.1})
	var initial:Dictionary=await _snapshot();var baseline:=accounted(initial);var consumed_before:=int(initial.get("consumed_energy",0))
	world.debug_command({"op":17,"team":0,"count":4096,"energy":1,"vx":0.01,"vy":0.0})
	world.debug_command({"op":5,"team":0,"energy":367})
	await _advance(24)
	var blocked:Dictionary=await _snapshot()
	check(int(blocked.metrics[0])==4096 and int(blocked.teams[0].gun)==367 and accounted(blocked)-baseline==4463,"机枪满池超过计划T仍保留全部未发能量","真实4096实体满池，0.2秒超过T0.1时不得丢367库存、强行吞槽或假发零能实体",{"active":blocked.metrics[0],"gun":blocked.teams[0].gun,"weapon":weapon(blocked),"accounted_delta":accounted(blocked)-baseline})
	world.debug_command({"op":15,"team":1,"energy":0,"count":1})
	await _advance(1,1.0/480.0)
	var freed:Dictionary=await _snapshot()
	check(int(freed.metrics[0])==4095 and int(freed.teams[0].gun)==367 and int(freed.consumed_energy)-consumed_before==1,"机枪等待事件末真实回收空槽","一颗1能粒子实际染敌格退出，prepare不能提前使用尚未回收的槽",{"active":freed.metrics[0],"gun":freed.teams[0].gun,"consumed_delta":int(freed.consumed_energy)-consumed_before})
	await _advance(1,1.0/480.0)
	var resumed:Dictionary=await _snapshot();var spent:=367-int(resumed.teams[0].gun)
	check(int(resumed.metrics[0])==4096 and spent in [3,4] and int(resumed.metrics[16])-int(freed.metrics[16])==1 and accounted(resumed)-baseline==4463,"机枪空槽释放后恢复未发计划且整数守恒","只复用一个真实回收槽，发出原商余3或4能量，超过T的背压不丢弹药",{"active":resumed.metrics[0],"gun_spent":spent,"spawn_delta":int(resumed.metrics[16])-int(freed.metrics[16]),"accounted_delta":accounted(resumed)-baseline})
	world.update_settings({"gun_rate":0.0,"gun_discharge_duration":10.0})

func _test_gun_aim_and_switch()->void:
	await reset_weapons()
	check(is_equal_approx(float(world.settings.get("gun_target_switch_cd",-1.0)),0.5),"机枪默认目标切换CD为0.5模拟秒","验证正式配置默认值，不用夹具覆盖旧0.08值冒充新默认",{"configured_cd":world.settings.get("gun_target_switch_cd",-1.0)})
	world.update_settings({"gun_rate":1200.0,"gun_discharge_duration":10.0,"gun_target_switch_cd":0.5})
	world.output(0,4,1000000.0)
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
	_inject(1,1000.0,Vector2(456,256),Vector2(-40,20),13)
	await _advance()
	var first:Dictionary=await _snapshot()
	var first_target:=int(weapon(first).get("gun_target",-1))
	check(first_target>=4096 and int(weapon(first).get("gun_target_generation",0))>0 and float(first.teams[0].get("gun_mode",0))>=2.0,"机枪迫近大球防御优先于补地","真实敌球进入近防范围，锁定其physical ID和出生代并切换防御模式",{"weapon":weapon(first),"team":first.teams[0]})
	_inject(2,1000.0,Vector2(256,61),Vector2(0,40),13)
	await _advance()
	var during_cd:Dictionary=await _snapshot()
	var ready_time:=float(weapon(first).get("target_switch_ready",0))
	check(int(weapon(during_cd).get("gun_target",-2))==first_target and sim_time<ready_time,"机枪轻微评分差遵守目标切换CD","略近的第二目标在0.5模拟秒内不导致来回跳锁",{"first":weapon(first),"during_cd":weapon(during_cd),"sim_time":sim_time})
	# 高分威胁仍必须等待有效原目标的0.5秒；位置保证等待期间不会撞到核心。
	_inject(3,1000.0,Vector2(256,356),Vector2(0,-120),13)
	await _advance()
	var urgent:Dictionary=await _snapshot()
	check(int(weapon(urgent).get("gun_target",-1))==first_target and sim_time<ready_time and is_equal_approx(float(weapon(urgent).get("target_switch_ready",0)),ready_time),"机枪高分新威胁也不得抢占有效原目标","取消旧+0.35抢占例外；新近身威胁出现时目标身份与到期时间均保持",{"weapon":weapon(urgent),"first":weapon(first),"sim_time":sim_time})
	var before_angle:=float(urgent.teams[0].get("gun_target_angle",0))
	var before_energy:=accounted(urgent)
	var before_spawn:=int(urgent.metrics[16])
	var before_gun:=int(urgent.teams[0].gun)
	await _advance(24)
	var tracked:Dictionary=await _snapshot()
	var tracked_angle:=float(tracked.teams[0].get("gun_target_angle",0))
	check(int(weapon(tracked).get("gun_target",-1))==first_target and sim_time<ready_time and absf(angle_difference(before_angle,tracked_angle))>0.005 and absf(angle_difference(float(tracked.teams[0].gun_angle),tracked_angle))<0.08,"机枪0.5秒锁定身份期间持续追踪移动目标","原目标横向位移使目标角和实际炮口角连续改变，不锁死旧角度",{"before_angle":before_angle,"tracked_angle":tracked_angle,"team":tracked.teams[0],"weapon":weapon(tracked)})
	var fired:=int(tracked.metrics[16])-before_spawn
	var gun_spent:=before_gun-int(tracked.teams[0].gun)
	check(fired==240 and gun_spent>0 and gun_spent==normal_energy(tracked)-normal_energy(urgent),"机枪锁定和目标切换CD不降低1200固定射速","0.2模拟秒真实发出240颗；单发由库存T计划决定，枪减少能量等于真实发出能量",{"fired":fired,"gun_spent":gun_spent,"active_energy_added":normal_energy(tracked)-normal_energy(urgent)})
	check(accounted(tracked)==before_energy,"机枪目标保持期间整数能量守恒","无新增输入的追踪窗口，在场+库存+累计实际消耗保持相等",{"before":before_energy,"after":accounted(tracked)})
	var steps_to_ready:=maxi(1,int(ceil((ready_time-sim_time)/(1.0/120.0)))+1)
	await _advance(steps_to_ready)
	var switched:Dictionary=await _snapshot()
	var next_target:=int(weapon(switched).get("gun_target",-1))
	check(sim_time>=ready_time and next_target>=4096 and next_target!=first_target and float(weapon(switched).get("target_switch_ready",0))>ready_time,"机枪0.5秒期限后允许切换更高分目标","原目标在期限内有效，过期后才切向更高分近身目标并重开0.5秒CD",{"weapon":weapon(switched),"first_ready":ready_time,"sim_time":sim_time,"team":switched.teams[0]})
	world.update_settings({"gun_rate":0.0})

func _gun_target_fixture(position:Vector2,velocity:Vector2)->Dictionary:
	await reset_weapons()
	world.update_settings({"gun_rate":1200.0,"gun_discharge_duration":10.0,"gun_target_switch_cd":0.5})
	world.output(0,4,1000000.0)
	_inject(1,1000.0,position,velocity,13)
	await _advance()
	return await _snapshot()

func _ball_physical_id(ball:Dictionary)->int:
	# balls读回只覆盖大球缓冲尾段，id是该段0..63；武器锁保存全粒子物理ID。
	return int(world.settings.particle_capacity)+int(ball.id)

func _write_generation_wrap_fixture_rd(physical_id:int,contact_mask:int)->void:
	# 仅测试罕见28位回卷边界，不改能量/运动/活跃列表；随后仍由实际Compute重生。
	var words:=PackedByteArray()
	words.resize(4)
	words.encode_u32(0,0xfffffff0 | (contact_mask & 15))
	world._rd.buffer_update(world._buffers[0],physical_id*64+48,4,words)
	words.encode_u32(0,1)
	world._rd.buffer_update(world._buffers[9],12,4,words)
	call_deferred("_mark_generation_wrap_written")

func _mark_generation_wrap_written()->void:
	_wrap_fixture_written=true

func _test_gun_target_invalidation_and_reuse()->void:
	var locked:Dictionary=await _gun_target_fixture(Vector2(456,256),Vector2(-40,0))
	var old_target:=int(weapon(locked).get("gun_target",-1))
	var old_generation:=int(weapon(locked).get("gun_target_generation",0))
	var old_ready:=float(weapon(locked).get("target_switch_ready",0))
	world.debug_command({"op":14})
	await _advance()
	var died:Dictionary=await _snapshot()
	check(old_target==4096 and old_generation>0 and sim_time<old_ready and int(weapon(died).get("gun_target",-1))==4294967295 and float(died.teams[0].get("gun_mode",0))<2.0,"机枪原目标死亡后立即解除身份锁定","真实debug清除实体后尚未到0.5秒，不继续瞄准失效物理槽",{"locked":weapon(locked),"after":weapon(died),"sim_time":sim_time})

	locked=await _gun_target_fixture(Vector2(456,256),Vector2(-40,0))
	old_target=int(weapon(locked).get("gun_target",-1));old_generation=int(weapon(locked).get("gun_target_generation",0));old_ready=float(weapon(locked).get("target_switch_ready",0))
	# 同批清除后重用相同slot，中间不推进；旧ID仍非空，只有出生代可识别新生命。
	world.debug_command({"op":14})
	_inject(2,1000.0,Vector2(256,456),Vector2(0,-40),13)
	await _advance()
	var reused:Dictionary=await _snapshot()
	var new_generation:=int(weapon(reused).get("gun_target_generation",0))
	var matching_generation:=-1
	for ball:Dictionary in reused.get("balls",[]):
		if _ball_physical_id(ball)==old_target:matching_generation=int(ball.get("generation",-1))
	check(int(weapon(reused).get("gun_target",-1))==old_target and new_generation>old_generation and new_generation==matching_generation and sim_time<old_ready and float(weapon(reused).get("target_switch_ready",0))>old_ready,"机枪同物理槽重生立即按新实体重锁","op14与新op13同批执行，ID相同但generation增加，CD必须以新生命重置",{"before":weapon(locked),"after":weapon(reused),"particle_generation":matching_generation,"sim_time":sim_time})
	check(absf(angle_difference(float(reused.teams[0].get("gun_target_angle",0)),PI/2.0))<0.02,"机枪槽位重用不沿旧实体位置瞄准","相同槽由东侧改为南侧，新一代目标角立即朝南，旧角度不可残留",{"team":reused.teams[0]})

	locked=await _gun_target_fixture(Vector2(456,256),Vector2(-40,0))
	old_target=int(weapon(locked).get("gun_target",-1));old_ready=float(weapon(locked).get("target_switch_ready",0))
	if not check(old_target==4096,"机枪回卷夹具先锁定有效物理槽","只有确认4096已是有效目标才允许窄范围修改该槽代数",{"weapon":weapon(locked)}):
		return
	var contact_mask:=0
	for ball:Dictionary in locked.get("balls",[]):
		if _ball_physical_id(ball)==old_target:contact_mask=int(ball.get("contact_mask",0))
	_wrap_fixture_written=false
	RenderingServer.call_on_render_thread(_write_generation_wrap_fixture_rd.bind(old_target,contact_mask))
	var write_deadline:=Time.get_ticks_msec()+10000
	while not _wrap_fixture_written and Time.get_ticks_msec()<write_deadline:await process_frame
	if not check(_wrap_fixture_written,"机枪28位出生代回卷夹具写入","只把已有实体代数设为最大值并模拟旧gen1缓存，不代算任何碰撞或能量"):
		return
	world.debug_command({"op":14})
	_inject(2,1000.0,Vector2(256,456),Vector2(0,-40),13)
	await _advance()
	var wrapped:Dictionary=await _snapshot()
	check(int(weapon(wrapped).get("gun_target",-1))==old_target and int(weapon(wrapped).get("gun_target_generation",0))==1 and sim_time<old_ready and float(weapon(wrapped).get("target_switch_ready",0))>old_ready,"机枪出生代最大值回卷不误认旧gen1生命","真实重生max→1时必须使残留同ID旧gen1锁失效，重新锁定并刷新0.5秒期限",{"old_ready":old_ready,"after":weapon(wrapped),"balls":wrapped.get("balls",[]),"sim_time":sim_time})

	locked=await _gun_target_fixture(Vector2(456,256),Vector2(-40,0))
	old_ready=float(weapon(locked).get("target_switch_ready",0))
	world.debug_command({"op":14})
	_inject(0,1000.0,Vector2(456,256),Vector2(-40,0),13)
	_inject(2,1000.0,Vector2(256,456),Vector2(0,-40),13)
	await _advance()
	var friendly:Dictionary=await _snapshot()
	check(sim_time<old_ready and int(weapon(friendly).get("gun_target",-1))==4097,"机枪缓存槽成为己方后立即重选敌方","同批重用原槽为己方球，不能因未到CD继续锁己方；重选实际敌方4097",{"weapon":weapon(friendly),"balls":friendly.get("balls",[]),"sim_time":sim_time})

	locked=await _gun_target_fixture(Vector2(456,256),Vector2(-40,0))
	old_ready=float(weapon(locked).get("target_switch_ready",0))
	world.debug_command({"op":14})
	_inject(1,1000.0,Vector2(800,256),Vector2(-40,0),13)
	_inject(2,1000.0,Vector2(256,456),Vector2(0,-40),13)
	await _advance()
	var outside:Dictionary=await _snapshot()
	check(sim_time<old_ready and int(weapon(outside).get("gun_target",-1))==4097,"机枪缓存目标超出防守范围立即重选","原物理槽位于世界x800，明显超过核心附近防守半径；不等CD才选择近敌",{"weapon":weapon(outside),"balls":outside.get("balls",[]),"sim_time":sim_time})

	# 原实体不换代：先处于近身紧急范围，随后自然向外飞离，必须即时失效。
	locked=await _gun_target_fixture(Vector2(361,256),Vector2(500,0))
	old_target=int(weapon(locked).get("gun_target",-1));old_generation=int(weapon(locked).get("gun_target_generation",0));old_ready=float(weapon(locked).get("target_switch_ready",0))
	_inject(2,1000.0,Vector2(256,456),Vector2(0,-40),13)
	await _advance(3)
	var receding:Dictionary=await _snapshot()
	var original_survives:=false
	for ball:Dictionary in receding.get("balls",[]):
		if _ball_physical_id(ball)==old_target and int(ball.get("generation",-1))==old_generation and float(ball.vx)>0.0:original_survives=true
	check(old_target==4096 and old_generation>0 and original_survives and sim_time<old_ready and int(weapon(receding).get("gun_target",-1))==4097,"机枪原实体不再有效逼近立即重选","旧球保持同代存活，真实向外运动离开近身保护范围后立即改锁逼近敌球",{"before":weapon(locked),"after":weapon(receding),"balls":receding.get("balls",[]),"sim_time":sim_time})
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

func _legal_right_wall_start()->Vector2:
	# 1.5.1首轮旧1022.7夹具在r1.4时已越墙0.1；真实TOI必须从合法位置出发。
	return Vector2(1024.0-float(world.settings.particle_radius)-0.1,400.0)

func _test_sniper_integer_split()->void:
	await reset_weapons()
	var wall_start:=_legal_right_wall_start()
	var radius:=float(world.settings.particle_radius)
	check(wall_start.x+radius<1024.0 and wall_start.x+radius+620.0/480.0>1024.0,"狙击墙碰夹具合法且真实跨越边界","按当前真实半径从world-r-0.1出生，先不穿墙，1/480秒内确实撞实体墙",{"start_x":wall_start.x,"radius":radius,"gap":1024.0-wall_start.x-radius})
	_inject(0,100.0,wall_start,Vector2(620.0,0.0),12)
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
	_inject(0,3.0,_legal_right_wall_start(),Vector2(620.0,0.0),12)
	await _advance()
	var tiny:Dictionary=await _snapshot()
	var shots:Array=tiny.get("snipers",[])
	check(shots.size()==1 and int(shots[0].energy)==3 and int(shots[0].get("sniper_level",-1))==2,"狙击小能量不制造零能子体","floor(3×3/10)=0；不产生0能量实体",{"snipers":shots})

func _test_sniper_full_pool_retry()->void:
	await reset_weapons()
	var initial:Dictionary=await _snapshot()
	var baseline:=accounted(initial)
	var consumed_before:=int(initial.get("consumed_energy",0))
	# 4095个真实普通实体占满常规池与七个保留槽，最后一个保留槽注入狙击。
	# .01避免op17把近零向量回退为(30,17)；这几步仍留在原格。
	world.debug_command({"op":17,"team":0,"count":4095,"energy":1,"vx":0.01,"vy":0.0})
	_inject(0,100.0,_legal_right_wall_start(),Vector2(620.0,0.0),12)
	# 1/480秒只产生一个真实GPU物理子步，能区分事件阶段和后续回收阶段。
	var one_substep:=1.0/480.0
	await _advance(1,one_substep)
	var full:Dictionary=await _snapshot()
	var full_shots:Array=[]
	for particle:Dictionary in full.get("particles",[]):
		if int(particle.type)==2:full_shots.append(particle)
	check(int(full.metrics[0])==4096 and full_shots.size()==1 and int(full_shots[0].energy)==100 and bool(full_shots[0].pending_split),"满池狙击分裂保留待重试状态","真实墙碰后没有空槽，保持100能量，不提前扣除30%或丢失请求",{"active":full.metrics[0],"snipers":full_shots})
	# 网格0只覆盖(8,8)这一颗；它按真实领土规则耗尽并在mode12回收。
	world.debug_command({"op":15,"team":1,"energy":0,"count":1})
	await _advance(1,one_substep)
	var reclaimed:Dictionary=await _snapshot()
	var waiting:Array=[]
	for particle:Dictionary in reclaimed.get("particles",[]):
		if int(particle.type)==2:waiting.append(particle)
	check(int(reclaimed.metrics[0])==4095 and int(reclaimed.consumed_energy)-consumed_before==1 and waiting.size()==1 and bool(waiting[0].pending_split),"狙击分裂等待真实槽位回收","一颗普通粒子染敌格消耗1；事件阶段不能复用尚未完成回收的槽",{"active":reclaimed.metrics[0],"consumed_delta":int(reclaimed.consumed_energy)-consumed_before,"snipers":waiting})
	await _advance(1,one_substep)
	var retried:Dictionary=await _snapshot()
	var energies:Array=[]
	var valid:=true
	for particle:Dictionary in retried.get("particles",[]):
		if int(particle.type)!=2:continue
		energies.append(int(particle.energy))
		valid=valid and int(particle.sniper_level)==2 and not bool(particle.pending_split)
	energies.sort()
	check(energies==[30,70] and valid and int(retried.metrics[0])==4096 and accounted(retried)-baseline==4195,"空槽出现后无新墙碰仍重试70/30分裂","两颗狙击从全池筛选；场内4194加已消耗1等于输入4195",{"energies":energies,"active":retried.metrics[0],"accounted_delta":accounted(retried)-baseline,"consumed_delta":int(retried.consumed_energy)-consumed_before})
	await _advance(3,one_substep)
	var settled:Dictionary=await _snapshot()
	var sniper_count:=0
	for particle:Dictionary in settled.get("particles",[]):
		if int(particle.type)==2:sniper_count+=1
	check(sniper_count==2 and int(weapon(settled).get("sniper_split_count",-1))==1 and accounted(settled)-baseline==4195,"延期分裂完成后不会每步重复执行","清除pending后继续真实推进，仍只有两颗狙击及一次分裂",{"sniper_count":sniper_count,"weapon":weapon(settled),"accounted_delta":accounted(settled)-baseline})

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
