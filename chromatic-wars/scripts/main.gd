extends Node2D
## 主控只推进固定时间、16颗弹药球和UI。右侧实体没有CPU逐粒子循环。

const BATTLE_RECT := Rect2(530, 112, 850, 850)
var settings: Dictionary = {}
var pinball: PinballPhysics
var world: GPUWorld
var ui: GameUI
var battle_view: TextureRect
var labels: BattleLabels
var active_dt := 1.0 / 120.0
var elapsed := 0.0
var accumulator := 0.0
var paused := false
var one_step := false
var status_clock := 0.0
var generation := 0
var retired: Array[GPUWorld] = []
var trigger_history: Array[Dictionary] = []
var first_texture := false
var font: Font
var editor_mode := false
var editor_preview: Node2D
var quitting := false
var rescue_attempts: Dictionary = {}

func _ready() -> void:
	font = ThemeDB.fallback_font
	if ResourceLoader.exists("res://assets/chinese_ui.otf"):
		font = load("res://assets/chinese_ui.otf")
	settings = GameSettings.load_file()
	battle_view = TextureRect.new()
	battle_view.position = BATTLE_RECT.position
	battle_view.size = BATTLE_RECT.size
	battle_view.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	battle_view.stretch_mode = TextureRect.STRETCH_SCALE
	battle_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	battle_view.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(battle_view)
	labels = BattleLabels.new()
	labels.font = font
	add_child(labels)
	pinball = PinballPhysics.new()
	pinball.font = font
	pinball.position = Vector2(22, 112)
	add_child(pinball)
	editor_preview = Node2D.new()
	editor_preview.z_index = 100
	editor_preview.draw.connect(_draw_editor_preview)
	add_child(editor_preview)
	pinball.weapon_output.connect(_weapon_output)
	pinball.trigger_log.connect(_trigger_log)
	pinball.simulation_fault.connect(func(message: String):
		paused = true
		push_error(message)
	)
	ui = GameUI.new()
	add_child(ui)
	ui.setup(settings)
	ui.pause_pressed.connect(_toggle_pause)
	ui.step_pressed.connect(func(): paused = true; one_step = true)
	ui.restart_pressed.connect(_restart)
	ui.speed_changed.connect(func(value: float): settings["time_scale"] = value)
	ui.settings_changed.connect(_settings_changed)
	ui.debug_requested.connect(_debug_requested)
	ui.editor_mode_changed.connect(_set_editor_mode)
	ui.clear_custom_pegs_requested.connect(_clear_custom_pegs)
	ui.restore_preset_pegs_requested.connect(_restore_preset_pegs)
	ui.clear_all_pegs_requested.connect(_clear_all_pegs)
	ui.performance_preset_requested.connect(_performance_preset)
	get_tree().auto_accept_quit = false
	_restart()

