class_name AirCurtain
extends RefCounted

var strength: float = 2950.0
var width: float = 96.0
var height: float = 180.0
var top: float = 286.0
var reference_radius: float = 4.2
var response_power: float = 2.8
var spread: float = 310.0

func configure(settings: Dictionary) -> void:
	strength = maxf(0.0, float(settings.get("air_force", strength)))
	width = clampf(float(settings.get("air_width", width)), 16.0, 98.0)
	height = clampf(float(settings.get("air_height", height)), 40.0, 280.0)
	top = 466.0 - height
	reference_radius = maxf(1.0, float(settings.get("radius_min", reference_radius)))
	response_power = clampf(float(settings.get("air_response_power", settings.get("air_exponent", response_power))), 0.2, 8.0)
	spread = maxf(0.0, float(settings.get("air_spread", spread)))

func acceleration(position: Vector2, radius: float, mass: float = -1.0, ammo_factor: float = 0.0, velocity: Vector2 = Vector2.ZERO, growth_ratio: float = 1.0, substep_dt: float = 0.0) -> Vector2:
	if strength <= 0.0:
		return Vector2.ZERO
	var half_width: float = width * 0.5
	# A circle feels air while its footprint overlaps the curtain. Testing
	# only its centre left almost no force beside the central passage walls.
	var horizontal_margin: float = half_width - absf(position.x - 240.0) + radius
	var vertical_margin: float = minf(position.y - top, top + height - position.y) + radius
	if horizontal_margin <= 0.0 or vertical_margin <= 0.0:
		return Vector2.ZERO
	# Smooth boundaries avoid a discontinuous acceleration switch. Strength
	# remains the reference small-ball acceleration; force is divided by the
	# bounded physical mass, never by raw trillion-scale ammunition values.
	var fade_width: float = minf(12.0, half_width * 0.28)
	var horizontal_t: float = clampf(horizontal_margin / maxf(1.0, fade_width), 0.0, 1.0)
	var vertical_t: float = clampf(vertical_margin / 14.0, 0.0, 1.0)
	var envelope: float = (
		horizontal_t * horizontal_t * (3.0 - 2.0 * horizontal_t)
		* vertical_t * vertical_t * (3.0 - 2.0 * vertical_t)
	)
	var base_mass: float = reference_radius * reference_radius
	var effective_mass: float = mass if mass > 0.0 else maxf(base_mass, radius * radius)
	var size_ratio: float = maxf(1.0, radius / reference_radius)
	var area_response: float = pow(size_ratio, clampf(3.0 - response_power, 0.0, 2.0))
	var response: float = (
		envelope * area_response * base_mass / maxf(base_mass, effective_mass)
		/ (1.0 + 1.8 * clampf(ammo_factor, 0.0, 1.0))
	)
	var side: float = (position.x - 240.0) / half_width
	# Downward motion through the updraft also encounters drag. Newly born
	# small balls resist being punched through the finite curtain by another
	# ball; grown balls gradually lose this extra assistance and can fall.
	# h is in 模拟秒. Limit the drag impulse to avoid a numerical reversal
	# within one substep, without imposing a speed or output-value gate.
	var light_factor: float = 1.0 - smoothstep(1.0, 4.0, growth_ratio)
	var downward_speed: float = maxf(0.0, velocity.y)
	var downward_drag: float = (
		12.0 / maxf(height, 40.0) * downward_speed * downward_speed
		* base_mass / maxf(base_mass, effective_mass) * envelope * light_factor
		* strength / 2950.0
	)
	if substep_dt > 0.0:
		downward_drag = minf(downward_drag, 0.8 * downward_speed / substep_dt)
	return Vector2(side * spread * response, -strength * response - downward_drag)

func draw_on(canvas: Node2D, simulation_time: float) -> void:
	var left: float = 240.0 - width * 0.5
	canvas.draw_rect(Rect2(left, top, width, height), Color(0.18, 0.64, 0.91, 0.055))
	for index in range(11):
		var x: float = left + (float(index) + 0.5) * width / 11.0
		var y: float = top + fposmod(float(index) * 41.0 - simulation_time * 180.0, height)
		var alpha: float = 0.25 + 0.16 * sin(float(index) * 2.0)
		var tone: Color = Color(0.32, 0.8, 1.0, alpha)
		canvas.draw_line(Vector2(x, minf(y + 15.0, top + height)), Vector2(x, y), tone, 1.3)
		canvas.draw_line(Vector2(x - 2.5, y + 5.0), Vector2(x, y), tone, 1.3)
		canvas.draw_line(Vector2(x + 2.5, y + 5.0), Vector2(x, y), tone, 1.3)

func snapshot() -> Dictionary:
	return {"strength": strength, "width": width, "height": height, "top": top, "response_power": response_power}
