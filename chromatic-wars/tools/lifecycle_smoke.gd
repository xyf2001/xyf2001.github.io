extends SceneTree
var scene: Node
var started := 0
var records: Dictionary = {}

func _initialize() -> void:
	call_deferred("run")

func frames(count: int) -> void:
	for index in count:
		await process_frame

func ready_world() -> bool:
	while not scene.world.active or scene.world.stats.get("teams", []).size() != 4:
		if not scene.world.error_message.is_empty() or Time.get_ticks_msec() - started > 150000:
			return false
		await process_frame
	return true

func run() -> void:
	started = Time.get_ticks_msec()
	scene = load("res://scenes/main.tscn").instantiate()
	root.add_child(scene)
	if not await ready_world():
		print("FAIL：首次GPU启动：", scene.world.error_message)
		quit(1)
		return
	scene.paused = true
	records["initial_memory"] = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
	# 同一帧连点新开局：包含未执行完初始化就被取消的生命周期。
	for index in 3:
		scene._restart()
	if not await ready_world():
		print("FAIL：快速重开后GPU启动：", scene.world.error_message)
		quit(1)
		return
	scene.paused = true
	await frames(16)
	var teams: Array = scene.world.stats.get("teams", [])
	var valid: bool = teams.size() == 4 and scene.retired.is_empty() and scene.pinball.balls.size() == 16
	for team: Dictionary in teams:
		valid = valid and bool(team.alive) and int(team.shield) == 1000000
	records["retired_nodes"] = scene.retired.size()
	records["ball_count"] = scene.pinball.balls.size()
	records["teams"] = teams
	records["final_memory"] = Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)
	records["generation"] = scene.generation
	var output := FileAccess.open("res://artifacts/lifecycle_smoke.json", FileAccess.WRITE)
	output.store_string(JSON.stringify(records, "\t"))
	output.close()
	if not valid:
		print("FAIL：快速重开状态或节点回收：", records)
		quit(1)
		return
	print("PASS：连续3次快速重开，四核心与16球复位，旧GPU节点已全部回收。")
	# 用可调的小最大半径制造真实倍率溢出，验证信号→主控→中文UI整条路径。
	scene.pinball.configure({"radius_max":12.0})
	var ball: Dictionary = scene.pinball.balls[0]
	ball["value"] = PinballPhysics.MAX_EXACT_ENERGY
	scene.pinball._update_radius(ball)
	ball["p"] = Vector2(35.0, 385.0)
	ball["v"] = Vector2(0.0, 20.0)
	scene.paused = false
	scene.one_step = true
	await frames(20)
	if scene.pinball.error.is_empty() or not scene.ui._error.visible or not scene.ui._error.text.contains("精确整数上限") or float(ball["value"]) != PinballPhysics.MAX_EXACT_ENERGY:
		print("FAIL：实际倍率超限未保留原值并显示中文原因")
		quit(1)
		return
	var stopped_time: float = scene.elapsed
	scene.paused = false
	scene.one_step = true
	await frames(12)
	if scene.elapsed != stopped_time:
		print("FAIL：CPU数值故障后仍可继续或单步")
		quit(1)
		return
	print("PASS：真实倍率超限保留原值，阻止继续与单步，中文原因在界面可见。")

	scene.world.shutdown()
	await frames(8)
	quit(0)