func _restart() -> void:
	if quitting: return
	_set_editor_mode(false)
	generation += 1
	var old_world: GPUWorld = world
	if old_world != null:
		old_world.shutdown()
		# RD释放排在渲染线程队列；延后回收节点，让小表异步回调先完成。
		retired.append(old_world)
		old_world.set_process(false)
	world = GPUWorld.new()
	# 同步释放快路径也必须看到新引用，否则退役函数会把旧对象误认成当前world而跳过回收。
	if old_world != null:
		_dispose_retired(old_world)
	add_child(world)
	world.configure(settings)
	var current_generation := generation
	world.initialized.connect(func():
		if current_generation == generation:
			battle_view.texture = world.texture
			first_texture = true
			queue_redraw()
			print("运行：GPU共享纹理已绑定，未使用整帧CPU回读。")
	)
	world.failed.connect(func(message: String):
		if current_generation == generation:
			paused = true
			push_error("战场停止：" + message)
	)
	world.rescue_requested.connect(func(team: int):
		if current_generation != generation: return
		var energy := pinball.rescue(team)
		var teams: Array = world.stats.get("teams", [])
		var nonce := int(teams[team].get("request_nonce", 0)) if team < teams.size() else 0
		rescue_attempts[team] = {"nonce": nonce, "energy": energy, "reported": false}
		world.resolve_rescue(team, energy)
		ui.show_rescue_feedback(team, "保命触发，正在补盾 +%.0f" % energy if energy > 0.0 else "保命失败：没有可用弹药球")
		print("紧急保命：阵营%d，球能量 %.0f，模拟时间 %.3f" % [team, energy, elapsed])
	)
	world.stats_updated.connect(func(data: Dictionary):
		if current_generation == generation:
			_update_rescue_feedback(data)
	)
	world.team_eliminated.connect(func(team: int):
		if current_generation != generation: return
		var teams: Array = world.stats.get("teams", [])
		var cd := float(teams[team].get("rescue_cd", 0.0)) if team < teams.size() else 0.0
		var attempt: Dictionary = rescue_attempts.get(team, {})
		if not attempt.is_empty() and float(attempt.get("energy", 0.0)) <= 0.0:
			ui.show_rescue_feedback(team, "保命失败：没有可用弹药球")
		elif cd > 0.0:
			ui.show_rescue_feedback(team, "已保命补盾，冷却内再次被击破" if not attempt.is_empty() else "保命冷却中，无法再次触发")
		else:
			ui.show_rescue_feedback(team, "核心被击破，未获得有效救援")
		var values := pinball.eliminate(team)
		world.death_balls(team, values)
		print("确认淘汰：阵营%d，余波球数%d，模拟时间 %.3f" % [team, values.size(), elapsed])
	)
	elapsed = 0.0
	active_dt = float(settings.get("fixed_dt", 1.0 / 120.0))
	labels.stats = {}
	accumulator = 0.0
	paused = false
	one_step = false
	first_texture = false
	battle_view.texture = null
	trigger_history.clear()
	rescue_attempts.clear()
	ui.clear_rescue_feedback()
	settings["font"] = font
	pinball.configure(settings)
	pinball.reset(int(settings.get("seed", 20261016)))
	Engine.max_fps = int(settings.get("fps_limit", 60))
	world.start()
	queue_redraw()

func _update_rescue_feedback(data: Dictionary) -> void:
	var teams: Array = data.get("teams", [])
	for team: int in rescue_attempts:
		var attempt: Dictionary = rescue_attempts[team]
		if bool(attempt.get("reported", false)) or team >= teams.size():
			continue
		var state: Dictionary = teams[team]
		if int(state.get("request_nonce", -1)) != int(attempt.nonce) or bool(state.get("pending", false)):
			continue
		var energy := float(attempt.energy)
		if energy > 0.0:
			ui.show_rescue_feedback(team, "保命成功：补盾 +%.0f" % energy if bool(state.get("alive", false)) else "已保命补盾，后续攻击再次击破")
		elif bool(state.get("alive", false)):
			ui.show_rescue_feedback(team, "常规补盾已解除本次危险")
		else:
			ui.show_rescue_feedback(team, "保命失败：没有可用弹药球")
		attempt["reported"] = true

func _dispose_retired(old: GPUWorld) -> void:
	# 旧回调仍绑定该节点。真正收到RD释放确认且回调归还后才可回收。
	while is_instance_valid(old) and not old.is_shutdown_complete():
		await get_tree().process_frame
	if is_instance_valid(old) and old != world:
		retired.erase(old)
		old.queue_free()

