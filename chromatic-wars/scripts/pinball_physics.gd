class_name PinballPhysics
extends Node2D

signal weapon_output(team: int, kind: int, energy: float)
signal trigger_log(data: Dictionary)
signal simulation_fault(message: String)

const ChannelsModule = preload("res://scripts/multiplier_channels.gd")
const AirModule = preload("res://scripts/air_curtain.gd")
const ConveyorModule = preload("res://scripts/weapon_conveyor.gd")
const TEAM_COLORS: Array[Color] = [Color("ff6476"), Color("65e8aa"), Color("63a5ff"), Color("f4d369")]
const BOUNDS: Rect2 = Rect2(16.0, 59.0, 448.0, 722.0)
const WIDTH: float = 480.0
const HEIGHT: float = 850.0
const MAX_EXACT_ENERGY: float = 9007199254740991.0

var channels = ChannelsModule.new()
var air = AirModule.new()
var conveyor = ConveyorModule.new()
var rng: RandomNumberGenerator = RandomNumberGenerator.new()
var balls: Array[Dictionary] = []
var pegs: Array[Vector3] = []
var custom_pegs: Array[Vector3] = []
var disabled_preset_pegs: Array[int] = []
var static_revision: int = 0
# Trajectories stay outside ball snapshots; one small history per CPU ball.
var motion_history: Dictionary = {}
var unstuck_events: int = 0
# All motion-watch durations below use 模拟秒, independent of wall-clock speed.
const MOTION_SAMPLE_PERIOD: float = 0.1
const STILL_WINDOW: float = 3.0
const LOOP_WINDOW: float = 8.0
const STUCK_CONFIRM_TIME: float = 0.4
var simulation_time: float = 0.0
var gravity: float = 820.0
var restitution: float = 1.0
var friction: float = 0.0
var radius_min: float = 4.2
var radius_max: float = 36.0
var radius_gain: float = 3.0
var threshold_start: float = 100.0
var threshold_target: float = 1000000.0
var threshold_duration: float = 1200.0
var generated: Array[float] = [0.0, 0.0, 0.0, 0.0]
var multiplier_events: int = 0
var output_events: int = 0
var contact_events: int = 0
var font: Font
var debug: bool = false
var last_event: Dictionary = {}
var active_seed: int = 1
var error: String = ""

func _ready() -> void:
	if font == null:
		font = ThemeDB.fallback_font
	if pegs.is_empty():
		_build_pegs()
	if balls.is_empty():
		reset(active_seed)
	queue_redraw()

func configure(settings: Dictionary) -> void:
	gravity = clampf(float(settings.get("gravity", gravity)), 20.0, 2000.0)
	restitution = clampf(float(settings.get("restitution", settings.get("elasticity", restitution))), 0.05, 1.0)
	friction = clampf(float(settings.get("friction", friction)), 0.0, 1.0)
	radius_min = clampf(float(settings.get("radius_min", radius_min)), 4.0, 12.0)
	# 默认最大直径72大于×2净宽67，小于中央98；成长足够后实体口自然拒绝。
	radius_max = clampf(float(settings.get("radius_max", radius_max)), radius_min, 40.0)
	radius_gain = maxf(0.01, float(settings.get("radius_gain", settings.get("radius_k", radius_gain))))
	threshold_start = maxf(2.0, float(settings.get("threshold_start", threshold_start)))
	threshold_target = maxf(threshold_start, float(settings.get("threshold_target", settings.get("growth_target", threshold_target))))
	threshold_duration = maxf(1.0, float(settings.get("threshold_duration", settings.get("growth_duration", threshold_duration))))
	debug = bool(settings.get("debug", debug))
	if settings.get("font") is Font:
		font = settings["font"]
	air.configure(settings)
	conveyor.configure(settings)
	channels.configure(settings)
	static_revision += 1
	if settings.has("disabled_preset_pegs") and settings["disabled_preset_pegs"] is Array:
		disabled_preset_pegs.clear()
		for saved_id in settings["disabled_preset_pegs"]:
			var preset_id: int = int(saved_id)
			if preset_id >= 0 and preset_id < 15 and not disabled_preset_pegs.has(preset_id):
				disabled_preset_pegs.append(preset_id)
		_build_pegs()
	if settings.has("custom_pegs") and settings["custom_pegs"] is Array:
		var saved_pegs: Array = settings["custom_pegs"].duplicate()
		custom_pegs.clear()
		_build_pegs()
		for saved_peg in saved_pegs:
			var peg: Vector3 = Vector3.ZERO
			if saved_peg is Vector3:
				peg = saved_peg
			elif saved_peg is Array and saved_peg.size() >= 3:
				peg = Vector3(float(saved_peg[0]), float(saved_peg[1]), float(saved_peg[2]))
			elif saved_peg is Dictionary:
				peg = Vector3(float(saved_peg.get("x", 0.0)), float(saved_peg.get("y", 0.0)), float(saved_peg.get("r", 6.0)))
			else:
				continue
			add_custom_peg(Vector2(peg.x, peg.y), peg.z)
	for ball in balls:
		_update_radius(ball)
	queue_redraw()

