class_name MultiplierChannels
extends RefCounted

## 实体槽：mouth_y 是完整入口净宽开始的边缘。判定用圆的后缘，不用球心。
const CUTS: Array[float] = [16.0, 57.0, 112.0, 187.0, 293.0, 368.0, 423.0, 464.0]
const MULTIPLIERS: Array[int] = [8, 4, 2, 0, 2, 4, 8]
const MOUTH_Y: float = 366.0
const END_Y: float = 450.0
const HALF_WALL: float = 4.0

var polygons: Array[PackedVector2Array] = []
var bottom_walls: Array[PackedVector2Array] = []
var counts: Array[int] = [0, 0, 0, 0, 0, 0]
var cuts: Array[float] = CUTS.duplicate()
var channel_widths: Vector3 = Vector3(37.0, 47.0, 67.0)

func _init() -> void:
	_rebuild_geometry()

func configure(settings: Dictionary) -> void:
	channel_widths = Vector3(
		clampf(float(settings.get("channel_width_8", channel_widths.x)), 12.0, 100.0),
		clampf(float(settings.get("channel_width_4", channel_widths.y)), 12.0, 100.0),
		clampf(float(settings.get("channel_width_2", channel_widths.z)), 12.0, 100.0)
	)
	# 六槽镜像调整，三段净宽之和最多158游戏单位，中央通路始终至少84游戏单位。
	var total: float = channel_widths.x + channel_widths.y + channel_widths.z
	if total > 158.0:
		channel_widths = Vector3(12.0, 12.0, 12.0) + (channel_widths - Vector3(12.0, 12.0, 12.0)) * (122.0 / (total - 36.0))
	var first: float = CUTS[0] + channel_widths.x + HALF_WALL
	var second: float = first + channel_widths.y + HALF_WALL * 2.0
	var third: float = second + channel_widths.z + HALF_WALL * 2.0
	cuts = [CUTS[0], first, second, third, 480.0 - third, 480.0 - second, 480.0 - first, CUTS[7]]
	_rebuild_geometry()

func _rebuild_geometry() -> void:
	polygons.clear()
	bottom_walls.clear()
	for index in range(1, 7):
		var x: float = cuts[index]
		# 倾斜上沿、8游戏单位实体厚度；入口以下保持净宽，绝不再次收窄。
		polygons.append(PackedVector2Array([
			Vector2(x - HALF_WALL, MOUTH_Y), Vector2(x - 1.0, MOUTH_Y - 14.0),
			Vector2(x + 1.0, MOUTH_Y - 14.0), Vector2(x + HALF_WALL, MOUTH_Y),
			Vector2(x + HALF_WALL, END_Y), Vector2(x - HALF_WALL, END_Y)
		]))
	# 底墙与可调竖隔板同步，保持抗挤压封底，中央通路保持开放。
	for span in [Vector2(cuts[0], cuts[3] + HALF_WALL), Vector2(cuts[4] - HALF_WALL, cuts[7])]:
		bottom_walls.append(PackedVector2Array([
			Vector2(span.x, END_Y), Vector2(span.y, END_Y),
			Vector2(span.y, END_Y + HALF_WALL * 2.0), Vector2(span.x, END_Y + HALF_WALL * 2.0)
		]))

func reset() -> void:
	counts = [0, 0, 0, 0, 0, 0]

func clear_bounds(channel: int) -> Vector2:
	var left: float = cuts[channel] + (HALF_WALL if channel > 0 else 0.0)
	var right: float = cuts[channel + 1] - (HALF_WALL if channel < 6 else 0.0)
	return Vector2(left, right)

func capture(position: Vector2, radius: float) -> int:
	if position.y - radius < MOUTH_Y or position.y - radius > END_Y:
		return -1
	for channel in range(7):
		if MULTIPLIERS[channel] == 0:
			continue
		var bounds: Vector2 = clear_bounds(channel)
		if position.x - radius >= bounds.x and position.x + radius <= bounds.y:
			return channel
	return -1

func register(channel: int) -> void:
	counts[channel if channel < 3 else channel - 1] += 1

func draw_on(canvas: Node2D, font: Font) -> void:
	for channel in range(7):
		if MULTIPLIERS[channel] == 0:
			continue
		var bounds: Vector2 = clear_bounds(channel)
		var color: Color = Color("61d2ed") if MULTIPLIERS[channel] == 2 else (Color("e6c56b") if MULTIPLIERS[channel] == 4 else Color("f99a76"))
		var rectangle: Rect2 = Rect2(bounds.x, MOUTH_Y, bounds.y - bounds.x, END_Y - MOUTH_Y)
		canvas.draw_rect(rectangle, color * Color(0.27, 0.27, 0.27, 0.35))
		canvas.draw_line(Vector2(bounds.x, MOUTH_Y), Vector2(bounds.y, MOUTH_Y), color, 1.5)
		var label: String = "×%d" % MULTIPLIERS[channel]
		var label_width: float = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 17).x
		canvas.draw_string(font, Vector2((bounds.x + bounds.y - label_width) * 0.5, MOUTH_Y + 36), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 17, color)
		var count: int = counts[channel if channel < 3 else channel - 1]
		canvas.draw_string(font, Vector2(bounds.x + 5.0, END_Y - 11.0), str(count), HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color("a5b6cc"))
	for polygon in polygons + bottom_walls:
		canvas.draw_colored_polygon(polygon, Color("576779"))
		var closed: PackedVector2Array = polygon.duplicate()
		closed.append(closed[0])
		canvas.draw_polyline(closed, Color("a8bdd1"), 1.25, true)

func snapshot() -> Dictionary:
	var widths: Array[float] = []
	for channel in range(7):
		var bounds: Vector2 = clear_bounds(channel)
		widths.append(bounds.y - bounds.x)
	return {"counts": counts.duplicate(), "clear_widths": widths, "mouth_y": MOUTH_Y, "depth": END_Y - MOUTH_Y}
