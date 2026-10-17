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
const COMMAND_STRIDE := 32
const PARTICLE_STRIDE := 64
const TEAM_STRIDE := 128
const METRICS_WORDS := 64
const GRID_CELLS := 128 * 128
const GRID_HEADS := GRID_CELLS * 4
const PARAM_FLOATS := 64
const WEAPON_STRIDE := 160
const WEAPON_STATE_BYTES := 4 * WEAPON_STRIDE
const POOL_HEADER_WORDS := 16
const DIAGNOSTIC_WORDS := 32

var texture: Texture2DRD = Texture2DRD.new()
var active := false
var error_message := ""
var stats: Dictionary = {}
var settings: Dictionary = {}
var _steps: Array[Vector2] = []
var _queued: Array[Dictionary] = []
var _resolutions: Array[Dictionary] = []
var _generation := 0
var _shutting_down := false
# 退役节点必须同时等待读回回调归还与渲染线程释放确认，不能用固定帧数猜测。
var pending_readbacks: int = 0
var resource_release_confirmed := true
var _ring_tail := 0
var _ring_head := 0
var _stats_clock := 0.0
var _read_in_flight := false
var _rescue_notified := [-1, -1, -1, -1]
var _death_notified := [false, false, false, false]
var _debug_sequence := 0
var _cached_debug: Dictionary = {}
var _rt_settings: Dictionary = {}
var _rd: RenderingDevice
var _shader: RID
var _pipeline: RID
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
	_generation += 1
	active = false
	texture.texture_rd_rid = RID()
	error_message = ""
	_read_in_flight = false
	_steps.clear()
	_queued.clear()
	_resolutions.clear()
	_ring_tail = 0
	_ring_head = 0
	_rescue_notified = [-1, -1, -1, -1]
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
	if team < 0 or team > 3 or kind < 0 or kind > 4 or energy < 1.0:
		return
	# 无空闲粒子时能量留在 GPU 队列；命令环满时留在此小命令队列。
	# 与GPU的clock/Vector2固定步时间使用相同float32，避免长局末步量化后迟一帧。
	_queued.append({"op":kind + 1, "team":team, "energy":energy, "at_time":float(PackedFloat32Array([at_time])[0])})

func resolve_rescue(team: int, energy: float) -> void:
	if team >= 0 and team < 4:
		var nonce := 0
		var teams: Array = stats.get("teams", [])
		if teams.size() > team:
			nonce = int(teams[team].get("request_nonce", 0))
		_resolutions.append({"op":6, "team":team, "energy":maxf(energy, 0.0), "nonce":nonce})

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
	var batch_end: float = batch.back().y if not batch.is_empty() else float(stats.get("sim_time", 0.0))
	for command: Dictionary in _queued:
		var op := int(command.get("op", 0))
		var at_time := float(PackedFloat32Array([float(command.get("at_time", -1.0))])[0])
		if op >= 1 and op <= 5 and at_time >= 0.0 and batch_end + 0.00001 < at_time:
			# 优先槽每批会清空，超出本批的未来命令必须留在CPU，不能提前占槽后丢失。
			remaining.append(command)
			continue
		if op == 1 or op == 5:
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
	if int(_rd.limit_get(RenderingDevice.LIMIT_MAX_STORAGE_BUFFERS_PER_SHADER_STAGE)) < 12:
		_fail_rd("GPU 每阶段存储缓冲数量少于 12，无法执行全 GPU 战场。", generation)
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
	_pipeline = _rd.compute_pipeline_create(_shader)
	if not _pipeline.is_valid():
		_fail_rd("GPU 计算管线创建失败：请检查 Vulkan 驱动及存储缓冲支持。", generation)
		return
	_resource_rids.append(_pipeline)
	var sizes := [required_particle_bytes, 4 * TEAM_STRIDE, grid_size * grid_size * 4, GRID_HEADS * 4, (capacity + BIG_CAPACITY) * 4, (RING_CAPACITY + 12) * COMMAND_STRIDE, METRICS_WORDS * 4, render_size * render_size * 4, PARAM_FLOATS * 4]
	# Indices 9/10/11 map to bindings 10/11/12. The pool keeps stable physical
	# IDs; indirect dispatch dimensions remain on the GPU with no count readback.
	sizes.append(WEAPON_STATE_BYTES)
	sizes.append((POOL_HEADER_WORDS + capacity * 2) * 4)
	sizes.append(DIAGNOSTIC_WORDS * 4)
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
	_shader = RID()
	_pipeline = RID()
	_uniform_set = RID()
	_output = RID()
	_metrics_dirty_rd = true
	_priorities_present_rd = false
	resource_release_confirmed = _shutting_down and pending_readbacks == 0