func threshold_at(time: float) -> float:
	# The configured target is a point on a continuous line, not a final cap.
	return threshold_start + (threshold_target - threshold_start) * maxf(0.0, time) / threshold_duration

func _preset_pegs() -> Array[Vector3]:
	var defaults: Array[Vector3] = []
	for column in range(3):
		defaults.append(Vector3(110.0 + float(column) * 130.0, 194.0, 5.4))
	for row in range(3):
		for column in range(4):
			defaults.append(Vector3(66.0 + float(column) * 108.0 + float(row % 2) * 32.0, 523.0 + float(row) * 100.0, 6.0))
	return defaults

func _build_pegs() -> void:
	static_revision += 1
	pegs.clear()
	var defaults: Array[Vector3] = _preset_pegs()
	for index in range(defaults.size()):
		if not disabled_preset_pegs.has(index):
			pegs.append(defaults[index])
	pegs.append_array(custom_pegs)

func remove_peg(local_position: Vector2) -> bool:
	var nearest: float = INF
	var selected_custom: int = -1
	var selected_preset: int = -1
	for index in range(custom_pegs.size()):
		var peg: Vector3 = custom_pegs[index]
		var distance: float = local_position.distance_to(Vector2(peg.x, peg.y))
		if distance <= peg.z + 12.0 and distance < nearest:
			nearest = distance
			selected_custom = index
	var defaults: Array[Vector3] = _preset_pegs()
	for index in range(defaults.size()):
		if disabled_preset_pegs.has(index):
			continue
		var peg: Vector3 = defaults[index]
		var distance: float = local_position.distance_to(Vector2(peg.x, peg.y))
		if distance <= peg.z + 12.0 and distance < nearest:
			nearest = distance
			selected_preset = index
			selected_custom = -1
	if selected_custom >= 0:
		custom_pegs.remove_at(selected_custom)
	elif selected_preset >= 0:
		disabled_preset_pegs.append(selected_preset)
	else:
		return false
	_build_pegs()
	queue_redraw()
	return true

func restore_preset_pegs() -> void:
	# Preserve custom layouts: do not restore a preset inside a custom column.
	var defaults: Array[Vector3] = _preset_pegs()
	disabled_preset_pegs.clear()
	for index in range(defaults.size()):
		var preset: Vector3 = defaults[index]
		for custom in custom_pegs:
			if Vector2(preset.x, preset.y).distance_squared_to(Vector2(custom.x, custom.y)) < pow(preset.z + custom.z + 2.0, 2.0):
				disabled_preset_pegs.append(index)
				break
	_build_pegs()
	queue_redraw()

func clear_all_pegs() -> void:
	custom_pegs.clear()
	disabled_preset_pegs.clear()
	for index in range(_preset_pegs().size()):
		disabled_preset_pegs.append(index)
	_build_pegs()
	queue_redraw()

func can_place_custom_peg(local_position: Vector2, radius: float) -> bool:
	if custom_pegs.size() >= 64 or not is_finite(radius) or not is_finite(local_position.x) or not is_finite(local_position.y):
		return false
	var peg_radius: float = clampf(radius, 3.0, 24.0)
	# 留出顶部出生区与底部输送带，其他空白位置均可编辑。
	if local_position.x - peg_radius < BOUNDS.position.x or local_position.x + peg_radius > BOUNDS.end.x \
		or local_position.y - peg_radius < 130.0 or local_position.y + peg_radius > 750.0:
		return false
	if pegs.is_empty():
		_build_pegs()
	for existing in pegs:
		if local_position.distance_squared_to(Vector2(existing.x, existing.y)) < pow(peg_radius + existing.z + 2.0, 2.0):
			return false
	for polygon in channels.polygons + channels.bottom_walls:
		if Geometry2D.is_point_in_polygon(local_position, polygon):
			return false
		for index in range(polygon.size()):
			var nearest := Geometry2D.get_closest_point_to_segment(local_position, polygon[index], polygon[(index + 1) % polygon.size()])
			if local_position.distance_squared_to(nearest) < pow(peg_radius + 2.0, 2.0):
				return false
	return true

