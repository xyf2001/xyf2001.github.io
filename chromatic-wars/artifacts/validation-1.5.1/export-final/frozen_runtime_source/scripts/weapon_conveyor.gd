class_name WeaponConveyor
extends RefCounted

## 唯一坐标 u=(x-left)/cell_width+phase，同时用于画面和命中。
## 武器枚举：0 护盾、1 大球、2 狙击、3 风暴、4 机枪。
const CONTENT: Array[int] = [0, 1, 2, 0, 3, 4]
const LABELS: Array[String] = ["护盾", "大球", "狙击", "风暴", "机枪"]
const LEFT: float = 16.0
const RIGHT: float = 464.0
const CELL_WIDTH: float = (RIGHT - LEFT) / 6.0
const OUTPUT_Y: float = 781.0
const COLORS: Array[Color] = [Color("69c9ed"), Color("d4a2f2"), Color("f7d281"), Color("f28c9c"), Color("9bdfbf")]

var phase: float = 0.0
var speed: float = 0.45
var position_counts: Array[int] = [0, 0, 0, 0, 0, 0]
var content_counts: Array[int] = [0, 0, 0, 0, 0, 0]
var kind_counts: Array[int] = [0, 0, 0, 0, 0]
var last_hit: Dictionary = {}

func configure(settings: Dictionary) -> void:
	speed = clampf(float(settings.get("conveyor_speed", speed)), -4.0, 4.0)

func reset() -> void:
	phase = 0.0
	position_counts = [0, 0, 0, 0, 0, 0]
	content_counts = [0, 0, 0, 0, 0, 0]
	kind_counts = [0, 0, 0, 0, 0]
	last_hit.clear()

func step(dt: float) -> void:
	phase = fposmod(phase + dt * speed, 6.0)

func sample(x: float) -> Dictionary:
	var physical_coordinate: float = clampf((x - LEFT) / CELL_WIDTH, 0.0, 6.0 - 0.000001)
	var content_slot: int = posmod(int(floor(physical_coordinate + phase)), 6)
	return {"x": x, "phase": phase, "position_slot": int(floor(physical_coordinate)), "content_slot": content_slot, "kind": CONTENT[content_slot], "label": LABELS[CONTENT[content_slot]], "u": physical_coordinate + phase}

func register(x: float, ball_id: int, team: int, energy: float) -> Dictionary:
	var hit: Dictionary = sample(x)
	hit["ball_id"] = ball_id
	hit["team"] = team
	hit["energy"] = energy
	position_counts[int(hit["position_slot"])] += 1
	content_counts[int(hit["content_slot"])] += 1
	kind_counts[int(hit["kind"])] += 1
	last_hit = hit.duplicate()
	return hit

func draw_on(canvas: Node2D, font: Font, debug: bool = false) -> void:
	canvas.draw_rect(Rect2(LEFT, OUTPUT_Y, RIGHT - LEFT, 52.0), Color("172438"))
	# 平滑连续的内容带；每个文字以裁剪后的剩余区间居中，不会飘出画布。
	var first_cell: int = int(floor(phase))
	for index in range(first_cell - 1, first_cell + 8):
		var raw_left: float = LEFT + (float(index) - phase) * CELL_WIDTH
		var left: float = maxf(LEFT, raw_left)
		var right: float = minf(RIGHT, raw_left + CELL_WIDTH)
		if right <= left:
			continue
		var content_slot: int = posmod(index, 6)
		var kind: int = CONTENT[content_slot]
		var tone: Color = COLORS[kind]
		canvas.draw_rect(Rect2(left, OUTPUT_Y + 1.0, right - left, 50.0), tone * Color(0.2, 0.2, 0.2, 0.9))
		canvas.draw_line(Vector2(left, OUTPUT_Y + 2.0), Vector2(left, OUTPUT_Y + 50.0), tone.darkened(0.5), 1.0)
		var text: String = LABELS[kind]
		var text_width: float = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		if right - left > text_width + 5.0:
			canvas.draw_string(font, Vector2((left + right - text_width) * 0.5, OUTPUT_Y + 23.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, tone)
	for slot in range(6):
		var left: float = LEFT + float(slot) * CELL_WIDTH
		canvas.draw_line(Vector2(left, OUTPUT_Y - 7.0), Vector2(left, OUTPUT_Y + 4.0), Color("8da6bf"), 1.0)
		canvas.draw_string(font, Vector2(left + 5.0, OUTPUT_Y + 44.0), "%d · %d次" % [slot + 1, position_counts[slot]], HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color("a5b6cc"))
	if debug:
		canvas.draw_string(font, Vector2(20.0, OUTPUT_Y - 12.0), "相位 %.4f / 固定窗口计数" % phase, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color("b3cadf"))

func snapshot() -> Dictionary:
	return {"phase": phase, "speed": speed, "position_counts": position_counts.duplicate(), "content_counts": content_counts.duplicate(), "kind_counts": kind_counts.duplicate(), "last_hit": last_hit.duplicate()}
