class_name GPUWorld
extends Node
## 右侧唯一权威状态在主 RenderingDevice 中，正式绘制直接共享 Texture2DRD。
## 仅异步读回小型阵营/统计/大球信息；从不读回整张画面或普通粒子表。

signal initialized
signal failed(message: String)
signal stats_updated(data: Dictionary)
signal rescue_requested(team: int)
signal team_eliminated(team: int)
signal debug_snapshot_ready(data: Dictionary)

const EmitterCodec = preload("res://scripts/gpu_emitters.gd")
const CollisionRules = preload("res://scripts/gpu_collisions.gd")
const RenderResources = preload("res://scripts/gpu_render.gd")

const BIG_CAPACITY := 64
const RING_CAPACITY := 1024
const PAINT_BATCH_CAPACITY := 64
const PAINT_COMMAND_BASE := RING_CAPACITY + 12
const COMMAND_STRIDE := 32
const PARTICLE_STRIDE := 64
const TEAM_STRIDE := 128
const METRICS_WORDS := 64
const GRID_CELLS := 128 * 128
const GRID_HEADS := GRID_CELLS * 4
const PARAM_FLOATS := 64
const WEAPON_STRIDE := 176
const WEAPON_STATE_BYTES := 4 * WEAPON_STRIDE
const POOL_HEADER_WORDS := 16
const DIAGNOSTIC_WORDS := 64
const KERNEL_MODE_COUNT := 16

var texture: Texture2DRD = Texture2DRD.new()
var active := false
var active_team_count: int = 4
var error_message := ""
var stats: Dictionary = {}
var settings: Dictionary = {}
# 手动诊断的最后一次采样；只在主线程发布，普通运行不会自动拆分compute列表。
var last_stage_profile: Dictionary = {}
var _steps: Array[Vector2] = []
var _queued: Array[Dictionary] = []
var _resolutions: Array[Dictionary] = []
var _paint_points: Array[Dictionary] = []
var _paint_flush_scheduled := false
var _generation := 0
var _shutting_down := false
# 退役节点必须同时等待读回回调归还与渲染线程释放确认，不能用固定帧数猜测。
var pending_readbacks: int = 0
var resource_release_confirmed := true
var _ring_tail := 0
var _ring_head := 0
var _last_sim_time_queued_main := 0.0
var _stats_clock := 0.0
var _read_in_flight := false
var _rescue_notified := [-1, -1, -1, -1]
var _rescue_submitted_nonce := [-1, -1, -1, -1]
var _rescue_team_sequence := [-1, -1, -1, -1]
var _critical_read_in_flight_rd := false
var _team_read_sequence_rd := 0
var _last_submitted_sim_time_rd := 0.0
var _last_submitted_tail_rd := 0
var _death_notified := [false, false, false, false]
var _debug_sequence := 0
var _cached_debug: Dictionary = {}
var _rt_settings: Dictionary = {}
var _rd: RenderingDevice
var _shader: RID
# mode0的兼容别名：旧只读调试入口仍用它检查资源是否已创建。
var _pipeline: RID
var _pipelines: Array[RID] = []
var _uniform_set: RID
var _output: RID
var _buffers: Array[RID] = []
var _resource_rids: Array[RID] = []
var _device_name := ""
var _memory_bytes := 0
var _last_gpu_ms := -1.0
var _metrics_dirty_rd := true
var _priorities_present_rd := false
var _last_read_metrics := PackedByteArray()
var _last_read_teams := PackedByteArray()
var _last_read_balls := PackedByteArray()
var _last_read_diagnostics := PackedByteArray()
var _last_submit_cpu_ms := 0.0
var _last_readback_latency_ms := 0.0
var _last_blocking_readback_ms := 0.0
var _last_substep_count := 0
var _batch_sequence_rd := 0
var _last_batch_metadata_rd: Dictionary = {}
var _batch_gpu_times_rd: Dictionary = {}
var _last_gpu_batch_id_rd := -1
var _last_timestamp_frame_rd := -1
var _stage_profile_requested_rd := false
var _stage_profile_recording_rd := false
var _stage_profile_sample_dispatch_rd := false
var _stage_profile_ordinal_rd := 0
var _stage_profile_metadata_rd: Dictionary = {}
var _stage_profiles_waiting_rd: Dictionary = {}

func request_stage_profile() -> bool:
	if not active or _shutting_down:
		return false
	if str(last_stage_profile.get("status", "")) in ["REQUESTED", "WAITING_FOR_TIMESTAMPS"]:
		return false
	last_stage_profile = {"status":"REQUESTED", "generation":_generation, "scope":"next simulated batch: first GPU substep and final render", "profile_changes_command_list_boundaries":true}
	RenderingServer.call_on_render_thread(_request_stage_profile_rd.bind(_generation))
	return true

func _request_stage_profile_rd(generation_id: int) -> void:
	if generation_id == _generation and not _shutting_down:
		_stage_profile_requested_rd = true

func _stage_profile_main(generation_id: int, profile: Dictionary) -> void:
	if generation_id == _generation and not _shutting_down:
		last_stage_profile = profile

func _new_batch_metadata_rd(batch: Array, fallback_sim_time: float) -> Dictionary:
	_batch_sequence_rd += 1
	return {"generation":_generation, "batch_id":_batch_sequence_rd, "substeps":batch.size(), "sim_start":float(batch.front().y - batch.front().x) if not batch.is_empty() else fallback_sim_time, "sim_end":float(batch.back().y) if not batch.is_empty() else fallback_sim_time, "cpu_submit_ms":0.0}

func configure(value: Dictionary) -> void:
	settings = value.duplicate(true)
	# 公共设置名由 UI / Settings 所有。别名仅用于独立调试场景。
	for pair: Array in [["terrain_resolution", "grid_size"], ["render_resolution", "render_size"], ["initial_shield", "intro_shield"], ["initial_gun", "intro_gun"], ["gun_rate_start", "gun_start"], ["gun_rate_end", "gun_end"], ["gun_growth_duration", "gun_duration"], ["big_ball_speed", "ball_speed"], ["rescue_cooldown", "emergency_cd"]]:
		if settings.has(pair[0]) and not settings.has(pair[1]):
			settings[pair[1]] = settings[pair[0]]
	if not settings.has("gun_rate"):
		var legacy_rate: Variant = settings.get("gun_end", 1200.0)
		settings["gun_rate"] = 1200.0 if is_equal_approx(float(legacy_rate), 1400.0) else legacy_rate
	var defaults := {"particle_capacity":10000, "grid_size":512, "render_size":768, "seed":2026, "intro_shield":1000000.0, "intro_gun":1000000.0, "gun_rate":1200.0, "gun_rotation_speed":1.7, "gun_target_switch_cd":0.5, "storm_ring_particles":360, "storm_ring_interval":0.10, "particle_speed":140.0, "ball_speed":42.0, "sniper_speed":600.0, "emergency_cd":180.0, "particle_radius":1.4, "packet_energy":1, "shield_scale":1.0, "precision_mode":"exact", "trail_length":0.55, "visual_density":1.0}
	for key: String in defaults:
		if not settings.has(key):
			settings[key] = defaults[key]
	var requested_count: Variant = settings.get("team_count", 4)
	settings["team_count"] = clampi(int(requested_count), 1, 4) if (requested_count is int or requested_count is float) and is_finite(float(requested_count)) else 4
	settings["shield_max_diameter"] = float(settings.get("shield_max_diameter", 389.12))
	settings["sniper_charge_time"] = float(settings.get("sniper_charge_time", 0.65))
	settings["ball_min_speed"] = float(settings.get("ball_min_speed", 40.0))
	settings["friendly_particle_collisions"] = bool(settings.get("friendly_particle_collisions", true))
	settings["gun_discharge_duration"] = settings.get("gun_discharge_duration", 10.0)
	for team_index: int in range(4):
		settings["core_%d_x" % team_index] = float(settings.get("core_%d_x" % team_index, 768.0 if team_index % 2 else 256.0))
		settings["core_%d_y" % team_index] = float(settings.get("core_%d_y" % team_index, 768.0 if team_index >= 2 else 256.0))
	settings.particle_capacity = clampi(int(settings.particle_capacity), 64, 1000000)
	settings.grid_size = clampi(int(settings.grid_size), 64, 1024)
	settings.render_size = clampi(int(settings.render_size), 256, 1536)
	settings.particle_radius = clampf(float(settings.particle_radius), 0.5, 3.0)
	_normalize_emission_settings()
	if str(settings.precision_mode) == "exact":
		settings.packet_energy = 1

func update_settings(value: Dictionary) -> void:
	## 容量、网格、输出纹理、随机种子、开局库存重开生效；其余物理参数立即生效。
	var immediate: Array[String] = ["gun_rate", "gun_discharge_duration", "gun_rotation_speed", "gun_target_switch_cd", "growth_curve_time", "sniper_split_angle", "gpu_profiling", "friendly_particle_collisions", "storm_ring_particles", "storm_ring_interval", "particle_speed", "ball_speed", "ball_min_speed", "sniper_speed", "sniper_charge_time", "shield_max_diameter", "emergency_cd", "particle_radius", "packet_energy", "shield_scale", "precision_mode", "trail_length", "visual_density", "growth_target", "growth_duration"]
	for key: String in immediate:
		if value.has(key):
			settings[key] = value[key]
	if str(settings.get("precision_mode", "exact")) == "exact":
		settings.packet_energy = 1
	settings.particle_radius = clampf(float(settings.get("particle_radius", 1.4)), 0.5, 3.0)
	_normalize_emission_settings()
	if active:
		RenderingServer.call_on_render_thread(_update_params_rd.bind(_generation, settings.duplicate(true)))