func _initialize_dispatch(configuration: Dictionary) -> void:
	var params := _make_params(configuration)
	_rd.buffer_update(_buffers[8], 0, params.size(), params)
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _uniform_set, 0)
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
	# 参数块13：保留布局前两项为0；后两项为风暴环粒子数/环间隔。
	bytes.encode_float(208, 0.0)
	bytes.encode_float(212, 0.0)
	bytes.encode_float(216, float(configuration.get("storm_ring_particles", 360)))
	bytes.encode_float(220, float(configuration.get("storm_ring_interval", 0.10)))
	bytes.encode_float(224, float(configuration.get("gun_target_switch_cd", 0.5)))
	bytes.encode_float(228, float(configuration.get("growth_curve_time", 1200.0)))
	bytes.encode_float(232, float(configuration.get("sniper_split_angle", 8.0)))
	bytes.encode_float(236, float(configuration.get("gun_discharge_duration", 10.0)))
	return bytes

func _execute_rd(generation_id: int, batch: Array, upload: Array, rescues: Array, tail: int, request_stats: bool) -> void:
	if generation_id != _generation or _rd == null or not _pipeline.is_valid():
		return
	var submit_started := Time.get_ticks_usec()
	_last_substep_count = batch.size()
	# 异步回读回调所在帧可能没有我们的标签；每次渲染线程批处理都缓存最近有效GPU样本。
	_update_timestamp()
	for command: Dictionary in upload:
		var bytes := EmitterCodec.encode(command)
		_rd.buffer_update(_buffers[5], int(command.slot) * COMMAND_STRIDE, COMMAND_STRIDE, bytes)
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
			_rd.compute_list_bind_compute_pipeline(stats_list, _pipeline)
			_rd.compute_list_bind_uniform_set(stats_list, _uniform_set, 0)
			_statistics_dispatch(stats_list, tail, float(stats.get("sim_time", 0.0)))
			_rd.compute_list_end()
			_schedule_stats_read(generation_id)
		return
	_metrics_dirty_rd = true
	_rd.capture_timestamp("颜色大战_开始")
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _uniform_set, 0)
	if batch.is_empty():
		_dispatch(list, 1, 1, 0, tail, 0.0, float(stats.get("sim_time", 0.0)))
		_dispatch(list, 11, 1, 0, tail, 0.0, float(stats.get("sim_time", 0.0)))
	for timing: Vector2 in batch:
		# 唯一正确依赖顺序。每个 pass 屏障同时覆盖 SSBO 和输出图像。
		_dispatch(list, 1, 1, 0, tail, timing.x, timing.y)
		_dispatch(list, 11, 1, 0, tail, timing.x, timing.y)
		_dispatch(list, 2, int(_rt_settings.particle_capacity) + BIG_CAPACITY, 0, tail, timing.x, timing.y)
		_dispatch(list, 3, GRID_HEADS, 0, tail, timing.x, timing.y)
		_dispatch(list, 4, int(_rt_settings.particle_capacity), 0, tail, timing.x, timing.y)
		for color: int in 9:
			_dispatch(list, 5, CollisionRules.PHASE_WIDTH * CollisionRules.PHASE_WIDTH, color, tail, timing.x, timing.y)
		_dispatch(list, 6, 1, 0, tail, timing.x, timing.y)
		_dispatch(list, 12, 1, 0, tail, timing.x, timing.y)
	var last_time: float = batch.back().y if not batch.is_empty() else float(stats.get("sim_time", 0.0))
	# UI只在读回时需要归约；物理不读取这些总数，避免每批重复扫描全部容量。
	if request_stats:
		_statistics_dispatch(list, tail, last_time)
	_render_dispatch(list, tail, last_time)
	_rd.compute_list_end()
	_rd.capture_timestamp("颜色大战_结束")
	_last_submit_cpu_ms = float(Time.get_ticks_usec() - submit_started) / 1000.0
	if request_stats:
		_schedule_stats_read(generation_id)

func _dispatch(list: int, mode: int, elements: int, color: int, tail: int, dt: float, sim_time: float, flags: int = 0) -> void:
	var push := PackedByteArray()
	push.resize(32)
	push.encode_u32(0, mode)
	push.encode_u32(4, color)
	push.encode_u32(8, tail)
	push.encode_u32(12, flags | (2 if bool(_rt_settings.get("gpu_profiling", false)) else 0))
	push.encode_float(16, dt)
	push.encode_float(20, sim_time)
	_rd.compute_list_set_push_constant(list, push, push.size())
	if mode == 2 or mode == 4 or mode == 9:
		_rd.compute_list_dispatch_indirect(list, _buffers[11], 0 if mode == 4 else 12)
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

func _schedule_stats_read(generation_id: int) -> void:
	_last_blocking_readback_ms = 0.0
	var combined := {"generation":generation_id, "parts":{}, "debug":false, "expected":4, "read_started_us":Time.get_ticks_usec()}
	_read_buffer(_buffers[6], "metrics", combined, 0, METRICS_WORDS * 4)
	_read_buffer(_buffers[1], "teams", combined, 0, 4 * TEAM_STRIDE)
	_read_buffer(_buffers[0], "balls", combined, int(_rt_settings.particle_capacity) * PARTICLE_STRIDE, BIG_CAPACITY * PARTICLE_STRIDE)
	_read_buffer(_buffers[11], "diagnostics", combined, 0, DIAGNOSTIC_WORDS * 4)

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
		_last_blocking_readback_ms += float(Time.get_ticks_usec() - started) / 1000.0
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
		if combined.has("read_error"):
			call_deferred("_failed_main", int(combined.generation), str(combined.read_error))
			return
		combined["readback_latency_ms"] = float(Time.get_ticks_usec() - int(combined.get("read_started_us", Time.get_ticks_usec()))) / 1000.0
		if bool(combined.debug):
			call_deferred("_debug_snapshot_main", combined)
		else:
			_update_timestamp()
			call_deferred("_stats_main", combined, _last_gpu_ms)