func add_custom_peg(local_position: Vector2, radius: float) -> bool:
	if not can_place_custom_peg(local_position, radius):
		return false
	var peg_radius: float = clampf(radius, 3.0, 24.0)
	var peg: Vector3 = Vector3(local_position.x, local_position.y, peg_radius)
	custom_pegs.append(peg)
	pegs.append(peg)
	static_revision += 1
	queue_redraw()
	return true

func remove_custom_peg(local_position: Vector2) -> bool:
	var selected: int = -1
	var nearest: float = INF
	for index in range(custom_pegs.size()):
		var peg: Vector3 = custom_pegs[index]
		var distance: float = local_position.distance_to(Vector2(peg.x, peg.y))
		if distance <= peg.z + 12.0 and distance < nearest:
			selected = index
			nearest = distance
	if selected < 0:
		return false
	custom_pegs.remove_at(selected)
	_build_pegs()
	queue_redraw()
	return true

func reset(seed: int) -> void:
	active_seed = seed
	rng.seed = seed
	simulation_time = 0.0
	generated = [0.0, 0.0, 0.0, 0.0]
	multiplier_events = 0
	output_events = 0
	contact_events = 0
	unstuck_events = 0
	motion_history.clear()
	last_event.clear()
	error = ""
	channels.reset()
	conveyor.reset()
	balls.clear()
	_build_pegs()
	for team in range(4):
		for member in range(4):
			var ball: Dictionary = {"id": team * 4 + member, "team": team, "value": 2.0, "threshold": threshold_at(0.0), "t_birth": threshold_at(0.0), "birth_time": 0.0, "p": Vector2.ZERO, "v": Vector2.ZERO, "r": radius_min, "mass": radius_min * radius_min, "loops": 0, "outputs": 0, "unstuck_count": 0}
			_launch(ball, true)
			balls.append(ball)
	queue_redraw()

func _update_radius(ball: Dictionary) -> void:
	ball["r"] = radius_for(float(ball["value"]), float(ball["threshold"]))
	var area: float = float(ball["r"]) * float(ball["r"])
	var base_area: float = radius_min * radius_min
	var size_factor: float = clampf((area - base_area) / maxf(1.0, radius_max * radius_max - base_area), 0.0, 1.0)
	# Exact ammunition stays separate from bounded mechanical quantities.
	var growth_ratio: float = maxf(0.0, float(ball["value"])) / maxf(1.0, float(ball["threshold"]))
	var growth_log: float = log(1.0 + maxf(growth_ratio - 1.0, 0.0))
	var ammo_log: float = log(1.0 + maxf(0.0, float(ball["value"])) / maxf(100.0, threshold_start))
	# Birth-locked growth governs mechanical weight. Absolute ammunition only
	# adds a small bounded contribution, so a late-born, still-small ball does
	# not become too heavy for the air curtain before it has actually grown.
	var ammo_factor: float = 0.9 * growth_log / (6.0 + growth_log) + 0.1 * ammo_log / (6.0 + ammo_log)
	ball["size_factor"] = size_factor
	ball["ammo_factor"] = ammo_factor
	ball["growth_ratio"] = growth_ratio
	ball["mass"] = base_area * (1.0 + 24.0 * size_factor + 8.0 * ammo_factor)
	ball["bounce"] = maxf(0.03, restitution * clampf(0.96 - 0.42 * size_factor - 0.16 * ammo_factor, 0.34, 0.96))

func radius_for(ammo: float, birth_threshold: float) -> float:
	var normalized: float = maxf(0.0, ammo / maxf(1.0, birth_threshold) - 1.0)
	return clampf(radius_min + radius_gain * sqrt(normalized), radius_min, radius_max)