func _normalize_emission_settings() -> void:
	settings["gun_rate"] = clampf(float(settings.get("gun_rate", 1200.0)), 0.0, 10000.0)
	settings["gun_rotation_speed"] = clampf(float(settings.get("gun_rotation_speed", 1.7)), 0.1, 6.0)
	var switch_cd: Variant = settings.get("gun_target_switch_cd", 0.5)
	settings["gun_target_switch_cd"] = clampf(float(switch_cd), 0.0, 2.0) if (switch_cd is int or switch_cd is float) and is_finite(float(switch_cd)) else 0.5
	var discharge_duration: Variant = settings.get("gun_discharge_duration", 10.0)
	settings["gun_discharge_duration"] = clampf(float(discharge_duration), 0.1, 120.0) if (discharge_duration is int or discharge_duration is float) and is_finite(float(discharge_duration)) else 10.0
	settings["gun_start"] = settings["gun_rate"]
	settings["gun_end"] = settings["gun_rate"]
	# 旧存档的时间发射成本已废弃，直接配置同样不能重新启用。
	settings.erase("particle_cost_delay")
	settings.erase("particle_cost_growth")
	settings["storm_ring_particles"] = 360
	settings["storm_ring_interval"] = clampf(float(settings.get("storm_ring_interval", 0.10)), 0.02, 2.0)
	settings["ball_min_speed"] = clampf(float(settings.get("ball_min_speed", 40.0)), 1.0, maxf(1.0, float(settings.get("ball_speed", 92.0))))

func _update_params_rd(generation_id: int, configuration: Dictionary) -> void:
	if generation_id != _generation or _buffers.is_empty():
		return
	_rt_settings = configuration
	var bytes := _make_params(configuration)
	_rd.buffer_update(_buffers[8], 0, bytes.size(), bytes)

func start() -> void:
	# 同一对象不得跨未归还读回重用资源；正式重开创建新对象并退役旧对象。
	if pending_readbacks > 0 or (_shutting_down and not is_shutdown_complete()):
		push_warning("GPUWorld仍有未完成的读回或资源释放；请等待is_shutdown_complete()后再启动同一对象。")
		return
	_shutting_down = false
	resource_release_confirmed = false
	if settings.is_empty():
		configure({})
	active_team_count = int(settings.get("team_count", 4))
	_generation += 1
	active = false
	texture.texture_rd_rid = RID()
	error_message = ""
	last_stage_profile = {}
	_read_in_flight = false
	_steps.clear()
	_queued.clear()
	_resolutions.clear()
	_paint_points.clear()
	_paint_flush_scheduled = false
	_ring_tail = 0
	_ring_head = 0
	_last_sim_time_queued_main = 0.0
	_rescue_notified = [-1, -1, -1, -1]
	_rescue_submitted_nonce = [-1, -1, -1, -1]
	_rescue_team_sequence = [-1, -1, -1, -1]
	_critical_read_in_flight_rd = false
	_team_read_sequence_rd = 0
	_last_submitted_sim_time_rd = 0.0
	_last_submitted_tail_rd = 0
	_death_notified = [false, false, false, false]
	if RenderingServer.get_current_rendering_driver_name() != "vulkan" or RenderingServer.get_current_rendering_method() != "forward_plus":
		call_deferred("_failed_main", _generation, "当前图形模式不受支持：需要 Forward+ / Vulkan，不能使用兼容或其他图形驱动代替。")
		return
	RenderingServer.call_on_render_thread(_initialize_rd.bind(_generation, settings.duplicate(true)))

func step(dt: float, sim_time: float) -> void:
	if active and dt > 0.0:
		var count := CollisionRules.substep_count(dt, settings)
		var substep := dt / float(count)
		for index: int in count:
			_steps.append(Vector2(substep, sim_time - dt + substep * float(index + 1)))

func output(team: int, kind: int, energy: float, at_time: float = -1.0) -> void:
	if team < 0 or team >= active_team_count or kind < 0 or kind > 4 or energy < 1.0:
		return
	# 无空闲粒子时能量留在 GPU 队列；命令环满时留在此小命令队列。
	# 与GPU的clock/Vector2固定步时间使用相同float32，避免长局末步量化后迟一帧。
	_queued.append({"op":kind + 1, "team":team, "energy":energy, "at_time":float(PackedFloat32Array([at_time])[0])})

func rescue_request_nonce(team: int) -> int:
	if team < 0 or team >= 4:
		return -1
	if int(_rescue_notified[team]) >= 0:
		return int(_rescue_notified[team])
	var teams: Array = stats.get("teams", [])
	return int(teams[team].get("request_nonce", 0)) if team < teams.size() else 0

func resolve_rescue(team: int, energy: float, request_nonce: int = -1) -> void:
	if team < 0 or team >= active_team_count or _shutting_down:
		return
	var nonce := request_nonce if request_nonce >= 0 else rescue_request_nonce(team)
	if int(_rescue_submitted_nonce[team]) == nonce:
		return
	_rescue_submitted_nonce[team] = nonce
	var resolution := {"op":6, "team":team, "energy":maxf(energy, 0.0), "nonce":nonce}
	if active:
		# 不等待下一帧flush，也不阻塞主线程；排在已提交的模拟工作之后立即补盾。
		RenderingServer.call_on_render_thread(_execute_rescues_rd.bind(_generation, [resolution]))
	else:
		_resolutions.append(resolution)

func manual_output(team: int, kind: int, energy: int, at_time: float = -1.0) -> bool:
	if not active or _shutting_down or team < 0 or team >= active_team_count or kind < 0 or kind > 4 or energy < 1:
		return false
	var teams: Array = stats.get("teams", [])
	if team < teams.size() and not bool(teams[team].get("alive", true)):
		return false
	# 人工输入全程保留int64；普通左球输出仍遵循自己的精确float整数域。
	_queued.append({"op":kind + 1, "team":team, "energy":energy, "at_time":float(PackedFloat32Array([at_time])[0]), "manual":true})
	return true

func paint_territory(team: int, position: Vector2, radius: float) -> bool:
	if not active or _shutting_down or team < 0 or team >= active_team_count or not is_finite(position.x) or not is_finite(position.y) or not is_finite(radius) or radius <= 0.0 or _paint_points.size() >= 256:
		return false
	_paint_points.append({"op":18, "team":team, "x":clampf(position.x, 0.0, CollisionRules.WORLD_SIZE), "y":clampf(position.y, 0.0, CollisionRules.WORLD_SIZE), "radius":clampf(radius, 0.5, 256.0)})
	if not _paint_flush_scheduled:
		_paint_flush_scheduled = true
		_flush_pending_paint.call_deferred(_generation)
	return true

func _flush_pending_paint(generation_id: int) -> void:
	if generation_id != _generation or not active or _shutting_down:
		return
	_paint_flush_scheduled = false
	if _paint_points.is_empty():
		return
	var count := mini(_paint_points.size(), PAINT_BATCH_CAPACITY)
	var batch := _paint_points.slice(0, count)
	_paint_points = _paint_points.slice(count)
	RenderingServer.call_on_render_thread(_execute_paint_rd.bind(generation_id, batch))
	if not _paint_points.is_empty():
		_paint_flush_scheduled = true
		get_tree().process_frame.connect(_flush_pending_paint.bind(generation_id), CONNECT_ONE_SHOT)

func death_balls(team: int, energies: Array) -> void:
	for energy: Variant in energies:
		if float(energy) >= 1.0:
			_queued.append({"op":2, "team":team, "energy":float(energy), "death":true})

func flush() -> void:
	if not active:
		return
	var batch := _steps.duplicate()
	_steps.clear()
	var upload: Array[Dictionary] = []
	var rescues := _resolutions.duplicate(true)
	_resolutions.clear()
	var priority_occupied: Dictionary = {}
	var remaining: Array[Dictionary] = []
	var available := maxi(0, RING_CAPACITY - (_ring_tail - _ring_head))
	var batch_end: float = batch.back().y if not batch.is_empty() else _last_sim_time_queued_main
	if not batch.is_empty():
		_last_sim_time_queued_main = batch_end
	for command: Dictionary in _queued:
		var op := int(command.get("op", 0))
		var at_time := float(PackedFloat32Array([float(command.get("at_time", -1.0))])[0])
		if op >= 1 and op <= 5 and at_time >= 0.0 and batch_end + 0.00001 < at_time:
			# 优先槽每批会清空，超出本批的未来命令必须留在CPU，不能提前占槽后丢失。
			remaining.append(command)
			continue
		if (op == 1 or op == 5) and not bool(command.get("manual", false)):
			# 独立8个优先槽：大球/狙击积压也不能阻塞充盾/枪库存。
			var slot := int(command.team) * 2 + (1 if op == 5 else 0)
			if not priority_occupied.has(slot):
				priority_occupied[slot] = true
				rescues.append(command)
			else:
				remaining.append(command)
		elif upload.size() < mini(available, 256):
			command["slot"] = _ring_tail % RING_CAPACITY
			_ring_tail += 1
			upload.append(command)
		else:
			remaining.append(command)
	_queued = remaining
	# 遥测是内部显示/通知刷新，按真实时间节流；游戏冷却/发射只用 batch 的模拟时钟。
	_stats_clock += get_process_delta_time()
	var request_stats := _stats_clock >= 0.25 and not _read_in_flight
	if request_stats:
		_stats_clock = 0.0
		_read_in_flight = true
	RenderingServer.call_on_render_thread(_execute_rd.bind(_generation, batch, upload, rescues, _ring_tail, request_stats))

