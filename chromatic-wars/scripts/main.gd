extends Node2D
## 主控只推进固定时间、每参战队4颗弹药球和UI。右侧实体没有CPU逐粒子循环。

const BATTLE_RECT := Rect2(530, 112, 850, 850)
var settings: Dictionary = {}
var gpu_start_settings: Dictionary = {}
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
var start_team_count := 4
var territory_brush_enabled := false
var territory_brush_team := 0
var territory_brush_radius := 24.0
var _brush_dragging := false
var _brush_inside := false
var _brush_targets: Array[Dictionary] = []
var _brush_last_sent := Vector2.ZERO
var _brush_has_last := false
var _brush_submitted_points := 0
var _brush_coalesced_points := 0
const BRUSH_POINTS_PER_FRAME := 16
const BRUSH_MAX_WAYPOINTS := 128

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
	ui.diagnostic_provider = _collect_diagnostic_state
	ui.pause_pressed.connect(_toggle_pause)
	ui.step_pressed.connect(func(): paused = true; one_step = true)
	ui.restart_pressed.connect(_restart)
	ui.speed_changed.connect(func(value: float): settings["time_scale"] = value)
	ui.settings_changed.connect(_settings_changed)
	ui.debug_requested.connect(_debug_requested)
	ui.manual_weapon_requested.connect(_manual_weapon_requested)
	ui.territory_brush_changed.connect(_set_territory_brush)
	ui.editor_mode_changed.connect(_set_editor_mode)
	ui.clear_custom_pegs_requested.connect(_clear_custom_pegs)
	ui.restore_preset_pegs_requested.connect(_restore_preset_pegs)
	ui.clear_all_pegs_requested.connect(_clear_all_pegs)
	ui.performance_preset_requested.connect(_performance_preset)
	ui.stage_profile_requested.connect(func():
		var accepted: bool = world != null and world.request_stage_profile()
		ui.show_stage_profile_request(accepted)
	)
	get_tree().auto_accept_quit = false
	_restart()

func _restart() -> void:
	if quitting: return
	_set_editor_mode(false)
	_set_territory_brush(false, territory_brush_team, territory_brush_radius)
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
	# 仅记录这代真正提交给configure的归一化开局配置；后续UI待重开值不能覆盖它。
	gpu_start_settings = world.settings.duplicate(true)
	start_team_count = clampi(int(gpu_start_settings.get("team_count", 4)), 1, 4)
	territory_brush_team = mini(territory_brush_team, start_team_count - 1)
	_brush_submitted_points = 0
	_brush_coalesced_points = 0
	ui.set_active_team_count(start_team_count)
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
		var nonce := world.rescue_request_nonce(team)
		var energy := pinball.rescue(team)
		rescue_attempts[team] = {"nonce": nonce, "energy": energy, "reported": false}
		world.resolve_rescue(team, energy, nonce)
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
	if _brush_dragging and (not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or ui.territory_pointer_blocked(battle_view.get_global_mouse_position())):
		_brush_inside = false
		if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
			_brush_dragging = false
	_flush_territory_brush()
	if not pinball.error.is_empty():
		paused = true
		one_step = false
	if world.active and pinball.error.is_empty():
		var dt := active_dt
		if not paused:
			# 真实帧时长只为固定步提供预算；所有游戏计时使用下方推进的模拟秒。
			accumulator += delta * float(settings.get("time_scale", 1.0))
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
			"pinball": pinball.snapshot(), "time_backlog": accumulator, "last_stage_profile":world.last_stage_profile,
			"settings": settings, "active_team_count":start_team_count, "territory_brush":_territory_brush_snapshot()})
	if not first_texture:
		queue_redraw()

func _weapon_output(team: int, kind: int, energy: float) -> void:
	if world != null: world.output(team, kind, energy, elapsed)

func _manual_weapon_requested(team: int, kind: int, energy: int) -> void:
	if team < 0 or team >= start_team_count or kind < 0 or kind > 4 or energy <= 0:
		ui.show_manual_feedback("人工输入无效或阵营未参战，未提交")
		return
	if world == null or not world.active or not world.manual_output(team, kind, energy, elapsed):
		ui.show_manual_feedback("人工输入未提交：战场未就绪或阵营已淘汰；数值仍保留")
		return
	var record := {"type":"manual_weapon", "source":"explicit_manual_debug", "team":team, "kind":kind, "energy":energy, "time":elapsed}
	_trigger_log(record)
	print("CHROMATIC_MANUAL_DEBUG " + JSON.stringify(record))
	ui.show_manual_feedback("人工武器输入已提交一次" + ("；暂停中可入账，发射及计时按武器原规则执行" if paused else ""))