func _launch(ball: Dictionary, fresh: bool) -> bool:
	if fresh:
		ball["value"] = 2.0
		ball["threshold"] = threshold_at(simulation_time)
		ball["t_birth"] = ball["threshold"]
		ball["birth_time"] = simulation_time
	_update_radius(ball)
	var radius: float = float(ball["r"])
	var candidate: Vector2 = Vector2.ZERO
	var best_clearance: float = -INF
	# Only spawn coordinates and initial velocity are randomized; actual
	# collisions still determine every multiplier and weapon destination.
	for attempt in range(64):
		var point: Vector2 = Vector2(rng.randf_range(25.0 + radius, 455.0 - radius), rng.randf_range(maxf(83.0, BOUNDS.position.y + radius + 2.0), 110.0))
		if _spawn_static_clearance(point, radius) < 0.01:
			continue
		var clearance: float = _spawn_ball_clearance(point, radius, int(ball["id"]))
		if clearance > best_clearance:
			best_clearance = clearance
			candidate = point
		if clearance > 2.0:
			break
	# An edited column layout can leave only a narrow safe part of the top
	# strip. Check a deterministic grid before deciding it is obstructed.
	if best_clearance == -INF:
		var top_y: float = BOUNDS.position.y + radius + 0.1
		var left_x: float = BOUNDS.position.x + radius + 0.1
		var right_x: float = BOUNDS.end.x - radius - 0.1
		for row in range(7):
			var y: float = lerpf(top_y, maxf(top_y, 110.0), float(row) / 6.0)
			for column in range(180):
				var point: Vector2 = Vector2(lerpf(left_x, right_x, float(column) / 179.0), y)
				if _spawn_static_clearance(point, radius) < 0.01:
					continue
				var clearance: float = _spawn_ball_clearance(point, radius, int(ball["id"]))
				if clearance > best_clearance:
					best_clearance = clearance
					candidate = point
				if clearance > 2.0:
					break
			if best_clearance > 2.0:
				break
	if best_clearance == -INF:
		# Never create a ball inside user geometry. A queued ball is absent
		# from physics and event triggers until a checked spawn becomes free.
		ball["waiting_spawn"] = true
		ball["spawn_retry_time"] = simulation_time + 0.25
		ball["spawn_block_revision"] = static_revision
		ball["v"] = Vector2.ZERO
		motion_history.erase(int(ball["id"]))
		return false
	ball["waiting_spawn"] = false
	ball["p"] = candidate
	ball["step_origin"] = candidate
	ball["v"] = Vector2(rng.randf_range(-205.0, 205.0), rng.randf_range(-410.0, -255.0))
	_reset_motion_watch(ball)
	return true

func _spawn_ball_clearance(point: Vector2, radius: float, ball_id: int) -> float:
	var clearance: float = INF
	for other in balls:
		if int(other["id"]) == ball_id or bool(other.get("waiting_spawn", false)):
			continue
		clearance = minf(clearance, point.distance_to(other["p"]) - float(other["r"]) - radius)
	return clearance

func _spawn_static_clearance(point: Vector2, radius: float) -> float:
	var clearance: float = minf(point.x - BOUNDS.position.x - radius, BOUNDS.end.x - point.x - radius)
	clearance = minf(clearance, point.y - BOUNDS.position.y - radius)
	for peg in pegs:
		clearance = minf(clearance, point.distance_to(Vector2(peg.x, peg.y)) - radius - peg.z)
	for polygon in channels.polygons + channels.bottom_walls:
		var edge_distance: float = INF
		for index in range(polygon.size()):
			var closest: Vector2 = Geometry2D.get_closest_point_to_segment(point, polygon[index], polygon[(index + 1) % polygon.size()])
			edge_distance = minf(edge_distance, point.distance_to(closest))
		if Geometry2D.is_point_in_polygon(point, polygon):
			edge_distance = -edge_distance
		clearance = minf(clearance, edge_distance - radius)
	return clearance

func _reset_motion_watch(ball: Dictionary) -> void:
	var point: Vector2 = ball["p"]
	motion_history[int(ball["id"])] = {
		"samples": [PackedFloat64Array([point.x, point.y, simulation_time, 0.0])],
		"next_sample": simulation_time + MOTION_SAMPLE_PERIOD,
		"path": 0.0, "last_position": point, "suspect_since": -1.0,
		"cooldown_until": simulation_time + 1.0, # 模拟秒
	}