func shutdown() -> void:
	if _shutting_down:
		return
	_shutting_down = true
	active = false
	_generation += 1
	texture.texture_rd_rid = RID()
	resource_release_confirmed = false
	RenderingServer.call_on_render_thread(_release_retired_rd.bind(_generation))

func is_shutdown_complete() -> bool:
	return _shutting_down and resource_release_confirmed and pending_readbacks == 0

func _release_retired_rd(generation_id: int) -> void:
	if generation_id != _generation or not _shutting_down or pending_readbacks != 0:
		return
	_release_rd()

func _readbacks_drained_main() -> void:
	# 回调可能来自渲染线程。先返回主线程再排释放，避免同步回读兼容路径中途释放缓冲。
	if _shutting_down and pending_readbacks == 0 and not resource_release_confirmed:
		RenderingServer.call_on_render_thread(_release_retired_rd.bind(_generation))

func _exit_tree() -> void:
	shutdown()

func debug_readback(kind: String = "sample") -> Dictionary:
	## 独立测试可读取前64个粒子、全部64个大球及少量地块；正式运行不调用。
	_debug_sequence += 1
	RenderingServer.call_on_render_thread(_debug_read_rd.bind(_generation, kind, _debug_sequence))
	return {"pending":true, "request_id":_debug_sequence, "cached":_cached_debug.duplicate(true)}

func debug_command(command: Dictionary) -> void:
	## 仅独立测试入口：GPU 自己执行注入/状态初始化，CPU 不模拟战场。
	_queued.append(command.duplicate(true))

func _debug_rebuild_pool_rd(count: int) -> void:
	## Explicit benchmark fixture hook: particles [0,count) were uploaded once by
	## the caller. Never used by gameplay, and never reads the particle table.
	var capacity := int(_rt_settings.particle_capacity)
	count = clampi(count, 0, capacity)
	var bytes := PackedByteArray()
	bytes.resize((POOL_HEADER_WORDS + capacity * 2) * 4)
	var ordinary_free := maxi(0, capacity - 8 - count)
	var reserved_free := capacity - maxi(count, capacity - 8)
	bytes.encode_u32(0, count)
	bytes.encode_u32(4, ordinary_free)
	bytes.encode_u32(8, reserved_free)
	for ordinal: int in count:
		bytes.encode_u32((POOL_HEADER_WORDS + ordinal) * 4, ordinal)
	var free_base := POOL_HEADER_WORDS + capacity
	for ordinal: int in ordinary_free:
		bytes.encode_u32((free_base + ordinal) * 4, capacity - 9 - ordinal)
	for ordinal: int in reserved_free:
		bytes.encode_u32((free_base + capacity - 8 + ordinal) * 4, maxi(count, capacity - 8) + ordinal)
	_rd.buffer_update(_buffers[10], 0, bytes.size(), bytes)
	var indirect := PackedByteArray()
	indirect.resize(24)
	indirect.encode_u32(0, maxi(1, (count + 63) / 64))
	indirect.encode_u32(4, 1)
	indirect.encode_u32(8, 1)
	indirect.encode_u32(12, maxi(1, (count + BIG_CAPACITY + 63) / 64))
	indirect.encode_u32(16, 1)
	indirect.encode_u32(20, 1)
	_rd.buffer_update(_buffers[11], 0, indirect.size(), indirect)
	_metrics_dirty_rd = true

func _initialize_rd(generation: int, configuration: Dictionary) -> void:
	# 快速重开可能在初始化真正执行前使该代过期，不能创建无主资源。
	if generation != _generation:
		return
	_release_rd()
	_rd = RenderingServer.get_rendering_device()
	if _rd == null:
		_fail_rd("无法取得主 RenderingDevice。请使用 Godot 4.3+、Forward+ / Vulkan，并更新显卡驱动。", generation)
		return
	_rt_settings = configuration
	_device_name = _rd.get_device_name()
	var capacity := int(configuration.particle_capacity)
	var grid_size := int(configuration.grid_size)
	var render_size := int(configuration.render_size)
	var required_particle_bytes := (capacity + BIG_CAPACITY) * PARTICLE_STRIDE
	# Godot 未暴露 maxStorageBufferRange；使用 Vulkan 保证的最小 128 MiB。
	var storage_limit := 128 * 1024 * 1024
	if int(_rd.limit_get(RenderingDevice.LIMIT_MAX_STORAGE_BUFFERS_PER_SHADER_STAGE)) < 14:
		_fail_rd("GPU 每阶段存储缓冲数量少于 14，无法执行全 GPU 战场。", generation)
		return
	if required_particle_bytes > storage_limit:
		_fail_rd("GPU 存储缓冲上限不足：粒子缓冲需要 %d 字节，设备上限 %d。请降低粒子容量。" % [required_particle_bytes, storage_limit], generation)
		return
	var spirv: RDShaderSPIRV
	# 导出PCK使用Godot标准RDShaderFile资源，其SPIR-V随导出包含。
	# 开发目录若有原始源码，则直接编译当前文本，避免旧.import缓存影响调试。
	var code := FileAccess.get_file_as_string("res://shaders/battle.glsl") if FileAccess.file_exists("res://shaders/battle.glsl") else ""
	if not code.is_empty() and code.contains("#version"):
		var source := RDShaderSource.new()
		source.source_compute = code.replace("#[compute]", "")
		spirv = _rd.shader_compile_spirv_from_source(source)
	else:
		var imported: RDShaderFile = load("res://shaders/battle.glsl") as RDShaderFile
		if imported == null:
			_fail_rd("无法加载 battle.glsl 的导入SPIR-V资源；请先用Godot编辑器完整导入后导出。", generation)
			return
		spirv = imported.get_spirv()
	var compile_error := spirv.get_stage_compile_error(RenderingDevice.SHADER_STAGE_COMPUTE)
	if not compile_error.is_empty():
		_fail_rd("GPU 计算着色器编译失败：\n" + compile_error, generation)
		return
	_shader = _rd.shader_create_from_spirv(spirv)
	if not _shader.is_valid():
		_fail_rd("GPU 计算着色器创建失败。", generation)
		return
	_resource_rids.append(_shader)
	# 每条管线固定一个specialization mode；驱动可裁掉其他模式的私有堆和分支。
	# 所有模式仍引用同一shader/SSBO布局，保留原来的pass依赖和屏障。
	for mode: int in KERNEL_MODE_COUNT:
		var kernel_mode := RDPipelineSpecializationConstant.new()
		kernel_mode.constant_id = 0
		kernel_mode.value = mode
		var constants: Array[RDPipelineSpecializationConstant] = [kernel_mode]
		var pipeline := _rd.compute_pipeline_create(_shader, constants)
		if not pipeline.is_valid():
			_fail_rd("GPU 计算管线创建失败（模式 %d）：请检查 Vulkan 驱动及存储缓冲支持。" % mode, generation)
			return
		_pipelines.append(pipeline)
		_resource_rids.append(pipeline)
	_pipeline = _pipelines[0]
	var sizes := [required_particle_bytes, 4 * TEAM_STRIDE, grid_size * grid_size * 4, GRID_HEADS * 4, (capacity + BIG_CAPACITY) * 4, (RING_CAPACITY + 12 + PAINT_BATCH_CAPACITY + 1) * COMMAND_STRIDE, METRICS_WORDS * 4, render_size * render_size * 4, PARAM_FLOATS * 4]
	# Indices 9/10/11 map to bindings 10/11/12. The pool keeps stable physical
	# IDs; indirect dispatch dimensions remain on the GPU with no count readback.
	sizes.append(WEAPON_STATE_BYTES)
	sizes.append((POOL_HEADER_WORDS + capacity * 2) * 4)
	sizes.append(DIAGNOSTIC_WORDS * 4)
	# binding13：每物理槽8B的uvec2首接触记录，末尾两条保存大球/宽弹摘要。
	sizes.append((capacity + BIG_CAPACITY + 2) * 8)
	# binding14：宽弹链与普通格占用标志、九色计数及非空格列表。
	sizes.append((4 * 32 * 32 + capacity + BIG_CAPACITY + GRID_CELLS + 9 + 9 * CollisionRules.PHASE_WIDTH * CollisionRules.PHASE_WIDTH) * 4)
	_buffers.clear()
	_memory_bytes = 0
	for buffer_index: int in sizes.size():
		var bytes: int = sizes[buffer_index]
		var data := PackedByteArray()
		data.resize(bytes)
		var usage := RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT if buffer_index == 11 else 0
		var buffer := _rd.storage_buffer_create(bytes, data, usage)
		if not buffer.is_valid():
			_fail_rd("GPU 存储缓冲分配失败，需要 %d 字节。请降低粒子容量/网格精度。" % bytes, generation)
			return
		_buffers.append(buffer)
		_resource_rids.append(buffer)
		_memory_bytes += bytes
	_output = RenderResources.create_output(_rd, render_size)
	if not _output.is_valid():
		_fail_rd("GPU 输出纹理创建失败。请降低渲染分辨率。", generation)
		return
	_resource_rids.append(_output)
	_memory_bytes += render_size * render_size * 4
	var uniforms: Array[RDUniform] = []
	for index: int in _buffers.size():
		var binding := index if index < 7 else index + 1
		var uniform := RDUniform.new()
		uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
		uniform.binding = binding
		uniform.add_id(_buffers[index])
		uniforms.append(uniform)
	var image_uniform := RDUniform.new()
	image_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	image_uniform.binding = 7
	image_uniform.add_id(_output)
	uniforms.append(image_uniform)
	_uniform_set = _rd.uniform_set_create(uniforms, _shader, 0)
	if not _uniform_set.is_valid():
		_fail_rd("GPU 资源绑定失败：着色器 binding 与存储缓冲/图像类型不一致。", generation)
		return
	_resource_rids.append(_uniform_set)
	# 参数和初始化 pass 在后续实现；首次渲染完成后才发送 initialized。
	_initialize_dispatch(configuration)
	call_deferred("_initialized_main", generation, _output, _device_name, _memory_bytes)