func _set_territory_brush(enabled: bool, team: int, radius: float) -> void:
	var was_enabled := territory_brush_enabled
	territory_brush_enabled = enabled and team >= 0 and team < start_team_count and is_finite(radius)
	territory_brush_team = clampi(team, 0, start_team_count - 1)
	territory_brush_radius = clampf(radius, 4.0, 128.0) if is_finite(radius) else 24.0
	_brush_dragging = false
	_brush_inside = false
	_brush_has_last = false
	_brush_targets.clear()
	if territory_brush_enabled and not was_enabled:
		paused = true
		one_step = false
	ui.set_territory_brush_enabled(territory_brush_enabled)
	if territory_brush_enabled or was_enabled:
		_trigger_log({"type":"manual_territory_brush", "source":"explicit_manual_debug", "enabled":territory_brush_enabled, "team":territory_brush_team, "radius":territory_brush_radius, "time":elapsed})
		ui.show_manual_feedback("人工领土画笔已开启并暂停；收起参数在右侧地图拖动，可显式继续" if territory_brush_enabled and not was_enabled else ("人工领土画笔参数已更新" if territory_brush_enabled else "人工领土画笔已关闭"))

func _battle_world_position(screen_position: Vector2) -> Variant:
	var rect := battle_view.get_global_rect()
	if rect.size.x <= 0.0 or rect.size.y <= 0.0 or not rect.has_point(screen_position):
		return null
	return (screen_position - rect.position) / rect.size * 1024.0

func _queue_brush_point(world_point: Vector2, new_stroke: bool) -> void:
	if not _brush_targets.is_empty():
		var last_index := _brush_targets.size() - 1
		var last: Dictionary = _brush_targets[last_index]
		if not new_stroke and not bool(last.start) and world_point.distance_to(last.position) < territory_brush_radius * 0.25:
			_brush_targets[last_index]["position"] = world_point
			_brush_coalesced_points += 1
			return
		if _brush_targets.size() >= BRUSH_MAX_WAYPOINTS:
			# 有界输入折线只合并尾点；实际提交仍逐点插值，不会用大跨度点留下断缝。
			_brush_targets[last_index] = {"position":world_point, "start":new_stroke or bool(last.start)}
			_brush_coalesced_points += 1
			return
	_brush_targets.append({"position":world_point, "start":new_stroke})

func _flush_territory_brush() -> void:
	if not territory_brush_enabled or world == null or not world.active:
		return
	var budget := BRUSH_POINTS_PER_FRAME
	while budget > 0 and not _brush_targets.is_empty():
		var target: Dictionary = _brush_targets.front()
		var point: Vector2 = target.position
		var next_point := point
		if _brush_has_last and not bool(target.start):
			var distance := _brush_last_sent.distance_to(point)
			if distance < 0.001:
				_brush_targets.pop_front()
				continue
			next_point = _brush_last_sent.move_toward(point, territory_brush_radius * 0.5)
		# 队列满时不能推进游标；下帧从完全相同的待发点重试。
		if not world.paint_territory(territory_brush_team, next_point, territory_brush_radius):
			break
		_brush_last_sent = next_point
		_brush_has_last = true
		_brush_submitted_points += 1
		budget -= 1
		if next_point.distance_to(point) < 0.001:
			_brush_targets.pop_front()
		else:
			_brush_targets[0]["start"] = false

func _territory_brush_snapshot() -> Dictionary:
	return {"enabled":territory_brush_enabled, "team":territory_brush_team, "radius_game_units":territory_brush_radius,
		"dragging":_brush_dragging, "pending_waypoints":_brush_targets.size(), "max_points_per_frame":BRUSH_POINTS_PER_FRAME,
		"submitted_points":_brush_submitted_points, "coalesced_inputs":_brush_coalesced_points,
		"energy_rule":"explicit manual territory edits do not consume weapon energy"}