func _watch_motion(ball: Dictionary) -> void:
	var ball_id: int = int(ball["id"])
	if not motion_history.has(ball_id):
		_reset_motion_watch(ball)
		return
	var watch: Dictionary = motion_history[ball_id]
	var position: Vector2 = ball["p"]
	# Accumulate every physical substep, not just sampled displacement: a
	# rapidly bouncing ball must not look stationary due to sampling alias.
	watch["path"] = float(watch["path"]) + position.distance_to(Vector2(watch["last_position"]))
	watch["last_position"] = position
	if simulation_time < float(watch["next_sample"]):
		return
	watch["next_sample"] = simulation_time + MOTION_SAMPLE_PERIOD
	var samples: Array = watch["samples"]
	samples.append(PackedFloat64Array([position.x, position.y, simulation_time, float(watch["path"])]))
	while samples.size() > 1 and float(samples[1][2]) < simulation_time - LOOP_WINDOW:
		samples.pop_front()
	if simulation_time < float(watch["cooldown_until"]):
		return
	var radius: float = float(ball["r"])
	var short_start: PackedFloat64Array = samples[samples.size() - 1]
	var short_min: Vector2 = position
	var short_max: Vector2 = position
	var full_min: Vector2 = position
	var full_max: Vector2 = position
	var early_depth: float = -INF
	var late_depth: float = -INF
	for sample in samples:
		var point: Vector2 = Vector2(float(sample[0]), float(sample[1]))
		full_min = full_min.min(point)
		full_max = full_max.max(point)
		if float(sample[2]) >= simulation_time - STILL_WINDOW:
			if float(sample[2]) < float(short_start[2]):
				short_start = sample
			short_min = short_min.min(point)
			short_max = short_max.max(point)
			late_depth = maxf(late_depth, point.y)
		elif float(sample[2]) <= simulation_time - LOOP_WINDOW + STILL_WINDOW:
			early_depth = maxf(early_depth, point.y)
	var short_extent: Vector2 = short_max - short_min
	var short_path: float = float(watch["path"]) - float(short_start[3])
	var still: bool = (
		simulation_time - float(short_start[2]) >= STILL_WINDOW - MOTION_SAMPLE_PERIOD * 1.1
		and short_path <= maxf(12.0, radius * 0.9)
		and short_extent.length() <= maxf(8.0, radius * 0.6)
	)
	var first_sample: PackedFloat64Array = samples[0]
	var full_extent: Vector2 = full_max - full_min
	var full_path: float = float(watch["path"]) - float(first_sample[3])
	# A long path alone does not prove progress: a bounded repeated orbit can
	# accumulate distance indefinitely. Require a full residence window and
	# no improvement in deepest position before treating it as a local loop.
	var local_region: bool = full_extent.x <= maxf(96.0, radius * 3.5) and full_extent.y <= maxf(96.0, radius * 3.5)
	var upper_lane: bool = full_max.y <= channels.END_Y + radius and full_extent.y <= maxf(72.0, radius * 2.8)
	var looping: bool = (
		simulation_time - float(first_sample[2]) >= LOOP_WINDOW - MOTION_SAMPLE_PERIOD * 1.1
		and (local_region or upper_lane)
		and full_path >= maxf(180.0, radius * 12.0)
		and late_depth <= early_depth + maxf(12.0, radius * 0.4)
		and full_max.y < conveyor.OUTPUT_Y - 80.0
	)
	if not still and not looping:
		watch["suspect_since"] = -1.0
		return
	if float(watch["suspect_since"]) < 0.0:
		watch["suspect_since"] = simulation_time
		return
	if simulation_time - float(watch["suspect_since"]) < STUCK_CONFIRM_TIME:
		return
	# This is a relocation, never a weapon output or multiplier event.
	# _launch(false) preserves team, exact value, threshold and birth times.
	ball["unstuck_count"] = int(ball.get("unstuck_count", 0)) + 1
	unstuck_events += 1
	_launch(ball, false)
	trigger_log.emit({"type": "unstuck", "team": ball["team"], "ball_id": ball_id, "energy": ball["value"], "time": simulation_time, "reason": "local_loop" if looping else "still"})