func _initialized_main(generation: int, output_rid: RID, device: String, memory: int) -> void:
	if generation != _generation:
		return
	texture.texture_rd_rid = output_rid
	active = true
	stats = {"device":device, "memory_mb":float(memory) / 1048576.0, "gpu_ms":-1.0, "precision_mode":str(settings.precision_mode), "active_particles":0, "big_balls":0, "queue_energy":0, "overflow_count":0, "teams":[]}
	stats["active_team_count"] = active_team_count
	initialized.emit()

func _fail_rd(message: String, generation: int) -> void:
	_release_rd()
	call_deferred("_failed_main", generation, message)

func _failed_main(generation: int, message: String) -> void:
	if generation != _generation:
		return
	active = false
	error_message = message
	failed.emit(message)

func _release_rd() -> void:
	if _rd != null:
		# 先释放 Uniform / Pipeline，再释放其引用的资源。
		for index: int in range(_resource_rids.size() - 1, -1, -1):
			var rid: RID = _resource_rids[index]
			if rid.is_valid():
				_rd.free_rid(rid)
	_resource_rids.clear()
	_buffers.clear()
	_pipelines.clear()
	_shader = RID()
	_pipeline = RID()
	_uniform_set = RID()
	_output = RID()
	_batch_sequence_rd = 0
	_last_batch_metadata_rd.clear()
	_batch_gpu_times_rd.clear()
	_last_gpu_ms = -1.0
	_last_gpu_batch_id_rd = -1
	_last_timestamp_frame_rd = -1
	_stage_profile_requested_rd = false
	_stage_profile_recording_rd = false
	_stage_profile_sample_dispatch_rd = false
	_stage_profile_metadata_rd.clear()
	_stage_profiles_waiting_rd.clear()
	_metrics_dirty_rd = true
	_priorities_present_rd = false
	resource_release_confirmed = _shutting_down and pending_readbacks == 0

func _initialize_dispatch(configuration: Dictionary) -> void:
	var params := _make_params(configuration)
	_rd.buffer_update(_buffers[8], 0, params.size(), params)
	var list := _rd.compute_list_begin()
	var largest := maxi(int(configuration.grid_size) * int(configuration.grid_size), int(configuration.render_size) * int(configuration.render_size))
	largest = maxi(largest, int(configuration.particle_capacity) + BIG_CAPACITY)
	largest = maxi(largest, GRID_HEADS)
	_dispatch(list, 0, largest, 0, 0, 0.0, 0.0)
	_dispatch(list, 11, 1, 0, 0, 0.0, 0.0)
	_statistics_dispatch(list, 0, 0.0)
	_render_dispatch(list, 0, 0.0)
	_rd.compute_list_end()

func _make_params(configuration: Dictionary) -> PackedByteArray:
	var values := PackedFloat32Array()
	values.resize(PARAM_FLOATS)
	var blocks: Array = [
		[configuration.particle_capacity, configuration.grid_size, configuration.render_size, int(configuration.seed) % 16777216],
		[CollisionRules.WORLD_SIZE, CollisionRules.CELL_SIZE, CollisionRules.SPATIAL_COLUMNS, BIG_CAPACITY],
		[configuration.intro_shield, configuration.intro_gun, configuration.gun_rate, 0.0],
		[configuration.gun_rotation_speed, configuration.get("particle_speed", 140.0), configuration.sniper_speed, configuration.ball_speed],
		[configuration.particle_radius, configuration.packet_energy, configuration.shield_scale, configuration.emergency_cd],
		[7.0, 3.0, 42.0, 12.0],
		[100.0, configuration.get("growth_target", 1000000.0), configuration.get("growth_duration", 1200.0), configuration.get("spawn_budget", 192.0)],
		[configuration.particle_radius, configuration.trail_length, configuration.visual_density, 0.0 if str(configuration.precision_mode) == "exact" else 1.0],
		[BIG_CAPACITY, 48.0, 16.0, 1000000.0]
	]
	for index: int in blocks.size():
		for column: int in 4:
			values[index * 4 + column] = float(blocks[index][column])
	# 参数块9以uint原位打包，初始盾枪不经过float32舍入。
	var bytes := values.to_byte_array()
	var shield := int(configuration.intro_shield)
	var gun := int(configuration.intro_gun)
	bytes.encode_u32(144, shield & 0xffffffff)
	bytes.encode_u32(148, (shield >> 32) & 0xffffffff)
	bytes.encode_u32(152, gun & 0xffffffff)
	bytes.encode_u32(156, (gun >> 32) & 0xffffffff)
	# 参数块10/11：四队核心坐标；块12：盾半径上限、聚能弹充能时间、大球最低移速、己方粒子碰撞开关。
	for team_index: int in range(4):
		bytes.encode_float(160 + team_index * 8, float(configuration.get("core_%d_x" % team_index, 768.0 if team_index % 2 else 256.0)))
		bytes.encode_float(164 + team_index * 8, float(configuration.get("core_%d_y" % team_index, 768.0 if team_index >= 2 else 256.0)))
	bytes.encode_float(192, float(configuration.get("shield_max_diameter", 389.12)) * 0.5)
	bytes.encode_float(196, float(configuration.get("sniper_charge_time", 0.65)))
	bytes.encode_float(200, float(configuration.get("ball_min_speed", 40.0)))
	bytes.encode_float(204, 1.0 if bool(configuration.get("friendly_particle_collisions", true)) else 0.0)
	# 参数块13：参战队数（本局锁定）/保留/风暴环粒子数/环间隔。
	bytes.encode_float(208, float(configuration.get("team_count", 4)))
	bytes.encode_float(212, 0.0)
	bytes.encode_float(216, float(configuration.get("storm_ring_particles", 360)))
	bytes.encode_float(220, float(configuration.get("storm_ring_interval", 0.10)))
	bytes.encode_float(224, float(configuration.get("gun_target_switch_cd", 0.5)))
	bytes.encode_float(228, float(configuration.get("growth_curve_time", 1200.0)))
	bytes.encode_float(232, float(configuration.get("sniper_split_angle", 8.0)))
	bytes.encode_float(236, float(configuration.get("gun_discharge_duration", 10.0)))
	return bytes

func _upload_ring_commands_rd(upload: Array) -> void:
	var start_slot := -1
	var next_slot := -1
	var bytes := PackedByteArray()
	for command: Dictionary in upload:
		var slot := int(command.slot)
		if start_slot >= 0 and slot != next_slot:
			_rd.buffer_update(_buffers[5], start_slot * COMMAND_STRIDE, bytes.size(), bytes)
			bytes = PackedByteArray()
			start_slot = -1
		if start_slot < 0:
			start_slot = slot
		bytes.append_array(EmitterCodec.encode(command))
		next_slot = slot + 1
	if not bytes.is_empty():
		_rd.buffer_update(_buffers[5], start_slot * COMMAND_STRIDE, bytes.size(), bytes)