func _collect_diagnostic_state() -> Dictionary:
	# 只在用户点击复制时汇总小表和配置，不读_rt_settings、不请求任何GPU读回。
	var submitted: Dictionary = world.settings.duplicate(true) if world != null else {}
	var pending_restart: Dictionary = {}
	var restart_keys: Array[String] = ["team_count", "particle_capacity", "grid_size", "render_size", "seed", "intro_shield", "intro_gun", "fixed_dt"]
	for team_index: int in 4:
		restart_keys.append("core_%d_x" % team_index)
		restart_keys.append("core_%d_y" % team_index)
	for key: String in restart_keys:
		var active_value: Variant = active_dt if key == "fixed_dt" else gpu_start_settings.get(key)
		if settings.get(key) != active_value:
			pending_restart[key] = {"active_start_value":active_value, "desired_value":settings.get(key)}
	var pinball_configuration := {
		"gravity":pinball.gravity, "restitution":pinball.restitution, "friction":pinball.friction,
		"radius_min":pinball.radius_min, "radius_max":pinball.radius_max, "radius_gain":pinball.radius_gain,
		"threshold_start":pinball.threshold_start, "threshold_target":pinball.threshold_target,
		"threshold_duration":pinball.threshold_duration, "threshold_curve_time":pinball.threshold_curve_time,
		"active_seed":pinball.active_seed, "static_revision":pinball.static_revision,
		"air":pinball.air.snapshot(), "air_reference_radius":pinball.air.reference_radius, "air_spread":pinball.air.spread,
		"channels":pinball.channels.snapshot(), "conveyor":pinball.conveyor.snapshot(),
		"custom_pegs":pinball.custom_pegs.duplicate(), "disabled_preset_pegs":pinball.disabled_preset_pegs.duplicate(),
		"actual_pegs":pinball.pegs.duplicate()}
	var configuration := {
		"source":{"desired":"validated main.settings in memory", "gpu_start":"GPUWorld.configure normalized settings captured for this generation", "gpu_submitted":"main-thread GPUWorld.settings; submission is not GPU confirmation", "pinball_effective":"current CPU PinballPhysics fields and layout", "startup_provider":"GameSettings.load_file", "saved_config_path":GameSettings.CONFIG_PATH, "saved_config_exists":FileAccess.file_exists(GameSettings.CONFIG_PATH), "saved_config_compared":false, "supported_time_scale_default_revision":GameSettings.TIME_SCALE_DEFAULT_REVISION},
		"desired":settings.duplicate(true), "gpu_start":gpu_start_settings.duplicate(true), "gpu_submitted":submitted,
		"gpu_start_initialized":world != null and world.active, "gpu_parameters_confirmed":false,
		"gpu_submitted_scope":"GPU parameter fields only; CPU-only entries may retain start values, use pinball_effective for current left physics",
		"weapon_plan_scope":"gun_rate and gun_discharge_duration are submitted settings; a current magazine keeps its refill-locked plan, which is not additionally read back",
		"pending_restart":pending_restart, "pinball_effective":pinball_configuration,
		"runtime_effective":{"fixed_dt":active_dt, "target_time_scale":settings.get("time_scale", 1.0), "fps_limit":Engine.max_fps, "active_team_count":start_team_count}}
	return {"sim_time":elapsed, "paused":paused, "fixed_dt":active_dt, "fps":Engine.get_frames_per_second(),
		"gpu_active":world != null and world.active, "error":pinball.error if not pinball.error.is_empty() else (world.error_message if world != null else "GPU未创建"),
		"stats":world.stats.duplicate(true) if world != null else {}, "pinball":pinball.snapshot(), "time_backlog":accumulator,
		"settings":settings, "configuration":configuration, "last_stage_profile":world.last_stage_profile.duplicate(true) if world != null else {},
		"active_team_count":start_team_count, "territory_brush":_territory_brush_snapshot(),
		"diagnostic_runtime":{"generation":generation, "world_instance_id":world.get_instance_id() if world != null else 0,
			"retired_world_count":retired.size(), "editor_mode":editor_mode, "quitting":quitting,
			"recent_trigger_history":trigger_history.duplicate(true), "rescue_attempts":rescue_attempts.duplicate(true)}}

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
	if float(previous.get("time_scale", 1.0)) != float(settings.get("time_scale", 1.0)):
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

func _input(event: InputEvent) -> void:
	# 即使松键被参数面板消费，也必须结束拖动，避免返回地图时继续涂色。
	if territory_brush_enabled and _brush_dragging and event is InputEventMouseButton and not event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		var point: Variant = _battle_world_position(event.position)
		if point != null and not ui.territory_pointer_blocked(event.position):
			_queue_brush_point(point, not _brush_inside)
		_brush_dragging = false
		_brush_inside = false
	# 右键退出须在GUI消费之前处理；只拦右侧地图，不影响左侧右键删柱。
	if territory_brush_enabled and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT and _battle_world_position(event.position) != null:
		_set_territory_brush(false, territory_brush_team, territory_brush_radius)
		get_viewport().set_input_as_handled()

func _unhandled_input(event: InputEvent) -> void:
	if territory_brush_enabled and _handle_territory_brush_input(event):
		get_viewport().set_input_as_handled()
		return
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

func _handle_territory_brush_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var point: Variant = _battle_world_position(event.position)
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed and point != null:
			_set_territory_brush(false, territory_brush_team, territory_brush_radius)
			return true
		if event.button_index != MOUSE_BUTTON_LEFT:
			return false
		if event.pressed:
			if point == null or ui.territory_pointer_blocked(event.position):
				return false
			_brush_dragging = true
			_brush_inside = true
			_queue_brush_point(point, true)
			_trigger_log({"type":"manual_territory_stroke", "source":"explicit_manual_debug", "team":territory_brush_team, "radius":territory_brush_radius, "world_start":point, "time":elapsed})
			return true
		if _brush_dragging:
			if point != null:
				_queue_brush_point(point, not _brush_inside)
			_brush_dragging = false
			_brush_inside = false
			return true
	elif event is InputEventMouseMotion and _brush_dragging:
		var motion_point: Variant = _battle_world_position(event.position)
		if motion_point == null or ui.territory_pointer_blocked(event.position):
			_brush_inside = false
			return false
		_queue_brush_point(motion_point, not _brush_inside)
		_brush_inside = true
		return true
	return false

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