func step(dt: float, sim_time: float) -> void:
	if dt <= 0.0 or not error.is_empty():
		return
	# 主控固定时间步；这里再按最小半径的扫掠距离细分，防止高速穿过细墙。
	# 不根据帧率或时间倍率改变物理 dt，速度按钮只改变主控执行的固定步数。
	var start_time: float = sim_time - dt
	var maximum_speed: float = 500.0
	for ball in balls:
		maximum_speed = maxf(maximum_speed, Vector2(ball["v"]).length())
	var safe_dt: float = minf(1.0 / 240.0, radius_min * 0.45 / maxf(1.0, maximum_speed))
	var substeps: int = maxi(1, int(ceil(dt / safe_dt)))
	var h: float = dt / float(substeps)
	for substep in range(substeps):
		simulation_time = start_time + float(substep + 1) * h
		conveyor.step(h)
		for ball in balls:
			if bool(ball.get("waiting_spawn", false)):
				# A statically blocked strip cannot clear until geometry or ball
				# settings change; avoid repeating the expensive fallback scan.
				if simulation_time >= float(ball.get("spawn_retry_time", 0.0)) and int(ball.get("spawn_block_revision", -1)) != static_revision:
					_launch(ball, false)
				if bool(ball.get("waiting_spawn", false)):
					continue
			var velocity: Vector2 = ball["v"]
			var position: Vector2 = ball["p"]
			ball["step_origin"] = position
			velocity += (Vector2(0.0, gravity) + air.acceleration(position, float(ball["r"]), float(ball["mass"]), float(ball["ammo_factor"]), velocity, float(ball["growth_ratio"]), h)) * h
			ball["v"] = velocity
			ball["p"] = position + velocity * h
		# 两轮序贯冲量/位置投影，同时处理球-球、球-墙和球-静态实体。
		for iteration in range(2):
			for ball in balls:
				if not bool(ball.get("waiting_spawn", false)):
					_static_contacts(ball)
			_ball_contacts()
			# 球球位置投影也必须受新底墙约束，不能把小球挤到墙的另一侧。
			for ball in balls:
				if not bool(ball.get("waiting_spawn", false)):
					_bottom_wall_contacts(ball)
		for ball in balls:
			if bool(ball.get("waiting_spawn", false)):
				continue
			var position: Vector2 = ball["p"]
			var channel: int = channels.capture(position, float(ball["r"]))
			if channel >= 0:
				var previous_value: float = ball["value"]
				var next_value: float = previous_value * float(channels.MULTIPLIERS[channel])
				if next_value > MAX_EXACT_ENERGY:
					error = "弹药球%d的×%d结果超过CPU命令精确整数上限2^53−1。已保留原值并暂停，请降低倍率累积或重开。" % [int(ball["id"]), int(channels.MULTIPLIERS[channel])]
					simulation_fault.emit(error)
					return
				channels.register(channel)
				ball["value"] = next_value
				ball["loops"] = int(ball["loops"]) + 1
				multiplier_events += 1
				last_event = {"type": "multiplier", "ball_id": ball["id"], "team": ball["team"], "channel": channel, "multiplier": channels.MULTIPLIERS[channel], "before": previous_value, "after": ball["value"], "x": position.x, "time": simulation_time, "radius": ball["r"], "threshold": ball["threshold"]}
				trigger_log.emit(last_event.duplicate())
				_launch(ball, false)
			elif position.y + float(ball["r"]) >= conveyor.OUTPUT_Y:
				var energy: float = ball["value"]
				var team: int = ball["team"]
				last_event = conveyor.register(position.x, int(ball["id"]), team, energy)
				last_event["type"] = "output"
				last_event["time"] = simulation_time
				generated[team] += energy
				output_events += 1
				ball["outputs"] = int(ball["outputs"]) + 1
				trigger_log.emit(last_event.duplicate())
				# 同步输出前先重生，接收者可安全调用 rescue/eliminate。
				_launch(ball, true)
				weapon_output.emit(team, int(last_event["kind"]), energy)
			else:
				_watch_motion(ball)
	simulation_time = sim_time
	queue_redraw()

func _reflect(ball: Dictionary, normal: Vector2) -> void:
	var velocity: Vector2 = ball["v"]
	var normal_speed: float = velocity.dot(normal)
	if normal_speed < 0.0:
		var tangent: Vector2 = velocity - normal * normal_speed
		ball["v"] = tangent * (1.0 - friction) - normal * normal_speed * float(ball["bounce"])
		contact_events += 1

func _static_contacts(ball: Dictionary) -> void:
	var position: Vector2 = ball["p"]
	var radius: float = ball["r"]
	if position.x - radius < BOUNDS.position.x:
		position.x = BOUNDS.position.x + radius
		_reflect(ball, Vector2.RIGHT)
	if position.x + radius > BOUNDS.end.x:
		position.x = BOUNDS.end.x - radius
		_reflect(ball, Vector2.LEFT)
	if position.y - radius < BOUNDS.position.y:
		position.y = BOUNDS.position.y + radius
		_reflect(ball, Vector2.DOWN)
	ball["p"] = position
	for polygon in channels.polygons:
		var left_edge: float = polygon[0].x
		if position.y + radius > channels.MOUTH_Y - 15.0 and position.y - radius < channels.END_Y and absf(position.x - (left_edge + 4.0)) < radius + 4.1:
			_polygon_contact(ball, polygon)
	_bottom_wall_contacts(ball)
	for peg in pegs:
		position = ball["p"]
		var center: Vector2 = Vector2(peg.x, peg.y)
		var separation: Vector2 = position - center
		var combined_radius: float = radius + peg.z
		if separation.length_squared() >= combined_radius * combined_radius:
			continue
		var distance: float = separation.length()
		var normal: Vector2 = separation / distance if distance > 0.000001 else Vector2.UP
		ball["p"] = center + normal * (combined_radius + 0.002)
		_reflect(ball, normal)