func _execute_rd(generation_id: int, batch: Array, upload: Array, rescues: Array, tail: int, request_stats: bool) -> void:
	if generation_id != _generation or _rd == null or not _pipeline.is_valid():
		return
	_last_submitted_tail_rd = tail
	var submit_started := Time.get_ticks_usec()
	_last_substep_count = batch.size()
	# 异步回读回调所在帧可能没有我们的标签；每次渲染线程批处理都缓存最近有效GPU样本。
	_update_timestamp()
	# 连续环槽合并上传，回绕处分两段；不为每条32B命令重复申请一次更新。
	_upload_ring_commands_rd(upload)
	# 优先槽成功执行后GPU会清空；仍明确清理上批未执行的槽，防止重放。
	# 从未写入或已清零时，不再每个空批分配/上传384字节。
	if not rescues.is_empty() or _priorities_present_rd:
		var priorities := PackedByteArray()
		priorities.resize(12 * COMMAND_STRIDE)
		for command: Dictionary in rescues:
			var bytes := EmitterCodec.encode(command)
			var slot := int(command.team)
			if int(command.op) != 6:
				slot = 4 + int(command.team) * 2 + (1 if int(command.op) == 5 else 0)
			var offset := slot * COMMAND_STRIDE
			for index: int in COMMAND_STRIDE:
				priorities[offset + index] = bytes[index]
		_rd.buffer_update(_buffers[5], RING_CAPACITY * COMMAND_STRIDE, priorities.size(), priorities)
		_priorities_present_rd = not rescues.is_empty()
	if batch.is_empty() and upload.is_empty() and rescues.is_empty():
		if request_stats:
			var stats_list := _rd.compute_list_begin()
			_statistics_dispatch(stats_list, tail, _last_submitted_sim_time_rd)
			_rd.compute_list_end()
			_schedule_stats_read(generation_id)
		return
	_metrics_dirty_rd = true
	var batch_metadata := _new_batch_metadata_rd(batch, _last_submitted_sim_time_rd)
	var batch_label := "CWB|%d|%d|" % [generation_id, int(batch_metadata.batch_id)]
	_rd.capture_timestamp(batch_label + "B")
	if _stage_profile_requested_rd and not batch.is_empty():
		_stage_profile_requested_rd = false
		_stage_profile_recording_rd = true
		_stage_profile_ordinal_rd = 0
		_stage_profile_metadata_rd = batch_metadata.duplicate(true)
		_stage_profile_metadata_rd.merge({"status":"WAITING_FOR_TIMESTAMPS", "sampled_substeps":1, "batch_substeps":batch.size(), "sampled_substep_index":0, "sampled_substep_dt":float(batch.front().x), "sampled_substep_sim_end":float(batch.front().y), "skipped_substeps":maxi(batch.size() - 1, 0), "sampled_final_render":true, "profile_changes_command_list_boundaries":true, "max_stage_pairs":64, "max_stage_queries":128, "expected_stage_pairs":0, "skipped_stage_dispatches":0, "recorded_at_usec":Time.get_ticks_usec(), "gpu_wait_scope":"pure CPU/GPU queue wait is not measured", "dispatches":[]}, true)
	var list := _rd.compute_list_begin()
	if batch.is_empty():
		_dispatch(list, 1, 1, 0, tail, 0.0, _last_submitted_sim_time_rd)
		_dispatch(list, 11, 1, 0, tail, 0.0, _last_submitted_sim_time_rd)
	var substep_index := 0
	for timing: Vector2 in batch:
		_stage_profile_sample_dispatch_rd = _stage_profile_recording_rd and substep_index == 0
		# 唯一正确依赖顺序。每个 pass 屏障同时覆盖 SSBO 和输出图像。
		_dispatch(list, 1, 1, 0, tail, timing.x, timing.y)
		_dispatch(list, 11, 1, 0, tail, timing.x, timing.y)
		_dispatch(list, 2, int(_rt_settings.particle_capacity) + BIG_CAPACITY, 0, tail, timing.x, timing.y)
		_dispatch(list, 3, GRID_HEADS, 0, tail, timing.x, timing.y)
		_dispatch(list, 4, int(_rt_settings.particle_capacity), 0, tail, timing.x, timing.y)
		# 首接触查询只读共享几何并行执行；屏障后单写者扣账染地，最后才做粒子抵消。
		_dispatch(list, 13, int(_rt_settings.particle_capacity), 0, tail, timing.x, timing.y)
		_dispatch(list, 14, 1, 0, tail, timing.x, timing.y)
		for color: int in 9:
			_dispatch(list, 5, CollisionRules.PHASE_WIDTH * CollisionRules.PHASE_WIDTH, color, tail, timing.x, timing.y)
		_dispatch(list, 6, 1, 0, tail, timing.x, timing.y)
		_dispatch(list, 12, 1, 0, tail, timing.x, timing.y)
		substep_index += 1
	_stage_profile_sample_dispatch_rd = false
	var last_time: float = batch.back().y if not batch.is_empty() else _last_submitted_sim_time_rd
	# UI只在读回时需要归约；物理不读取这些总数，避免每批重复扫描全部容量。
	if request_stats:
		_statistics_dispatch(list, tail, last_time)
	_stage_profile_sample_dispatch_rd = _stage_profile_recording_rd
	_render_dispatch(list, tail, last_time)
	_stage_profile_sample_dispatch_rd = false
	_rd.compute_list_end()
	_rd.capture_timestamp(batch_label + "E")
	if not batch.is_empty():
		_last_submitted_sim_time_rd = float(batch.back().y)
		_schedule_critical_team_read(generation_id)
	_last_submit_cpu_ms = float(Time.get_ticks_usec() - submit_started) / 1000.0
	batch_metadata["cpu_submit_ms"] = _last_submit_cpu_ms
	_last_batch_metadata_rd = batch_metadata.duplicate(true)
	if _stage_profile_recording_rd:
		_stage_profile_metadata_rd["cpu_submit_ms"] = _last_submit_cpu_ms
		_stage_profiles_waiting_rd[int(batch_metadata.batch_id)] = _stage_profile_metadata_rd.duplicate(true)
		call_deferred("_stage_profile_main", generation_id, _stage_profile_metadata_rd.duplicate(true))
		_stage_profile_recording_rd = false
		_stage_profile_metadata_rd = {}
	if request_stats:
		_schedule_stats_read(generation_id, batch_metadata)

func _execute_paint_rd(generation_id: int, commands: Array) -> void:
	if generation_id != _generation or _shutting_down or _rd == null or not _pipeline.is_valid() or commands.is_empty():
		return
	var grid := int(_rt_settings.grid_size)
	var unit := CollisionRules.WORLD_SIZE / float(grid)
	var low := Vector2i(grid - 1, grid - 1)
	var high := Vector2i.ZERO
	var rows := PackedByteArray()
	var count := 0
	for command: Dictionary in commands:
		if count >= PAINT_BATCH_CAPACITY:
			break
		if int(command.team) < 0 or int(command.team) >= int(_rt_settings.get("team_count", 4)):
			continue
		var center := Vector2(float(command.x), float(command.y))
		var radius := float(command.radius)
		low.x = mini(low.x, clampi(int(floor((center.x - radius) / unit)), 0, grid - 1))
		low.y = mini(low.y, clampi(int(floor((center.y - radius) / unit)), 0, grid - 1))
		high.x = maxi(high.x, clampi(int(floor((center.x + radius) / unit)), 0, grid - 1))
		high.y = maxi(high.y, clampi(int(floor((center.y + radius) / unit)), 0, grid - 1))
		rows.append_array(EmitterCodec.encode(command))
		count += 1
	if count == 0:
		return
	var width := high.x - low.x + 1
	var height := high.y - low.y + 1
	var header := PackedByteArray()
	header.resize(COMMAND_STRIDE)
	header.encode_u32(0, count)
	header.encode_u32(4, low.x)
	header.encode_u32(8, low.y)
	header.encode_u32(12, width)
	header.encode_u32(16, height)
	_rd.buffer_update(_buffers[5], PAINT_COMMAND_BASE * COMMAND_STRIDE, rows.size(), rows)
	_rd.buffer_update(_buffers[5], (PAINT_COMMAND_BASE + PAINT_BATCH_CAPACITY) * COMMAND_STRIDE, COMMAND_STRIDE, header)
	var list := _rd.compute_list_begin()
	_dispatch(list, 15, width * height, 0, _last_submitted_tail_rd, 0.0, _last_submitted_sim_time_rd)
	_render_dispatch(list, _last_submitted_tail_rd, _last_submitted_sim_time_rd)
	_rd.compute_list_end()
	_metrics_dirty_rd = true

func _execute_rescues_rd(generation_id: int, resolutions: Array) -> void:
	if generation_id != _generation or _shutting_down or _rd == null or not _pipeline.is_valid() or resolutions.is_empty():
		return
	# 只覆盖4个救援槽。flag4令prepare只执行救援，不重放其他命令或武器。
	var priorities := PackedByteArray()
	priorities.resize(4 * COMMAND_STRIDE)
	for resolution: Dictionary in resolutions:
		var bytes := EmitterCodec.encode(resolution)
		var offset := int(resolution.team) * COMMAND_STRIDE
		for index: int in COMMAND_STRIDE:
			priorities[offset + index] = bytes[index]
	_rd.buffer_update(_buffers[5], RING_CAPACITY * COMMAND_STRIDE, priorities.size(), priorities)
	var list := _rd.compute_list_begin()
	_dispatch(list, 1, 1, 0, _last_submitted_tail_rd, 0.0, _last_submitted_sim_time_rd, 4)
	_render_dispatch(list, _last_submitted_tail_rd, _last_submitted_sim_time_rd)
	_rd.compute_list_end()
	_metrics_dirty_rd = true
	_schedule_critical_team_read(generation_id)

func _dispatch(list: int, mode: int, elements: int, color: int, tail: int, dt: float, sim_time: float, flags: int = 0) -> void:
	if mode < 0 or mode >= _pipelines.size() or not _pipelines[mode].is_valid():
		push_error("GPU 计算模式 %d 缺少专用管线。" % mode)
		return
	if _stage_profile_recording_rd and _stage_profile_sample_dispatch_rd:
		if _stage_profile_ordinal_rd < 64:
			var ordinal := _stage_profile_ordinal_rd
			_stage_profile_ordinal_rd += 1
			var label := "CWS|%d|%d|%d|%d|%d|" % [_generation, int(_stage_profile_metadata_rd.batch_id), ordinal, mode, color]
			var dispatches: Array = _stage_profile_metadata_rd.dispatches
			dispatches.append({"ordinal":ordinal, "mode":mode, "color":color, "scope":"final_render" if mode in [8, 9, 10] else "first_substep"})
			_stage_profile_metadata_rd["expected_stage_pairs"] = dispatches.size()
			# Godot禁止在已经dispatch的compute list内部capture_timestamp。
			# 只有手动采样拆列表；compute_list_begin返回固定ComputeListID，调用者旧ID仍有效。
			_rd.compute_list_end()
			_rd.capture_timestamp(label + "B")
			var measured := _rd.compute_list_begin()
			_dispatch_commands(measured, mode, elements, color, tail, dt, sim_time, flags)
			_rd.compute_list_end()
			_rd.capture_timestamp(label + "E")
			_rd.compute_list_begin()
			return
		_stage_profile_metadata_rd["skipped_stage_dispatches"] = int(_stage_profile_metadata_rd.skipped_stage_dispatches) + 1
	_dispatch_commands(list, mode, elements, color, tail, dt, sim_time, flags)

