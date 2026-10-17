class_name BattleLabels
extends Node2D
## 这里只显示每0.25真实秒读回的少量阵营/大球遥测。普通粒子和领土没有CPU绘制路径。
const COLORS := [Color("ff6476"), Color("65e8aa"), Color("63a5ff"), Color("f4d369")]
const NAMES := ["红方", "绿方", "蓝方", "黄方"]
var font: Font
var stats: Dictionary = {}
var area := Rect2(530, 112, 850, 850)

func compact(value: float) -> String:
	if value >= 100000000.0: return "%.2f亿" % (value / 100000000.0)
	if value >= 10000.0: return "%.2f万" % (value / 10000.0)
	return "%.0f" % value

func badge(point: Vector2, text: String, color: Color, size: int = 13) -> void:
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x + 14.0
	point.x = clampf(point.x, area.position.x + width * 0.5 + 5, area.end.x - width * 0.5 - 5)
	point.y = clampf(point.y, area.position.y + 20, area.end.y - 8)
	var box := Rect2(point + Vector2(-width * 0.5, -size - 3), Vector2(width, size + 9))
	draw_rect(box, Color(0.025, 0.05, 0.09, 0.86))
	draw_line(box.position, box.position + Vector2(width, 0), Color(color, 0.7), 1.0)
	draw_string(font, point + Vector2(-width * 0.5 + 7, 0), text,
		HORIZONTAL_ALIGNMENT_LEFT, width - 14, size, color)

func _draw() -> void:
	if font == null: return
	var factor := area.size.x / 1024.0
	var teams: Array = stats.get("teams", [])
	for i in teams.size():
		var team: Dictionary = teams[i]
		var core := area.position + Vector2(float(team.get("x", 256)), float(team.get("y", 256))) * factor
		if not bool(team.get("alive", true)):
			badge(core, NAMES[i] + " · 已淘汰", Color("9cabb8"))
			continue
		var radius := float(team.get("shield_radius", 45)) * factor
		badge(core + Vector2(0, -radius - 12), NAMES[i] + " · 护盾 " + compact(float(team.get("shield", 0))), COLORS[i])
		var cd := float(team.get("rescue_cd", 0))
		var status := "保命待定" if bool(team.get("pending", false)) else ("紧急保命 就绪" if cd <= 0 else "紧急保命 %.0f模拟秒" % cd)
		badge(core + Vector2(0, radius + 27), status, Color("d2e0ee"), 11)
	var balls: Array = stats.get("balls", [])
	for ball: Dictionary in balls:
		var team := clampi(int(ball.get("team", 0)), 0, 3)
		var point := area.position + Vector2(float(ball.get("x", 0)), float(ball.get("y", 0))) * factor
		var radius := float(ball.get("radius", 10)) * factor
		var label_point := point + Vector2(0, radius + 18)
		for core_info: Dictionary in teams:
			var core := area.position + Vector2(float(core_info.get("x", 0)), float(core_info.get("y", 0))) * factor
			if label_point.distance_to(core) < 90:
				label_point = point + Vector2(radius + 55, -radius - 10)
		badge(label_point, "大球 " + compact(float(ball.get("energy", 0))), COLORS[team])