func _bottom_wall_contacts(ball: Dictionary) -> void:
	var radius: float = ball["r"]
	var origin: Vector2 = ball.get("step_origin", ball["p"])
	for polygon in channels.bottom_walls:
		var position: Vector2 = ball["p"]
		var bounds: Rect2 = Rect2(polygon[0], polygon[2] - polygon[0])
		# 保留本子步开始时所在的一侧，防止挤压越过墙中线后被向上解嵌。
		if origin.y - radius >= bounds.end.y - 0.01 and position.y - radius < bounds.end.y \
			and position.x + radius > bounds.position.x and position.x - radius < bounds.end.x:
			ball["p"] = Vector2(position.x, bounds.end.y + radius + 0.002)
			_reflect(ball, Vector2.DOWN)
		elif bounds.grow(radius).has_point(position):
			_polygon_contact(ball, polygon)

func _polygon_contact(ball: Dictionary, polygon: PackedVector2Array) -> void:
	var position: Vector2 = ball["p"]
	var closest: Vector2 = Vector2.ZERO
	var distance_squared: float = INF
	for index in range(polygon.size()):
		var from: Vector2 = polygon[index]
		var to: Vector2 = polygon[(index + 1) % polygon.size()]
		var nearest: Vector2 = Geometry2D.get_closest_point_to_segment(position, from, to)
		var candidate_distance: float = position.distance_squared_to(nearest)
		if candidate_distance < distance_squared:
			distance_squared = candidate_distance
			closest = nearest
	var inside: bool = Geometry2D.is_point_in_polygon(position, polygon)
	var radius: float = ball["r"]
	if not inside and distance_squared >= radius * radius:
		return
	var direction: Vector2 = position - closest
	var normal: Vector2 = direction.normalized() if direction.length_squared() > 0.000001 else Vector2.UP
	if inside:
		normal = -normal
	ball["p"] = closest + normal * (radius + 0.002)
	_reflect(ball, normal)

func _ball_contacts() -> void:
	# 仅左侧16颗刚体使用 O(16²) CPU；右侧 GPU 粒子不经过此模块。
	for first in range(balls.size()):
		for second in range(first + 1, balls.size()):
			var a: Dictionary = balls[first]
			var b: Dictionary = balls[second]
			if bool(a.get("waiting_spawn", false)) or bool(b.get("waiting_spawn", false)):
				continue
			var delta: Vector2 = Vector2(b["p"]) - Vector2(a["p"])
			var combined_radius: float = float(a["r"]) + float(b["r"])
			if delta.length_squared() >= combined_radius * combined_radius:
				continue
			var distance: float = delta.length()
			var normal: Vector2 = delta / distance if distance > 0.000001 else Vector2.RIGHT
			var inverse_a: float = 1.0 / float(a["mass"])
			var inverse_b: float = 1.0 / float(b["mass"])
			var inverse_sum: float = inverse_a + inverse_b
			var penetration: float = combined_radius - distance + 0.002
			a["p"] = Vector2(a["p"]) - normal * penetration * inverse_a / inverse_sum
			b["p"] = Vector2(b["p"]) + normal * penetration * inverse_b / inverse_sum
			var normal_speed: float = (Vector2(b["v"]) - Vector2(a["v"])).dot(normal)
			if normal_speed < 0.0:
				var pair_bounce: float = sqrt(float(a["bounce"]) * float(b["bounce"]))
				var impulse: float = -(1.0 + pair_bounce) * normal_speed / inverse_sum
				a["v"] = Vector2(a["v"]) - normal * impulse * inverse_a
				b["v"] = Vector2(b["v"]) + normal * impulse * inverse_b
				contact_events += 1

func rescue(team: int) -> float:
	var selected: Dictionary = {}
	for ball in balls:
		if int(ball["team"]) == team and (selected.is_empty() or float(ball["value"]) > float(selected["value"])):
			selected = ball
	if selected.is_empty():
		return 0.0
	var energy: float = selected["value"]
	_launch(selected, true)
	trigger_log.emit({"type": "rescue", "team": team, "energy": energy, "ball_id": selected["id"], "time": simulation_time})
	queue_redraw()
	return energy