func _update_timestamp() -> void:
	var first := -1
	var last := -1
	for index: int in _rd.get_captured_timestamps_count():
		var label := _rd.get_captured_timestamp_name(index)
		if label == "颜色大战_开始":
			first = _rd.get_captured_timestamp_gpu_time(index)
		elif label == "颜色大战_结束":
			last = _rd.get_captured_timestamp_gpu_time(index)
	if first >= 0 and last >= first:
		# Vulkan驱动timestamp_query_result_to_time返回纳秒（timestampPeriod），
		# Godot4.6 XML文档误写微秒；以实际引擎实现为准。
		_last_gpu_ms = float(last - first) / 1000000.0

func _decode_energy(bytes: PackedByteArray, offset: int) -> int:
	return int(bytes.decode_u32(offset)) | (int(bytes.decode_u32(offset + 4)) << 32)

func _decode_team(bytes: PackedByteArray, index: int, sim_time: float) -> Dictionary:
	var offset := index * TEAM_STRIDE
	var state := int(bytes.decode_u32(offset + 32))
	return {"team":index, "shield":_decode_energy(bytes, offset), "gun":_decode_energy(bytes, offset + 8), "storm":_decode_energy(bytes, offset + 16), "sniper":_decode_energy(bytes, offset + 24), "state":state, "alive":state != 2, "pending":state == 1, "request_nonce":int(bytes.decode_u32(offset + 36)), "death_nonce":int(bytes.decode_u32(offset + 40)), "rescue_cd":maxf(0.0, bytes.decode_float(offset + 48) - sim_time), "ready_time":bytes.decode_float(offset + 48), "gun_phase":bytes.decode_float(offset + 52), "gun_angle":bytes.decode_float(offset + 56), "gun_target_angle":bytes.decode_float(offset + 116), "gun_mode":bytes.decode_float(offset + 120), "x":bytes.decode_float(offset + 80), "y":bytes.decode_float(offset + 84), "core_radius":bytes.decode_float(offset + 88), "shield_radius":bytes.decode_float(offset + 92)}

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
	return {"profiling_enabled":bool(settings.get("gpu_profiling", false)), "collision_candidates":int(bytes.decode_u32(32)), "actual_contacts":int(bytes.decode_u32(36)), "pool_live_ids":int(bytes.decode_u32(40)), "pool_normal_free":int(bytes.decode_u32(44)), "pool_sniper_free":int(bytes.decode_u32(48)), "normal_dispatch_groups":int(bytes.decode_u32(0)), "motion_dispatch_groups":int(bytes.decode_u32(12)), "gpu_allocation_bytes":_memory_bytes, "active_by_team":active_by_team}

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
	stats["substeps_in_last_batch"] = _last_substep_count
	stats["cpu_submit_ms"] = _last_submit_cpu_ms
	# Async completion includes queueing/frame scheduling, not a blocking CPU
	# wait. Keep its name explicit so benchmarks do not call it GPU sync time.
	stats["async_readback_latency_ms"] = _last_readback_latency_ms
	stats["blocking_readback"] = not _rd.has_method("buffer_get_data_async")
	stats["explicit_cpu_gpu_sync_wait_ms"] = _last_blocking_readback_ms
	stats_updated.emit(stats)
	if int(metrics.decode_u32(60)) != 0:
		_failed_main(_generation, "GPU 能量累加超出当前受支持整数上限（2^63−1）。已停止模拟并保留待发命令；请降低数值增长或重新开局。")
		return
	for index: int in 4:
		if bool(teams[index].pending) and int(_rescue_notified[index]) != int(teams[index].request_nonce):
			_rescue_notified[index] = int(teams[index].request_nonce)
			rescue_requested.emit(index)
		if not bool(teams[index].alive) and not bool(_death_notified[index]):
			_death_notified[index] = true
			team_eliminated.emit(index)

func _debug_read_rd(generation_id: int, kind: String, sequence: int) -> void:
	if generation_id != _generation or _rd == null or _buffers.is_empty():
		return
	_last_blocking_readback_ms = 0.0
	# 独立测试要求即时精确总数，不能误取上次0.25秒遥测快照；正式路径不走此入口。
	var list := _rd.compute_list_begin()
	_rd.compute_list_bind_compute_pipeline(list, _pipeline)
	_rd.compute_list_bind_uniform_set(list, _uniform_set, 0)
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