func _dispatch_commands(list: int, mode: int, elements: int, color: int, tail: int, dt: float, sim_time: float, flags: int) -> void:
	_rd.compute_list_bind_compute_pipeline(list, _pipelines[mode])
	_rd.compute_list_bind_uniform_set(list, _uniform_set, 0)
	var push := PackedByteArray()
	push.resize(32)
	push.encode_u32(0, mode)
	push.encode_u32(4, color)
	push.encode_u32(8, tail)
	push.encode_u32(12, flags | (2 if bool(_rt_settings.get("gpu_profiling", false)) else 0))
	push.encode_float(16, dt)
	push.encode_float(20, sim_time)
	_rd.compute_list_set_push_constant(list, push, push.size())
	if mode == 5:
		_rd.compute_list_dispatch_indirect(list, _buffers[11], (32 + color * 3) * 4)
	elif mode == 2 or mode == 4 or mode == 9 or mode == 13:
		_rd.compute_list_dispatch_indirect(list, _buffers[11], 0 if mode == 4 or mode == 13 else 12)
	else:
		_rd.compute_list_dispatch(list, maxi(1, (elements + 63) / 64), 1, 1)
	_rd.compute_list_add_barrier(list)

func _render_dispatch(list: int, tail: int, sim_time: float) -> void:
	var pixels := int(_rt_settings.render_size) * int(_rt_settings.render_size)
	_dispatch(list, 8, pixels, 0, tail, 0.0, sim_time)
	_dispatch(list, 9, int(_rt_settings.particle_capacity) + BIG_CAPACITY, 0, tail, 0.0, sim_time)
	_dispatch(list, 10, pixels, 0, tail, 0.0, sim_time)

func _statistics_dispatch(list: int, tail: int, sim_time: float) -> void:
	# 领土计数由GPU归属变更出口维护；此处只在低频读回/显式Debug统计粒子。
	if not _metrics_dirty_rd:
		return
	_dispatch(list, 7, 1, 0, tail, 0.0, sim_time, 1)
	_metrics_dirty_rd = false

func _schedule_stats_read(generation_id: int, batch_metadata: Dictionary = {}) -> void:
	_last_blocking_readback_ms = 0.0
	var combined := {"generation":generation_id, "parts":{}, "debug":false, "expected":4, "read_started_us":Time.get_ticks_usec()}
	combined["batch_metadata"] = (batch_metadata if not batch_metadata.is_empty() else _last_batch_metadata_rd).duplicate(true)
	_team_read_sequence_rd += 1
	combined["team_sequence"] = _team_read_sequence_rd
	_read_buffer(_buffers[6], "metrics", combined, 0, METRICS_WORDS * 4)
	_read_buffer(_buffers[1], "teams", combined, 0, 4 * TEAM_STRIDE)
	_read_buffer(_buffers[0], "balls", combined, int(_rt_settings.particle_capacity) * PARTICLE_STRIDE, BIG_CAPACITY * PARTICLE_STRIDE)
	_read_buffer(_buffers[11], "diagnostics", combined, 0, DIAGNOSTIC_WORDS * 4)

func _schedule_critical_team_read(generation_id: int) -> void:
	if generation_id != _generation or _shutting_down or _critical_read_in_flight_rd or _rd == null:
		return
	# 无异步API的老引擎保留低频通知，不能用逐帧同步回读阻塞GUI。
	if not _rd.has_method("buffer_get_data_async"):
		return
	_critical_read_in_flight_rd = true
	_team_read_sequence_rd += 1
	var combined := {"generation":generation_id, "parts":{}, "debug":false, "critical":true, "expected":1, "team_sequence":_team_read_sequence_rd, "read_started_us":Time.get_ticks_usec()}
	_read_buffer(_buffers[1], "teams", combined, 0, 4 * TEAM_STRIDE)

func _critical_team_main(combined: Dictionary) -> void:
	if int(combined.generation) != _generation or _shutting_down:
		return
	var bytes: PackedByteArray = combined.parts.teams
	var sequence := int(combined.team_sequence)
	for index: int in 4:
		_observe_rescue_state(index, int(bytes.decode_u32(index * TEAM_STRIDE + 32)), int(bytes.decode_u32(index * TEAM_STRIDE + 36)), sequence)

func _observe_rescue_state(team: int, state: int, nonce: int, sequence: int) -> void:
	if team >= active_team_count:
		return
	# 两种通道可能乱序完成。见过较新快照后不能用旧遥测重放旧请求。
	if sequence <= int(_rescue_team_sequence[team]):
		return
	_rescue_team_sequence[team] = sequence
	if state == 1 and int(_rescue_notified[team]) != nonce:
		_rescue_notified[team] = nonce
		rescue_requested.emit(team)

func _read_buffer(buffer: RID, key: String, combined: Dictionary, offset: int, length_bytes: int) -> void:
	# Godot4.4+异步。4.3兼容仅低频读这几个小表，仍无逐帧粒子/图像读回。
	if int(combined.generation) != _generation or _shutting_down:
		return
	if not combined.has("read_lengths"):
		combined["read_lengths"] = {}
	combined.read_lengths[key] = length_bytes
	pending_readbacks += 1
	if _rd.has_method("buffer_get_data_async"):
		var result: Variant = _rd.call("buffer_get_data_async", buffer, _read_part.bind(key, combined), offset, length_bytes)
		if result is int and result != OK:
			combined["read_error"] = "GPU 异步回读 %s 失败：%s" % [key, error_string(int(result))]
			_read_part(PackedByteArray(), key, combined)
	else:
		var started := Time.get_ticks_usec()
		var bytes := _rd.buffer_get_data(buffer, offset, length_bytes)
		var waited_ms := float(Time.get_ticks_usec() - started) / 1000.0
		_last_blocking_readback_ms += waited_ms
		combined["blocking_readback_ms"] = float(combined.get("blocking_readback_ms", 0.0)) + waited_ms
		_read_part(bytes, key, combined)

func _read_part(bytes: PackedByteArray, key: String, combined: Dictionary) -> void:
	pending_readbacks -= 1
	if int(combined.generation) != _generation or _shutting_down:
		# 旧代只归还已有任务；不读取新一代时间戳、不发通知、不触发新读回。
		if _shutting_down and pending_readbacks == 0:
			call_deferred("_readbacks_drained_main")
		return
	if bytes.size() != int(combined.read_lengths.get(key, bytes.size())):
		combined["read_error"] = "GPU 回读 %s 字节数不完整（%d / %d）。" % [key, bytes.size(), int(combined.read_lengths[key])]
	combined.parts[key] = bytes
	if combined.parts.size() == int(combined.get("expected", 3)):
		if bool(combined.get("critical", false)):
			_critical_read_in_flight_rd = false
		if combined.has("read_error"):
			call_deferred("_failed_main", int(combined.generation), str(combined.read_error))
			return
		combined["readback_latency_ms"] = float(Time.get_ticks_usec() - int(combined.get("read_started_us", Time.get_ticks_usec()))) / 1000.0
		if bool(combined.get("critical", false)):
			call_deferred("_critical_team_main", combined)
		elif bool(combined.debug):
			call_deferred("_debug_snapshot_main", combined)
		else:
			_update_timestamp()
			var metadata: Dictionary = combined.get("batch_metadata", {})
			var timing: Dictionary = _batch_gpu_times_rd.get(int(metadata.get("batch_id", -1)), {})
			combined["gpu_timing"] = timing.duplicate(true)
			combined["latest_gpu_batch_timing"] = _batch_gpu_times_rd.get(_last_gpu_batch_id_rd, {}).duplicate(true)
			call_deferred("_stats_main", combined, float(timing.get("gpu_ms", -1.0)))

func _update_timestamp() -> void:
	if _rd == null:
		return
	var captured_frame := _rd.get_captured_timestamps_frame()
	if captured_frame != _last_timestamp_frame_rd:
		_last_timestamp_frame_rd = captured_frame
		var batches: Dictionary = {}
		var stages: Dictionary = {}
		for index: int in _rd.get_captured_timestamps_count():
			var parts := _rd.get_captured_timestamp_name(index).split("|")
			if parts.size() < 4 or parts[0] not in ["CWB", "CWS"] or int(parts[1]) != _generation:
				continue
			var batch_id := int(parts[2])
			if parts[0] == "CWB" and parts.size() == 4:
				if not batches.has(batch_id): batches[batch_id] = {}
				batches[batch_id][parts[3]] = _rd.get_captured_timestamp_gpu_time(index)
			elif parts[0] == "CWS" and parts.size() == 7:
				if not stages.has(batch_id): stages[batch_id] = {}
				var ordinal := int(parts[3])
				if not stages[batch_id].has(ordinal): stages[batch_id][ordinal] = {}
				stages[batch_id][ordinal][parts[6]] = _rd.get_captured_timestamp_gpu_time(index)
		for batch_id: int in batches:
			var points: Dictionary = batches[batch_id]
			if not points.has("B") or not points.has("E") or int(points.E) < int(points.B):
				continue
			# Vulkan实际timestamp单位为纳秒；CPU timestamp才是微秒。
			var duration_ms := float(int(points.E) - int(points.B)) / 1000000.0
			_batch_gpu_times_rd[batch_id] = {"generation":_generation, "batch_id":batch_id, "gpu_ms":duration_ms, "captured_frame":captured_frame}
			if batch_id >= _last_gpu_batch_id_rd:
				_last_gpu_batch_id_rd = batch_id
				_last_gpu_ms = duration_ms
		while _batch_gpu_times_rd.size() > 128:
			_batch_gpu_times_rd.erase(_batch_gpu_times_rd.keys()[0])
		for batch_id: int in _stage_profiles_waiting_rd.keys():
			if stages.has(batch_id) or batches.has(batch_id):
				_publish_stage_profile_rd(batch_id, stages.get(batch_id, {}), captured_frame)
	# 丢失或不支持的timestamp不能永远显示等待，也不能把缺测当0ms。
	for batch_id: int in _stage_profiles_waiting_rd.keys():
		var profile: Dictionary = _stage_profiles_waiting_rd[batch_id]
		if Time.get_ticks_usec() - int(profile.recorded_at_usec) > 30000000:
			_publish_stage_profile_rd(batch_id, {}, captured_frame)