func _process(delta: float) -> void:
	if editor_preview != null and editor_mode and paused:
		editor_preview.queue_redraw()
	if world == null: return
	if not pinball.error.is_empty():
		paused = true
		one_step = false
	if world.active and pinball.error.is_empty():
		var dt := active_dt
		if not paused:
			# 真实帧时长只为固定步提供预算；所有游戏计时使用下方推进的模拟秒。
			accumulator += delta * float(settings.get("time_scale", 0.25))
		var steps := 0
		while ((not paused and accumulator >= dt) or one_step) and steps < 8:
			elapsed += dt
			pinball.step(dt, elapsed)
			if not pinball.error.is_empty():
				one_step = false
				break
			world.step(dt, elapsed)
			if one_step:
				one_step = false
				break
			accumulator -= dt
			steps += 1
		# 超负荷时保留积压，绝不把时间/伤害/弹药静默丢弃。
		world.flush()
	labels.stats = world.stats
	labels.queue_redraw()
	# UI 刷新以真实时间节流，暂停时仍可读参数；不参与任何游戏倒计时。
	status_clock += delta
	if status_clock >= 0.10:
		status_clock = 0.0
		ui.update_state({"sim_time": elapsed, "paused": paused,
			"fixed_dt": active_dt, "fps": Engine.get_frames_per_second(), "gpu_active": world.active,
			"error": pinball.error if not pinball.error.is_empty() else world.error_message, "stats": world.stats,
			"pinball": pinball.snapshot(), "time_backlog": accumulator,
			"settings": settings})
	if not first_texture:
		queue_redraw()

func _weapon_output(team: int, kind: int, energy: float) -> void:
	if world != null: world.output(team, kind, energy, elapsed)

func _trigger_log(data: Dictionary) -> void:
	trigger_history.append(data)
	if trigger_history.size() > 256: trigger_history.pop_front()

func _settings_changed(config: Dictionary) -> void:
	var previous := settings
	settings = GameSettings.validate(config)
	settings["font"] = font
	pinball.configure(settings)
	settings["custom_pegs"] = pinball.custom_pegs.duplicate()
	settings["disabled_preset_pegs"] = pinball.disabled_preset_pegs.duplicate()
	ui.sync_editor_config(settings)
	Engine.max_fps = int(settings.get("fps_limit", 60))
	if world != null and world.has_method("update_settings"):
		world.call("update_settings", settings)
	# 容量、地图精度和输出纹理在面板标明新开局生效；此处不隐式重建。
	if float(previous.get("time_scale", 0.25)) != float(settings.get("time_scale", 0.25)):
		accumulator = 0.0

func _toggle_pause() -> void:
	paused = not paused
	if not paused and editor_mode:
		_set_editor_mode(false)

func _set_editor_mode(enabled: bool) -> void:
	editor_mode = enabled
	if enabled:
		paused = true
		one_step = false
	if ui != null:
		ui.set_editor_mode(enabled)
	if editor_preview != null:
		editor_preview.queue_redraw()

func _save_editor_layout() -> void:
	settings["custom_pegs"] = pinball.custom_pegs.duplicate()
	settings["disabled_preset_pegs"] = pinball.disabled_preset_pegs.duplicate()
	var save_error := GameSettings.save_file(settings)
	if save_error != OK:
		push_warning("固定柱已在当前游戏生效，但保存布局失败：%s" % error_string(save_error))
	ui.sync_editor_config(settings)

func _clear_custom_pegs() -> void:
	settings["custom_pegs"] = []
	pinball.configure(settings)
	_save_editor_layout()

func _restore_preset_pegs() -> void:
	pinball.restore_preset_pegs()
	_save_editor_layout()

func _clear_all_pegs() -> void:
	pinball.clear_all_pegs()
	_save_editor_layout()

func _performance_preset() -> void:
	# 只应用分圈风暴参数；不降低画面、领土精度或真实碰撞。
	settings["storm_ring_particles"] = 360
	settings["storm_ring_interval"] = 0.10
	settings = GameSettings.validate(settings)
	var save_error := GameSettings.save_file(settings)
	if save_error != OK:
		push_warning("流畅预设保存失败：%s" % error_string(save_error))
	ui.sync_editor_config(settings)
	_restart()