func eliminate(team: int) -> Array[float]:
	var energies: Array[float] = []
	for index in range(balls.size() - 1, -1, -1):
		if int(balls[index]["team"]) == team:
			energies.append(float(balls[index]["value"]))
			motion_history.erase(int(balls[index]["id"]))
			balls.remove_at(index)
	queue_redraw()
	return energies

func snapshot() -> Dictionary:
	var copy: Array[Dictionary] = balls.duplicate(true)
	var waiting_spawns: int = 0
	for ball in copy:
		if bool(ball.get("waiting_spawn", false)):
			waiting_spawns += 1
		ball["radius"] = ball["r"]
		ball["birth_threshold"] = ball["threshold"]
	return {"time": simulation_time, "seed": active_seed, "error": error, "active_balls": balls.size(), "waiting_spawns": waiting_spawns, "balls": copy, "threshold": threshold_at(simulation_time), "generated": generated.duplicate(), "multiplier_events": multiplier_events, "output_events": output_events, "contact_events": contact_events, "unstuck_events": unstuck_events, "channels": channels.snapshot(), "air": air.snapshot(), "conveyor": conveyor.snapshot(), "last_event": last_event.duplicate()}

func _number(value: float) -> String:
	if value >= 100000000.0:
		return "%.2f亿" % (value / 100000000.0)
	if value >= 10000.0:
		return "%.1f万" % (value / 10000.0)
	return str(int(value))

func _draw() -> void:
	if font == null:
		font = ThemeDB.fallback_font
	draw_rect(Rect2(0.0, 0.0, WIDTH, HEIGHT), Color("101a2a"))
	draw_rect(Rect2(0.0, 0.0, WIDTH, HEIGHT), Color("2b425b"), false, 1.5)
	draw_string(font, Vector2(18.0, 27.0), "弹药增幅机", HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color("e0ecfa"))
	draw_string(font, Vector2(18.0, 47.0), "%d球真实碰撞 · 出生门槛 %s" % [balls.size(), _number(threshold_at(simulation_time))], HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("819db8"))
	draw_line(Vector2(16.0, 59.0), Vector2(464.0, 59.0), Color("7895ac"), 3.0)
	draw_line(Vector2(16.0, 59.0), Vector2(16.0, 781.0), Color("7895ac"), 3.0)
	draw_line(Vector2(464.0, 59.0), Vector2(464.0, 781.0), Color("7895ac"), 3.0)
	air.draw_on(self, simulation_time)
	channels.draw_on(self, font)
	draw_string(font, Vector2(210.0, 429.0), "空气墙", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("6ab6d8"))
	for peg in pegs:
		var center: Vector2 = Vector2(peg.x, peg.y)
		draw_circle(center, peg.z + 3.0, Color(0.19, 0.46, 0.64, 0.15))
		draw_circle(center, peg.z, Color("758ba3"))
		draw_circle(center + Vector2(-1.5, -1.7), peg.z * 0.31, Color("e1f3ff"))
	conveyor.draw_on(self, font, debug)
	var used_labels: Array[Rect2] = []
	for ball in balls:
		if bool(ball.get("waiting_spawn", false)):
			continue
		var position: Vector2 = ball["p"]
		var radius: float = ball["r"]
		var tone: Color = TEAM_COLORS[int(ball["team"])]
		draw_circle(position, radius + 3.0, tone * Color(1.0, 1.0, 1.0, 0.12))
		draw_circle(position, radius, tone)
		draw_arc(position, maxf(1.0, radius - 0.7), 0.0, TAU, 24, tone.lightened(0.4), 1.0, true)
		draw_circle(position + Vector2(-radius * 0.25, -radius * 0.3), maxf(1.1, radius * 0.24), Color(1.0, 1.0, 1.0, 0.62))
		var text: String = _number(float(ball["value"]))
		if debug:
			text += " r%.1f" % radius
		var width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		var anchor: Vector2 = Vector2(clampf(position.x + radius + 3.0, 19.0, 461.0 - width), position.y + 4.0)
		var label_rect: Rect2 = Rect2(anchor - Vector2(0.0, 10.0), Vector2(width, 13.0))
		for previous in used_labels:
			if label_rect.intersects(previous):
				anchor.y += 13.0
				label_rect.position.y += 13.0
		used_labels.append(label_rect)
		draw_string(font, anchor + Vector2(1.0, 1.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("070c14"))
		draw_string(font, anchor, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("e4eefc"))