func _publish_stage_profile_rd(batch_id: int, points: Dictionary, captured_frame: int) -> void:
	var profile: Dictionary = _stage_profiles_waiting_rd[batch_id].duplicate(true)
	_stage_profiles_waiting_rd.erase(batch_id)
	var mode_sums: Dictionary = {}
	var mode_expected: Dictionary = {}
	var mode_observed: Dictionary = {}
	var measured: Array[Dictionary] = []
	var missing := 0
	for description: Dictionary in profile.dispatches:
		var item := description.duplicate(true)
		var key := str(int(item.mode))
		mode_expected[key] = int(mode_expected.get(key, 0)) + 1
		var pair: Dictionary = points.get(int(item.ordinal), {})
		if pair.has("B") and pair.has("E") and int(pair.E) >= int(pair.B):
			var milliseconds := float(int(pair.E) - int(pair.B)) / 1000000.0
			item["status"] = "MEASURED"
			item["gpu_ms"] = milliseconds
			mode_sums[key] = float(mode_sums.get(key, 0.0)) + milliseconds
			mode_observed[key] = int(mode_observed.get(key, 0)) + 1
		else:
			missing += 1
			item["status"] = "UNAVAILABLE"
			item["gpu_ms"] = null
		measured.append(item)
	var by_mode: Dictionary = {}
	for key: String in mode_expected:
		var complete := int(mode_observed.get(key, 0)) == int(mode_expected[key])
		by_mode[key] = {"gpu_ms":mode_sums.get(key) if complete else null, "measured_dispatches":int(mode_observed.get(key, 0)), "expected_dispatches":int(mode_expected[key]), "status":"MEASURED" if complete else "PARTIAL"}
	var batch_timing: Dictionary = _batch_gpu_times_rd.get(batch_id, {})
	profile["status"] = "COMPLETE" if missing == 0 and int(profile.skipped_stage_dispatches) == 0 and not batch_timing.is_empty() else "PARTIAL"
	profile["measurement_is_test_result"] = false
	profile["captured_frame"] = captured_frame
	profile["measured_stage_pairs"] = measured.size() - missing
	profile["missing_stage_pairs"] = missing
	profile["batch_gpu_ms"] = batch_timing.get("gpu_ms")
	profile["batch_gpu_time_scope"] = "whole simulated batch and final render; stages sample first GPU substep only"
	profile["gpu_ms_by_mode"] = by_mode
	profile["nine_color_gpu_ms"] = by_mode.get("5", {}).get("gpu_ms")
	profile["serial_terrain_gpu_ms"] = by_mode.get("14", {}).get("gpu_ms")
	profile["serial_entity_gpu_ms"] = by_mode.get("6", {}).get("gpu_ms")
	profile["dispatches"] = measured
	profile["unmeasured_substeps"] = {"count":int(profile.skipped_substeps), "gpu_ms":null, "status":"NOT_SAMPLED"}
	profile["pure_rd_wait_ms"] = null
	call_deferred("_stage_profile_main", _generation, profile)

func _decode_energy(bytes: PackedByteArray, offset: int) -> int:
	return int(bytes.decode_u32(offset)) | (int(bytes.decode_u32(offset + 4)) << 32)

func _decode_team(bytes: PackedByteArray, index: int, sim_time: float) -> Dictionary:
	var offset := index * TEAM_STRIDE
	var state := int(bytes.decode_u32(offset + 32))
	return {"team":index, "enabled":index < active_team_count, "shield":_decode_energy(bytes, offset), "gun":_decode_energy(bytes, offset + 8), "storm":_decode_energy(bytes, offset + 16), "sniper":_decode_energy(bytes, offset + 24), "state":state, "alive":index < active_team_count and state != 2, "pending":index < active_team_count and state == 1, "request_nonce":int(bytes.decode_u32(offset + 36)), "death_nonce":int(bytes.decode_u32(offset + 40)), "rescue_cd":maxf(0.0, bytes.decode_float(offset + 48) - sim_time), "ready_time":bytes.decode_float(offset + 48), "gun_phase":bytes.decode_float(offset + 52), "gun_angle":bytes.decode_float(offset + 56), "gun_target_angle":bytes.decode_float(offset + 116), "gun_mode":bytes.decode_float(offset + 120), "x":bytes.decode_float(offset + 80), "y":bytes.decode_float(offset + 84), "core_radius":bytes.decode_float(offset + 88), "shield_radius":bytes.decode_float(offset + 92)}

func _decode_particles(bytes: PackedByteArray, first_id: int = 0) -> Array[Dictionary]:
	var particles: Array[Dictionary] = []
	for index: int in bytes.size() / PARTICLE_STRIDE:
		var offset := index * PARTICLE_STRIDE
		if bytes.decode_u32(offset + 28) == 0:
			continue
		var contact_and_generation := int(bytes.decode_u32(offset + 48))
		particles.append({"id":first_id + index, "x":bytes.decode_float(offset), "y":bytes.decode_float(offset + 4), "vx":bytes.decode_float(offset + 8), "vy":bytes.decode_float(offset + 12), "energy":_decode_energy(bytes, offset + 16), "team":int(bytes.decode_u32(offset + 24)), "type":int(bytes.decode_u32(offset + 28)), "radius":bytes.decode_float(offset + 32), "birth_scale":bytes.decode_float(offset + 36), "contact_mask":contact_and_generation & 0xf, "generation":contact_and_generation >> 4, "particle_generation":contact_and_generation >> 4, "sniper_level":int(bytes.decode_u32(offset + 52)) & 3, "level":int(bytes.decode_u32(offset + 52)) & 3, "flags":int(bytes.decode_u32(offset + 56)), "pending_split":(int(bytes.decode_u32(offset + 56)) & 0x40000000) != 0})
	return particles