func _unhandled_input(event: InputEvent) -> void:
	if not editor_mode or not paused or not (event is InputEventMouseButton):
		return
	if not event.pressed or event.button_index not in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		return
	var local_position := pinball.get_local_mouse_position()
	if not Rect2(Vector2.ZERO, Vector2(pinball.WIDTH, pinball.HEIGHT)).has_point(local_position):
		return
	var changed := false
	if event.button_index == MOUSE_BUTTON_LEFT:
		changed = pinball.add_custom_peg(local_position, float(settings.get("peg_radius", 6.0)))
	else:
		changed = pinball.remove_peg(local_position)
	if changed:
		_save_editor_layout()
	get_viewport().set_input_as_handled()

func _draw_editor_preview() -> void:
	if not editor_mode or not paused or pinball == null:
		return
	var point := pinball.get_local_mouse_position()
	if not Rect2(Vector2.ZERO, Vector2(pinball.WIDTH, pinball.HEIGHT)).has_point(point):
		return
	var radius := float(settings.get("peg_radius", 6.0))
	var allowed := pinball.can_place_custom_peg(point, radius)
	var tone := Color("64e3df") if allowed else Color("ff6476")
	var center := editor_preview.to_local(pinball.to_global(point))
	editor_preview.draw_circle(center, radius, Color(tone, 0.20))
	editor_preview.draw_arc(center, radius, 0.0, TAU, 32, tone, 1.6, true)
	editor_preview.draw_line(center - Vector2(4.0, 0.0), center + Vector2(4.0, 0.0), tone, 1.0)
	editor_preview.draw_line(center - Vector2(0.0, 4.0), center + Vector2(0.0, 4.0), tone, 1.0)

func _debug_requested(kind: String) -> void:
	if world == null: return
	if kind == "screenshot":
		await RenderingServer.frame_post_draw
		var path := "user://截图_%d.png" % Time.get_unix_time_from_system()
		var error := get_viewport().get_texture().get_image().save_png(path)
		print("截图：", ProjectSettings.globalize_path(path), " 状态：", error)
	elif kind == "storm":
		world.output(0, 3, 10000.0)
	elif kind == "sniper":
		world.output(0, 2, 10000.0)
	elif kind == "big_ball":
		# 明示调试发射，非正式规则后台抽取。
		world.output(0, 1, 100000.0)
	else:
		print("调试快照：", world.debug_readback(kind))

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_SPACE: _toggle_pause()
			KEY_N: paused = true; one_step = true
			KEY_R: _restart()
			KEY_F12: _debug_requested("screenshot")

func _draw() -> void:
	draw_rect(Rect2(0, 0, 1600, 1000), Color("080e18"))
	for x in range(0, 1600, 40):
		draw_line(Vector2(x, 85), Vector2(x, 988), Color(0.18, 0.34, 0.43, 0.06))
	for y in range(85, 1000, 40):
		draw_line(Vector2(12, y), Vector2(1588, y), Color(0.18, 0.34, 0.43, 0.06))
	# 子节点纹理叠在背景上；没有用CPU伪画右侧领土的回退路径。
	draw_rect(BATTLE_RECT.grow(3), Color("08121e"))
	draw_rect(BATTLE_RECT.grow(3), Color("345367"), false, 1.2)
	if not first_texture and font != null:
		var message := "正在编译 GPU Compute 管线…"
		if world != null and not world.error_message.is_empty(): message = world.error_message
		draw_string(font, BATTLE_RECT.position + Vector2(35, 360), message,
			HORIZONTAL_ALIGNMENT_LEFT, 780, 21, Color("ffb879"))

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and not quitting:
		quitting = true
		paused = true
		one_step = false
		_shutdown_and_quit()

func _shutdown_and_quit() -> void:
	# 读回回调绑定节点；退出也要等待回调归还和RD释放确认，不能仅排队就销毁树。
	var closing: Array[GPUWorld] = retired.duplicate()
	if world != null: closing.append(world)
	for target in closing:
		if is_instance_valid(target): target.shutdown()
	var complete := false
	while not complete:
		complete = true
		for target in closing:
			if is_instance_valid(target) and not target.is_shutdown_complete(): complete = false
		if not complete: await get_tree().process_frame
	get_tree().quit()