func _decode_diagnostics(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < DIAGNOSTIC_WORDS * 4:
		return {}
	var active_by_team: Array[int] = []
	for team_index: int in 4:
		active_by_team.append(int(bytes.decode_u32((16 + team_index) * 4)))
	var collision_groups: Array[int] = []
	for color: int in 9:
		collision_groups.append(int(bytes.decode_u32((32 + color * 3) * 4)))
	return {"profiling_enabled":bool(settings.get("gpu_profiling", false)), "collision_candidates":int(bytes.decode_u32(32)), "actual_contacts":int(bytes.decode_u32(36)), "pool_live_ids":int(bytes.decode_u32(40)), "pool_normal_free":int(bytes.decode_u32(44)), "pool_sniper_free":int(bytes.decode_u32(48)), "normal_dispatch_groups":int(bytes.decode_u32(0)), "motion_dispatch_groups":int(bytes.decode_u32(12)), "collision_dispatch_groups_by_color":collision_groups, "gpu_allocation_bytes":_memory_bytes, "active_by_team":active_by_team}

func _decode_weapon_states(bytes: PackedByteArray) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for index: int in mini(4, bytes.size() / WEAPON_STRIDE):
		var offset := index * WEAPON_STRIDE
		var words: Array[int] = []
		for word: int in range(WEAPON_STRIDE >> 2):
			words.append(int(bytes.decode_u32(offset + word * 4)))
		var quotient := _decode_energy(bytes, offset)
		var plan_slots := int(bytes.decode_u32(offset + 128))
		var plan_remainder := int(bytes.decode_u32(offset + 136))
		result.append({"gun_shot_energy":quotient, "gun_target":int(bytes.decode_u32(offset + 8)), "gun_target_generation":int(bytes.decode_u32(offset + 12)), "target_switch_ready":bytes.decode_float(offset + 16), "gun_paint_target_cell":int(bytes.decode_float(offset + 20)), "gun_paint_cursor":int(bytes.decode_float(offset + 24)), "gun_paint_scan_cells":int(bytes.decode_float(offset + 28)), "storm_total_shots":int(bytes.decode_u32(offset + 32)), "storm_next_shot":int(bytes.decode_u32(offset + 36)), "storm_rings":int(bytes.decode_u32(offset + 40)), "storm_ring":int(bytes.decode_u32(offset + 44)), "storm_base_energy":_decode_energy(bytes, offset + 48), "storm_remainder":_decode_energy(bytes, offset + 56), "next_ring_time":bytes.decode_float(offset + 64), "last_ring_complete_time":bytes.decode_float(offset + 72), "storm_completed_events":int(bytes.decode_u32(offset + 112)), "storm_completed_rings":int(bytes.decode_u32(offset + 116)), "sniper_split_count":int(bytes.decode_u32(offset + 120)), "shield_reference_energy":bytes.decode_float(offset + 80), "shield_expansion_radius":bytes.decode_float(offset + 84), "gun_plan_slots":plan_slots, "gun_plan_ordinal":int(bytes.decode_u32(offset + 132)), "gun_plan_remainder":plan_remainder, "gun_plan_carry":int(bytes.decode_u32(offset + 140)), "gun_plan_energy":quotient * plan_slots + plan_remainder, "gun_plan_start":bytes.decode_float(offset + 144), "gun_plan_deadline":bytes.decode_float(offset + 148), "gun_plan_rate":bytes.decode_float(offset + 152), "gun_plan_duration":bytes.decode_float(offset + 156), "gun_refill_pending":int(bytes.decode_u32(offset + 124)), "raw_words":words})
		var weapon_state: Dictionary = result.back()
		weapon_state["rescue_defense_reserve"] = _decode_energy(bytes, offset + 160)
	return result

func _stats_main(combined: Dictionary, gpu_ms: float) -> void:
	if int(combined.generation) != _generation:
		return
	_read_in_flight = false
	_last_read_metrics = combined.parts.metrics
	_last_read_teams = combined.parts.teams
	_last_read_balls = combined.parts.balls
	_last_read_diagnostics = combined.parts.diagnostics
	_last_readback_latency_ms = float(combined.get("readback_latency_ms", 0.0))
	var metrics: PackedByteArray = combined.parts.metrics
	var sim_time := float(metrics.decode_float(76))
	var teams: Array[Dictionary] = []
	for index: int in 4:
		var team := _decode_team(combined.parts.teams, index, sim_time)
		team["territory"] = float(metrics.decode_u32((8 + index) * 4)) / float(int(settings.grid_size) * int(settings.grid_size))
		teams.append(team)
	_ring_head = int(metrics.decode_u32(16))
	var cpu_queue_energy := 0.0
	for command: Dictionary in _queued:
		cpu_queue_energy += float(command.get("energy", 0.0))
	var queued_energy := cpu_queue_energy + float(_decode_energy(metrics, 100))
	for team: Dictionary in teams:
		queued_energy += float(team.storm) + float(team.sniper)
	# 粒子保存自身的真实整数能量；能量>1不会追溯改变或引入时间成本。
	var actual_precision := str(settings.precision_mode)
	stats = {"device":_device_name, "memory_mb":float(_memory_bytes) / 1048576.0, "gpu_ms":gpu_ms, "precision_mode":actual_precision, "rejected_dead_commands":int(metrics.decode_u32(112)), "active_particles":int(metrics.decode_u32(0)), "big_balls":int(metrics.decode_u32(4)), "collisions":int(metrics.decode_u32(8)), "captures":int(metrics.decode_u32(12)), "command_head":_ring_head, "queue_commands":int(metrics.decode_u32(20)) + _queued.size(), "command_ring_occupancy":int(metrics.decode_u32(108)), "queue_energy":queued_energy, "max_cell_occupancy":int(metrics.decode_u32(24)), "step":int(metrics.decode_u32(28)), "overflow_count":int(metrics.decode_u32(60)), "packing_count":int(metrics.decode_u32(56)), "packing_ratio":float(metrics.decode_u32(88)) / float(maxi(1, int(metrics.decode_u32(0)))), "active_packet_energy":_decode_energy(metrics, 92), "consumed_energy":_decode_energy(metrics, 68), "sim_time":sim_time, "teams":teams, "balls":_decode_particles(combined.parts.balls), "grid_size":int(settings.grid_size), "particle_capacity":int(settings.particle_capacity), "packet_energy":int(settings.packet_energy)}
	stats.merge(_decode_diagnostics(_last_read_diagnostics), true)
	stats["active_team_count"] = active_team_count
	var batch_metadata: Dictionary = combined.get("batch_metadata", {})
	stats["batch_metadata"] = batch_metadata.duplicate(true)
	stats["substeps_in_last_batch"] = int(batch_metadata.get("substeps", 0))
	stats["cpu_submit_ms"] = float(batch_metadata.get("cpu_submit_ms", -1.0))
	stats["gpu_batch_id"] = combined.get("gpu_timing", {}).get("batch_id")
	stats["gpu_ms_status"] = "MEASURED_FOR_READBACK_BATCH" if gpu_ms >= 0.0 else "UNAVAILABLE_FOR_READBACK_BATCH"
	stats["gpu_ms_scope"] = "whole batch and render; not one physics substep"
	stats["latest_gpu_batch_timing"] = combined.get("latest_gpu_batch_timing", {}).duplicate(true)
	# Async completion includes queueing/frame scheduling, not a blocking CPU
	# wait. Keep its name explicit so benchmarks do not call it GPU sync time.
	stats["async_readback_latency_ms"] = _last_readback_latency_ms
	stats["blocking_readback"] = not _rd.has_method("buffer_get_data_async")
	stats["explicit_cpu_gpu_sync_wait_ms"] = float(combined.get("blocking_readback_ms", 0.0))
	stats["cpu_gpu_sync_wait_scope"] = "synchronous buffer_get_data fallback only; other RenderingDevice waits are not measured"
	stats_updated.emit(stats)
	if int(metrics.decode_u32(60)) != 0:
		_failed_main(_generation, "GPU 能量累加超出当前受支持整数上限（2^63−1）。已停止模拟并保留待发命令；请降低数值增长或重新开局。")
		return
	for index: int in 4:
		_observe_rescue_state(index, int(teams[index].state), int(teams[index].request_nonce), int(combined.get("team_sequence", -1)))
		if bool(teams[index].enabled) and not bool(teams[index].alive) and not bool(_death_notified[index]):
			_death_notified[index] = true
			team_eliminated.emit(index)

func _debug_read_rd(generation_id: int, kind: String, sequence: int) -> void:
	if generation_id != _generation or _rd == null or _buffers.is_empty():
		return
	_last_blocking_readback_ms = 0.0
	# 独立测试要求即时精确总数，不能误取上次0.25秒遥测快照；正式路径不走此入口。
	var list := _rd.compute_list_begin()
	_statistics_dispatch(list, _ring_tail, float(stats.get("sim_time", 0.0)))
	_rd.compute_list_end()
	var combined := {"generation":generation_id, "parts":{}, "debug":true, "request_id":sequence, "kind":kind, "expected":9, "read_started_us":Time.get_ticks_usec(), "cpu_submit_ms":_last_submit_cpu_ms, "substeps":_last_substep_count}
	_read_buffer(_buffers[6], "metrics", combined, 0, METRICS_WORDS * 4)
	_read_buffer(_buffers[1], "teams", combined, 0, 4 * TEAM_STRIDE)
	_read_buffer(_buffers[0], "balls", combined, int(_rt_settings.particle_capacity) * PARTICLE_STRIDE, BIG_CAPACITY * PARTICLE_STRIDE)
	var particle_count := int(_rt_settings.particle_capacity) if kind == "all_particles" else mini(64, int(_rt_settings.particle_capacity))
	_read_buffer(_buffers[0], "particles", combined, 0, particle_count * PARTICLE_STRIDE)
	_read_buffer(_buffers[0], "snipers", combined, (int(_rt_settings.particle_capacity) - 8) * PARTICLE_STRIDE, 8 * PARTICLE_STRIDE)
	_read_buffer(_buffers[11], "diagnostics", combined, 0, DIAGNOSTIC_WORDS * 4)
	_read_buffer(_buffers[9], "weapons", combined, 0, WEAPON_STATE_BYTES)
	_read_buffer(_buffers[10], "pool_header", combined, 0, POOL_HEADER_WORDS * 4)
	var terrain_start := 0
	var terrain_count := 64
	if kind.begins_with("terrain:"):
		var chunks := kind.split(":")
		if chunks.size() >= 2:
			terrain_start = clampi(int(chunks[1]), 0, int(_rt_settings.grid_size) * int(_rt_settings.grid_size) - 1)
		if chunks.size() >= 3:
			terrain_count = clampi(int(chunks[2]), 1, 1024)
	terrain_count = mini(terrain_count, int(_rt_settings.grid_size) * int(_rt_settings.grid_size) - terrain_start)
	combined["terrain_start"] = terrain_start
	_read_buffer(_buffers[2], "terrain", combined, terrain_start * 4, terrain_count * 4)

func _debug_snapshot_main(combined: Dictionary) -> void:
	if int(combined.generation) != _generation:
		return
	var bytes: PackedByteArray = combined.parts.metrics
	var sim_time := bytes.decode_float(76)
	var teams: Array[Dictionary] = []
	for index: int in 4:
		teams.append(_decode_team(combined.parts.teams, index, sim_time))
	var territory: Array[int] = []
	var terrain_bytes: PackedByteArray = combined.parts.terrain
	for index: int in terrain_bytes.size() / 4:
		territory.append(int(terrain_bytes.decode_u32(index * 4)))
	var metrics: Array[int] = []
	for index: int in METRICS_WORDS:
		metrics.append(int(bytes.decode_u32(index * 4)))
	_cached_debug = {"request_id":int(combined.request_id), "kind":str(combined.kind), "teams":teams, "particles":_decode_particles(combined.parts.particles), "balls":_decode_particles(combined.parts.balls), "terrain_start":int(combined.terrain_start), "terrain":territory, "metrics":metrics, "consumed_energy":_decode_energy(bytes, 68), "sim_time":sim_time}
	_cached_debug["diagnostics"] = _decode_diagnostics(combined.parts.diagnostics)
	_cached_debug["active_team_count"] = active_team_count
	_cached_debug["diagnostics"]["active_team_count"] = active_team_count
	_cached_debug["weapons"] = _decode_weapon_states(combined.parts.weapons)
	_cached_debug["snipers"] = _decode_particles(combined.parts.snipers, int(settings.particle_capacity) - 8)
	var pool_header: Array[int] = []
	for word: int in POOL_HEADER_WORDS:
		pool_header.append(int(combined.parts.pool_header.decode_u32(word * 4)))
	_cached_debug["pool_header"] = pool_header
	_cached_debug["cpu_submit_ms"] = float(combined.get("cpu_submit_ms", 0.0))
	_cached_debug["substeps_in_last_batch"] = int(combined.get("substeps", 0))
	_cached_debug["async_readback_latency_ms"] = float(combined.get("readback_latency_ms", 0.0))
	_cached_debug["explicit_cpu_gpu_sync_wait_ms"] = _last_blocking_readback_ms
	debug_snapshot_ready.emit(_cached_debug.duplicate(true))
