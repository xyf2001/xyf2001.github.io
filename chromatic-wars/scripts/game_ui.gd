class_name GameUI
extends CanvasLayer
## 仅展示少量统计与四阵营快照；不读取、遍历或重传战场粒子。

signal pause_pressed
signal step_pressed
signal restart_pressed
signal speed_changed(value: float)
signal settings_changed(config: Dictionary)
signal debug_requested(kind: String)
signal editor_mode_changed(enabled: bool)
signal performance_preset_requested
signal clear_custom_pegs_requested
signal restore_preset_pegs_requested
signal clear_all_pegs_requested

const Settings = preload("res://scripts/game_settings.gd")
const TEAM_NAMES := ["红方", "绿方", "蓝方", "黄方"]
const TEAM_COLORS := [Color("ff616e"), Color("5be5ae"), Color("66adff"), Color("ffd260")]
const INK := Color("e3edf8")
const MUTED := Color("8499b2")
const ACCENT := Color("64e3df")

var _config: Dictionary
var _root: Control
var _panel: PanelContainer
var _status: Label
var _metrics: Label
var _footer: Label
var _clock: Label
var _threshold: Label
var _notice: Label
var _ball_details: RichTextLabel
var _detail_table: RichTextLabel
var _details_panel: PanelContainer
var _error: Label
var _pause: Button
var _speed: OptionButton
var _seed: SpinBox
var _team_labels: Array[RichTextLabel] = []
var _inputs: Dictionary = {}
var _syncing := false
var _built := false
var _notice_until := 0
var _diagnostic_text := ""
var _logged_device := ""
var _editor_toggle: CheckButton
var _peg_count: Label
var _rescue_feedback: Array[String] = ["", "", "", ""]

func setup(config: Dictionary) -> void:
	_config = Settings.validate(config)
	layer = 10
	if not _built:
		_build()
		_built = true
	_sync_inputs()

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	var theme := Theme.new()
	var font := load("res://assets/chinese_ui.otf") as Font
	if font:
		theme.default_font = font
	theme.default_font_size = 15
	theme.set_color("font_color", "Label", INK)
	theme.set_color("font_color", "Button", INK)
	theme.set_color("font_color", "OptionButton", INK)
	theme.set_color("font_color", "LineEdit", INK)
	theme.set_color("font_uneditable_color", "LineEdit", MUTED)
	theme.set_stylebox("normal", "Button", _box(Color("152337"), Color("2a3f57"), 7))
	theme.set_stylebox("hover", "Button", _box(Color("223c50"), Color("5c989f"), 7))
	theme.set_stylebox("pressed", "Button", _box(Color("25545b"), ACCENT, 7))
	theme.set_stylebox("focus", "Button", _box(Color(0, 0, 0, 0), ACCENT, 7))
	theme.set_stylebox("normal", "OptionButton", _box(Color("152337"), Color("2a3f57"), 7))
	theme.set_stylebox("hover", "OptionButton", _box(Color("223c50"), Color("5c989f"), 7))
	theme.set_stylebox("pressed", "OptionButton", _box(Color("25545b"), ACCENT, 7))
	theme.set_stylebox("normal", "LineEdit", _box(Color("0b1522"), Color("2a3f57"), 5))
	theme.set_stylebox("focus", "LineEdit", _box(Color("0e1d2d"), ACCENT, 5))
	_root.theme = theme
	var header := _plain_panel(Rect2(20, 12, 1560, 76), Color("0d1828"), Color("25374d"))
	_root.add_child(header)
	_label("颜色大战", Vector2(38, 17), 30, INK, Vector2(310, 39))
	_label("CHROMATIC WARS  /  四色疆域", Vector2(40, 57), 11, MUTED, Vector2(390, 20))
	_pause = _button("暂停", Vector2(530, 22), Vector2(78, 34), func(): pause_pressed.emit())
	_button("单步", Vector2(616, 22), Vector2(66, 34), func(): step_pressed.emit())
	_button("新开局", Vector2(690, 22), Vector2(82, 34), func(): restart_pressed.emit())
	_speed = OptionButton.new()
	_speed.position = Vector2(784, 22)
	_speed.size = Vector2(108, 34)
	for value: float in [0.25, 0.5, 1.0, 2.0, 4.0]:
		_speed.add_item(str(value) + "× 速度")
	_root.add_child(_speed)
	_speed.item_selected.connect(func(index: int):
		var value: float = [0.25, 0.5, 1.0, 2.0, 4.0][index]
		_config["time_scale"] = value
		speed_changed.emit(value)
	)
	_label("种子", Vector2(908, 28), 14, MUTED)
	_seed = SpinBox.new()
	_seed.position = Vector2(946, 22)
	_seed.size = Vector2(150, 34)
	_seed.max_value = 2147483647
	_seed.step = 1
	_seed.allow_greater = false
	_root.add_child(_seed)
	_seed.value_changed.connect(func(value: float): _change("seed", int(value)))
	_button("随机", Vector2(1102, 22), Vector2(64, 34), _random_seed)
	_clock = _label("模拟 00:00", Vector2(1190, 24), 18, INK, Vector2(170, 30))
	_button("球详情", Vector2(1340, 22), Vector2(86, 34), func(): _details_panel.visible = not _details_panel.visible)
	_button("参数设置", Vector2(1434, 22), Vector2(128, 34), func(): _panel.visible = not _panel.visible)
	_status = _label("● GPU 计算管线初始化中…", Vector2(530, 63), 12, ACCENT, Vector2(640, 20))
	_metrics = _label("等待统计", Vector2(1190, 63), 12, MUTED, Vector2(375, 20))
	_label("弹药增幅机", Vector2(22, 90), 15, INK, Vector2(190, 21))
	_threshold = _label("体积门槛 100", Vector2(244, 91), 12, MUTED, Vector2(250, 20))
	_label("四色疆域", Vector2(532, 90), 15, INK)
	_label("GPU 常驻状态 · 固定步长模拟", Vector2(674, 92), 12, MUTED, Vector2(470, 20))
	_label("阵营遥测", Vector2(1398, 90), 15, INK)
	for team: int in range(4):
		_build_team_card(team)
	var detail_panel := _plain_panel(Rect2(1396, 800, 184, 162), Color("0b1523"), Color("26394c"))
	_root.add_child(detail_panel)
	var detail_box := VBoxContainer.new()
	detail_box.add_theme_constant_override("separation", 6)
	detail_panel.add_child(detail_box)
	var diagnostic_heading := HBoxContainer.new()
	detail_box.add_child(diagnostic_heading)
	var tip := Label.new()
	tip.text = "战场诊断"
	tip.add_theme_color_override("font_color", ACCENT)
	tip.add_theme_font_size_override("font_size", 15)
	tip.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	diagnostic_heading.add_child(tip)
	var copy_diagnostics := Button.new()
	copy_diagnostics.text = "复制"
	copy_diagnostics.add_theme_font_size_override("font_size", 11)
	copy_diagnostics.pressed.connect(func():
		DisplayServer.clipboard_set(_diagnostic_text)
		print("CHROMATIC_DIAGNOSTICS " + _diagnostic_text)
	)
	diagnostic_heading.add_child(copy_diagnostics)
	_ball_details = RichTextLabel.new()
	_ball_details.bbcode_enabled = false
	_ball_details.custom_minimum_size = Vector2(160, 96)
	_ball_details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ball_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ball_details.scroll_active = true
	_ball_details.selection_enabled = true
	_ball_details.add_theme_color_override("default_color", MUTED)
	_ball_details.add_theme_font_size_override("normal_font_size", 12)
	_ball_details.text = "左侧 16 颗真实物理球\n右侧 GPU 驻留模拟\n\n暂停后可逐步观察。"
	_ball_details.mouse_filter = Control.MOUSE_FILTER_PASS
	detail_box.add_child(_ball_details)
	_footer = _label("粒子 0  |  大球 0  |  积压 0  |  溢出 0", Vector2(22, 974), 12, MUTED, Vector2(1080, 22))
	_notice = _label("空格 暂停  ·  N 单步  ·  R 重开  ·  Tab 参数", Vector2(1114, 974), 11, MUTED, Vector2(470, 22))
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_error = _label("", Vector2(572, 438), 20, Color("ffb7b7"), Vector2(766, 190))
	_error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_error.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_error.visible = false
	_build_ball_details()
	_build_settings()

func _build_ball_details() -> void:
	_details_panel = _plain_panel(Rect2(28, 164, 466, 630), Color("0b1626"), Color("4c7589"))
	_details_panel.visible = false
	_root.add_child(_details_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	_details_panel.add_child(column)
	var heading := HBoxContainer.new()
	column.add_child(heading)
	var title := Label.new()
	title.text = "16 颗弹药球 · 实时状态"
	title.add_theme_font_size_override("font_size", 19)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	var close := Button.new()
	close.text = "关闭"
	close.pressed.connect(func(): _details_panel.hide())
	heading.add_child(close)
	_detail_table = RichTextLabel.new()
	_detail_table.bbcode_enabled = true
	_detail_table.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_table.add_theme_font_size_override("normal_font_size", 14)
	column.add_child(_detail_table)
	var note := Label.new()
	note.text = "倍率循环保留出生门槛；输出或保命消耗后重生时更新。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 12)
	note.add_theme_color_override("font_color", MUTED)
	column.add_child(note)

func _build_team_card(team: int) -> void:
	var panel := _plain_panel(Rect2(1396, 112 + team * 172, 184, 160), Color("0c1726"), TEAM_COLORS[team].darkened(0.6))
	_root.add_child(panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	panel.add_child(column)
	var title := Label.new()
	title.text = "● " + TEAM_NAMES[team]
	title.add_theme_font_size_override("font_size", 17)
	title.add_theme_color_override("font_color", TEAM_COLORS[team])
	column.add_child(title)
	var text := RichTextLabel.new()
	text.custom_minimum_size = Vector2(160, 116)
	text.bbcode_enabled = true
	text.add_theme_font_size_override("normal_font_size", 12)
	text.add_theme_color_override("default_color", INK)
	text.text = "存活 · 领土 25.0%\n护盾 1,000,000\n机枪 1,000,000\n紧急保命 就绪"
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(text)
	_team_labels.append(text)

func _build_settings() -> void:
	_panel = _plain_panel(Rect2(876, 102, 704, 860), Color("0b1626"), Color("4c7589"))
	_panel.visible = false
	_root.add_child(_panel)
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	_panel.add_child(column)
	var heading := HBoxContainer.new()
	column.add_child(heading)
	var title := Label.new()
	title.text = "实时参数与图形设置"
	title.add_theme_font_size_override("font_size", 22)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	heading.add_child(title)
	var close := Button.new()
	close.text = "收起"
	close.pressed.connect(func(): _panel.hide())
	heading.add_child(close)
	var note := Label.new()
	note.text = "青色参数即时发送；机枪正射速与发完时长在下次真实补弹时锁定，武器速度用于新发射。金色参数在新开局后生效。\n所有游戏时长均按模拟秒计算，暂停时停止计时。\n物理长度统一为游戏单位，与画面像素及窗口缩放无关。"
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 12)
	note.add_theme_color_override("font_color", MUTED)
	column.add_child(note)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	column.add_child(actions)
	for data: Array in [["保存配置", _save], ["加载配置", _load], ["重置默认", _reset]]:
		var button := Button.new()
		button.text = data[0]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.pressed.connect(data[1])
		actions.add_child(button)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	var items := VBoxContainer.new()
	items.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	items.add_theme_constant_override("separation", 6)
	scroll.add_child(items)
	_section(items, "01  弹球物理与空气墙")
	_number(items, "gravity", "重力", 50, 2000, 10, "游戏单位/模拟秒²")
	_number(items, "restitution", "弹性", 0.05, 1, 0.01, "")
	_number(items, "friction", "摩擦", 0, 0.3, 0.005, "")
	_number(items, "air_force", "空气墙推力", 0, 12000, 25, "游戏单位/模拟秒²")
	_number(items, "air_height", "空气墙高度", 40, 280, 5, "游戏单位")
	_number(items, "air_width", "空气墙宽度", 30, 98, 2, "游戏单位")
	_number(items, "air_exponent", "空气墙半径响应曲线", 0.5, 8, 0.1, "指数")
	_section(items, "02  数值与体积 · 门槛指数增长、相对增速渐缓")
	_number(items, "growth_target", "体积门槛目标", 100, 1000000000, 1000, "能量")
	_number(items, "growth_duration", "门槛目标达到时间", 1, 7200, 30, "模拟秒")
	_number(items, "growth_curve_time", "门槛增长缓和时间", 1, 7200, 30, "模拟秒")
	_number(items, "radius_min", "弹药球最小半径", 4, 9, 0.5, "游戏单位")
	_number(items, "radius_max", "弹药球最大半径", 12, 40, 0.5, "游戏单位")
	_number(items, "radius_k", "半径增长系数", 0.1, 30, 0.5, "游戏单位")
	_section(items, "03  武器、护盾与紧急保命")
	_number(items, "intro_shield", "初始唯一护盾", 0, 1000000000, 1000, "能量")
	_number(items, "intro_gun", "初始机枪库存", 0, 1000000000, 1000, "能量")
	_number(items, "gun_rate", "机枪固定射速（0调试停火）", 0, 10000, 10, "粒子/模拟秒")
	_inputs["gun_rate"].tooltip_text = "正射速在下次真实补弹时锁定到本弹匣；设为0立即调试停火。恢复正值后继续原弹匣锁定的射速，停火会延长实际发完时间。"
	_number(items, "gun_rotation_speed", "机枪旋转速度", 0.1, 6, 0.05, "弧度/模拟秒")
	_number(items, "gun_target_switch_cd", "机枪目标切换冷却", 0, 2, 0.01, "模拟秒")
	_number(items, "gun_discharge_duration", "机枪补弹后发完时长", 0.1, 120, 0.1, "模拟秒")
	_inputs["gun_discharge_duration"].tooltip_text = "新时长在下次真实补弹时锁定；按剩余库存加新入能量，在固定射速槽之间商余均匀分配，不把余数全装进尾发。补弹重新计时，不重置射击相位或瞄准；调试停火或粒子池背压会延长实际发完时间。"
	_number(items, "storm_ring_interval", "风暴圈间隔", 0.02, 2, 0.01, "模拟秒")
	var energy_note := Label.new()
	energy_note.text = "机枪每次真实补弹时锁定正射速与发完时长；总库存按固定时间槽商余均匀分配，余数均匀分散。\n补弹重新计时，不重置射击相位或瞄准；更改正射速或时长等待下次真实补弹。\n射速0立即调试停火。能量少时有稀疏空槽；停火或物理池背压会延长实际发完时间，库存仍保留。\n普通高能粒子每染一格消耗 1 能量，剩余继续。风暴最多 3 圈，按输入整数分配。"
	energy_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	energy_note.add_theme_font_size_override("font_size", 12)
	energy_note.add_theme_color_override("font_color", MUTED)
	items.add_child(energy_note)
	_number(items, "ball_speed", "大球发射速度", 10, 500, 2, "游戏单位/模拟秒")
	_number(items, "ball_min_speed", "大球最低移速", 1, 500, 1, "游戏单位/模拟秒")
	_number(items, "sniper_speed", "狙击高能弹速度", 50, 2000, 10, "游戏单位/模拟秒")
	_number(items, "sniper_charge_time", "狙击蓄能时长", 0, 3, 0.05, "模拟秒")
	_number(items, "sniper_split_angle", "狙击分裂偏角", 0, 30, 0.1, "度")
	var sniper_note := Label.new()
	sniper_note.text = "狙击不会被普通粒子偏转；墙、敌盾、敌大球的新接触触发分裂。\n接触结算后的余能按主弹 70% / 子弹 30% 分配，余数归主弹，最多 3 级。"
	sniper_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sniper_note.add_theme_font_size_override("font_size", 12)
	sniper_note.add_theme_color_override("font_color", MUTED)
	items.add_child(sniper_note)
	_number(items, "shield_scale", "护盾半径缩放", 0.25, 3, 0.05, "倍")
	_number(items, "shield_max_diameter", "护盾最大宽度", 32, 768, 0.1, "游戏单位")
	_number(items, "emergency_cd", "紧急保命冷却", 0, 3600, 10, "模拟秒")
	_section(items, "04  GPU 性能与画面 · 容量受设备能力约束")
	var performance_button := Button.new()
	performance_button.text = "应用流畅预设并新开局"
	performance_button.tooltip_text = "应用分圈风暴参数；保留当前领土网格、画面分辨率、粒子可视密度、真实碰撞与拖尾。"
	performance_button.pressed.connect(func(): performance_preset_requested.emit())
	items.add_child(performance_button)
	_choice(items, "particle_capacity", "GPU 粒子容量", [["1 万", 10000], ["5 万", 50000], ["10 万", 100000], ["30 万（高显存）", 300000], ["100 万（压力测试）", 1000000]])
	_choice(items, "grid_size", "领土网格", [["256 × 256 格", 256], ["512 × 512 格", 512], ["768 × 768 格", 768], ["1024 × 1024 格", 1024]])
	_choice(items, "render_size", "战场渲染分辨率", [["512 × 512 像素", 512], ["768 × 768 像素", 768], ["1024 × 1024 像素", 1024], ["1536 × 1536 像素", 1536]])
	_number(items, "particle_radius", "粒子碰撞与显示半径", 0.5, 3, 0.1, "游戏单位")
	_toggle(items, "friendly_particle_collisions", "同阵营普通粒子碰撞", "即时生效。开启后己方普通粒子互相弹开、不消耗弹药；关闭后互相穿过。\n不改变敌方抵消、狙击、己方大球补能或大球之间的碰撞。")
	_number(items, "trail_length", "拖尾保留系数", 0, 0.9, 0.01, "")
	_number(items, "visual_density", "粒子可视密度", 0.05, 1, 0.05, "比例")
	_choice(items, "fixed_dt", "固定模拟步长", [["1/60 模拟秒", 1.0 / 60], ["1/120 模拟秒", 1.0 / 120], ["1/240 模拟秒", 1.0 / 240]])
	_number(items, "fps_limit", "显示帧率上限", 0, 240, 10, "0 = 不限制")
	var warning := Label.new()
	warning.text = "容量、网格、渲染分辨率、步长与随机种子需要新开局。\n粒子按自身剩余整数能量参与碰撞、补给与消耗。\n流畅预设保留分辨率和真实碰撞；容量增加会占用更多显存。"
	warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warning.add_theme_font_size_override("font_size", 12)
	warning.add_theme_color_override("font_color", MUTED)
	items.add_child(warning)
	_section(items, "05  布局编辑 · 固定柱、倍率通道与大本营")
	_editor_toggle = CheckButton.new()
	_editor_toggle.text = "编辑固定柱（开启后暂停）"
	_editor_toggle.toggled.connect(func(enabled: bool): editor_mode_changed.emit(enabled))
	items.add_child(_editor_toggle)
	var layout_note := Label.new()
	layout_note.text = "收起参数后，左侧区域左键加柱、右键删除预设或自定义柱。\n最多 64 根自定义柱；改柱自动保存，不重置球的数值或位置。\n通道左右对称，总宽超过 158 游戏单位会同步缩小。\n通道宽度与护盾上限即时生效；大本营坐标需新开局。"
	layout_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout_note.add_theme_font_size_override("font_size", 12)
	layout_note.add_theme_color_override("font_color", MUTED)
	items.add_child(layout_note)
	_number(items, "peg_radius", "新固定柱半径", 3, 24, 0.1, "游戏单位")
	var peg_row := HBoxContainer.new()
	items.add_child(peg_row)
	_peg_count = Label.new()
	_peg_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_peg_count.add_theme_font_size_override("font_size", 12)
	_peg_count.add_theme_color_override("font_color", MUTED)
	peg_row.add_child(_peg_count)
	var peg_buttons := HBoxContainer.new()
	items.add_child(peg_buttons)
	var restore_pegs := Button.new()
	restore_pegs.text = "恢复预设柱"
	restore_pegs.tooltip_text = "保留自定义柱；与自定义柱重叠的预设暂不恢复。不会重置弹药球。"
	restore_pegs.pressed.connect(func(): restore_preset_pegs_requested.emit())
	peg_buttons.add_child(restore_pegs)
	var clear_pegs := Button.new()
	clear_pegs.text = "清空自定义柱"
	clear_pegs.pressed.connect(func(): clear_custom_pegs_requested.emit())
	peg_buttons.add_child(clear_pegs)
	var clear_all := Button.new()
	clear_all.text = "清空全部固定柱"
	clear_all.tooltip_text = "删除全部预设与自定义固定柱。不会重置弹药球。"
	clear_all.pressed.connect(func(): clear_all_pegs_requested.emit())
	peg_buttons.add_child(clear_all)
	_number(items, "channel_width_8", "8 倍通道净宽", 12, 100, 0.1, "游戏单位")
	_number(items, "channel_width_4", "4 倍通道净宽", 12, 100, 0.1, "游戏单位")
	_number(items, "channel_width_2", "2 倍通道净宽", 12, 100, 0.1, "游戏单位")
	for team: int in range(4):
		_number(items, "core_%d_x" % team, TEAM_NAMES[team] + "大本营 X", 32, 992, 1, "游戏单位")
		_number(items, "core_%d_y" % team, TEAM_NAMES[team] + "大本营 Y", 32, 992, 1, "游戏单位")
	_section(items, "06  调试发射与状态快照")
	var debug_row := HBoxContainer.new()
	items.add_child(debug_row)
	for pair: Array in [["单次大球", "big_ball"], ["风暴", "storm"], ["狙击", "sniper"], ["保命快照", "rescue"]]:
		var button := Button.new()
		button.text = pair[0]
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var kind: String = pair[1]
		button.pressed.connect(func(): debug_requested.emit(kind))
		debug_row.add_child(button)

func update_state(data: Dictionary) -> void:
	if not _built:
		return
	var time := float(data.get("sim_time", 0.0))
	_clock.text = "模拟 %02d:%02d" % [int(time) / 60, int(time) % 60]
	_pause.text = "继续" if bool(data.get("paused", false)) else "暂停"
	var stats: Dictionary = data.get("stats", {})
	var pinball: Dictionary = data.get("pinball", {})
	var active := bool(data.get("gpu_active", false))
	var particle_energy: Variant = stats.get("active_packet_energy", null)
	var energy_text := _compact(float(particle_energy)) if particle_energy != null else "等待遥测"
	_status.text = ("● GPU 常驻 · Texture2DRD 直显" if active else "● GPU 管线未就绪") + "  |  粒子实际能量 " + energy_text
	_status.add_theme_color_override("font_color", ACCENT if active else Color("ffb66e"))
	var gpu_ms := float(stats.get("gpu_ms", data.get("gpu_ms", -1.0)))
	var timing := "GPU %.2f ms" % gpu_ms if gpu_ms >= 0 else "GPU 计时不可用"
	_metrics.text = "%.0f FPS  ·  %s" % [float(data.get("fps", 0.0)), timing]
	var device := str(stats.get("device", "等待GPU状态验证"))
	_metrics.tooltip_text = "Vulkan GPU: " + device
	if stats.has("device") and device != _logged_device:
		_logged_device = device
		print("CHROMATIC_GPU_DEVICE " + device)
	_threshold.text = "体积门槛 " + _compact(float(pinball.get("threshold", _growth_threshold(time))))
	var count := int(stats.get("active_particles", stats.get("active", stats.get("particles", 0))))
	var big := int(stats.get("big_balls", stats.get("big", 0)))
	var queue := float(stats.get("queue_energy", stats.get("queued_energy", stats.get("backlog", 0))))
	var overflow := int(stats.get("overflow_count", stats.get("overflow", 0)))
	var memory := float(stats.get("memory_mb", stats.get("vram_mb", 0)))
	var grid := int(stats.get("grid_size", _config["grid_size"]))
	_footer.text = "粒子 %s / %s  ·  大球 %d  ·  积压能量 %s  ·  溢出 %d  ·  领土 %d²  ·  显存估算 %.1f MB" % [_number_text(count), _number_text(int(stats.get("particle_capacity", _config["particle_capacity"]))), big, _compact(queue), overflow, grid, memory]
	var teams: Variant = stats.get("teams", data.get("teams", []))
	if teams is Array and teams.size() == 4:
		for team: int in range(4):
			if teams[team] is Dictionary:
				_update_team(team, teams[team])
	else:
		for label: RichTextLabel in _team_labels:
			label.text = "等待GPU状态验证\n护盾 —\n机枪 —\n紧急保命 —"
	var error_text := str(data.get("error", ""))
	_error.visible = not error_text.is_empty()
	_error.text = "模拟已停止\n" + error_text + "\n\n请修正参数或新开局。图形错误需要 Godot 4.3+、Forward+、Vulkan显卡与驱动。" if not error_text.is_empty() else ""
	var balls: Variant = pinball.get("balls", [])
	var diag := "GPU: %s\n活跃弹药球 %d / 16\n在场粒子实际能量 %s\n高能权重 · 整数能量结算\n固定步长 %.3f 模拟毫秒\n" % [device, int(pinball.get("active_count", pinball.get("active_balls", 16))), energy_text, float(data.get("fixed_dt", _config["fixed_dt"])) * 1000]
	if balls is Array and not balls.is_empty():
		if _details_panel.visible:
			_update_ball_table(balls)
		var largest: Dictionary = {}
		for ball: Variant in balls:
			if ball is Dictionary and float(ball.get("value", ball.get("ammo", 0))) > float(largest.get("value", largest.get("ammo", -1))):
				largest = ball
		if not largest.is_empty():
			diag += "最大球 #%s · %s\n数值 %s / 半径 %.1f 游戏单位" % [str(largest.get("id", "—")), TEAM_NAMES[clampi(int(largest.get("team", 0)), 0, 3)], _compact(float(largest.get("value", largest.get("ammo", 0)))), float(largest.get("radius", 0))]
	_ball_details.text = diag
	_diagnostic_text = JSON.stringify({"version": ProjectSettings.get_setting("application/config/version", "initial"), "device": device, "fps": float(data.get("fps", 0.0)),
		"gpu_ms": gpu_ms, "sim_time": time, "paused": bool(data.get("paused", false)),
		"time_scale": data.get("settings", _config).get("time_scale", 0.25), "time_backlog": data.get("time_backlog", 0.0),
		"fixed_dt": data.get("fixed_dt", _config["fixed_dt"]), "particle_model": "weighted_integer_energy", "active_particle_energy": particle_energy,
		"friendly_particle_collisions": _config["friendly_particle_collisions"],
		"active_particles": count, "particle_capacity": stats.get("particle_capacity", _config["particle_capacity"]),
		"big_balls": big, "queue_energy": queue, "grid_size": grid,
		"render_size": _config["render_size"], "overflow_count": overflow})
	if Time.get_ticks_msec() > _notice_until:
		_notice.text = "放柱模式：左键放置 / 右键删除  ·  参数内可关闭" if _editor_toggle.button_pressed else "空格 暂停  ·  N 单步  ·  R 重开  ·  Tab 参数"

func set_editor_mode(enabled: bool) -> void:
	if _editor_toggle:
		_editor_toggle.set_pressed_no_signal(enabled)

func sync_editor_config(config: Dictionary) -> void:
	_config = Settings.validate(config)
	if _built:
		_sync_inputs()

func set_custom_pegs(pegs: Array) -> void:
	_config["custom_pegs"] = pegs.duplicate()
	_update_peg_count()

func _update_peg_count() -> void:
	if _peg_count:
		_peg_count.text = "预设 %d / 15 · 自定义 %d / 64（自动保存）" % [15 - _config["disabled_preset_pegs"].size(), _config["custom_pegs"].size()]

func _update_ball_table(balls: Array) -> void:
	var text := "[table=5][cell]编号[/cell][cell]阵营[/cell][cell]弹药[/cell][cell]半径（游戏单位）[/cell][cell]出生门槛[/cell]"
	for ball: Variant in balls:
		if not ball is Dictionary:
			continue
		var team := clampi(int(ball.get("team", 0)), 0, 3)
		var color: String = TEAM_COLORS[team].to_html(false)
		text += "[cell]#%s[/cell][cell][color=#%s]%s[/color][/cell][cell]%s[/cell][cell]%.1f[/cell][cell]%s[/cell]" % [str(ball.get("id", "—")), color, TEAM_NAMES[team], _compact(float(ball.get("value", ball.get("ammo", 0)))), float(ball.get("radius", ball.get("r", 0))), _compact(float(ball.get("birth_threshold", ball.get("t_birth", ball.get("threshold", 100)))))]
	text += "[/table]"
	_detail_table.text = text

func _update_team(index: int, team: Dictionary) -> void:
	var alive := bool(team.get("alive", int(team.get("state", 0)) != 2))
	var pending := bool(team.get("pending", team.get("pending_rescue", false)))
	var state := "保命处理中" if pending else ("存活" if alive else "已淘汰")
	var territory := float(team.get("territory", team.get("territory_ratio", 0.25)))
	if territory <= 1:
		territory *= 100
	# GPU整数库存可超过float64精确整数范围；完整数字/提示保留原int64低位。
	var shield := int(team.get("shield", team.get("shield_energy", 0)))
	var gun := int(team.get("gun", team.get("gun_energy", 0)))
	var cd := float(team.get("rescue_cd", team.get("emergency_cd", 0)))
	var cd_text := "就绪" if cd <= 0 else "%.1f 模拟秒" % cd
	_team_labels[index].text = "%s · 领土 %.1f%%\n护盾 %s\n机枪 %s\n紧急保命 %s" % [state, territory, _number_text(shield), _number_text(gun), cd_text]
	_team_labels[index].tooltip_text = "护盾 %s\n机枪 %s\n保命冷却 %.3f 模拟秒" % [_number_text(shield), _number_text(gun), cd]
	if not _rescue_feedback[index].is_empty():
		_team_labels[index].text += "\n[color=#ffd27d]" + _rescue_feedback[index] + "[/color]"

func clear_rescue_feedback() -> void:
	_rescue_feedback.fill("")

func show_rescue_feedback(team: int, message: String) -> void:
	if team < 0 or team >= _rescue_feedback.size():
		return
	_rescue_feedback[team] = message
	_notify(TEAM_NAMES[team] + " · " + message)

func _input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var focus := _root.get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	match event.keycode:
		KEY_SPACE: pause_pressed.emit()
		KEY_N: step_pressed.emit()
		KEY_R: restart_pressed.emit()
		KEY_TAB: _panel.visible = not _panel.visible
		KEY_ESCAPE:
			_panel.hide()
			_details_panel.hide()
		_: return
	_root.get_viewport().set_input_as_handled()

func _number(parent: VBoxContainer, key: String, title: String, minimum: float, maximum: float, step: float, unit: String) -> void:
	var row := _parameter_row(parent, key, title)
	var input := SpinBox.new()
	input.min_value = minimum
	input.max_value = maximum
	# SpinBox 的 step 会对 value 做网格取整；细步长保证 4.2、0.012、1200 等默认值显示准确。
	input.step = 0.001 if step < 1.0 else 1.0
	input.custom_minimum_size = Vector2(170, 34)
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(input)
	var unit_label := Label.new()
	unit_label.text = unit
	unit_label.custom_minimum_size.x = 115
	unit_label.add_theme_font_size_override("font_size", 11)
	unit_label.add_theme_color_override("font_color", MUTED)
	row.add_child(unit_label)
	_inputs[key] = input
	input.value_changed.connect(func(value: float): _change(key, value))

func _choice(parent: VBoxContainer, key: String, title: String, options: Array) -> void:
	var row := _parameter_row(parent, key, title)
	var input := OptionButton.new()
	input.custom_minimum_size = Vector2(280, 34)
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for option: Array in options:
		input.add_item(option[0])
		input.set_item_metadata(input.item_count - 1, option[1])
	row.add_child(input)
	_inputs[key] = input
	input.item_selected.connect(func(index: int): _change(key, input.get_item_metadata(index)))

func _toggle(parent: VBoxContainer, key: String, title: String, explanation: String) -> void:
	var row := _parameter_row(parent, key, title)
	var input := CheckButton.new()
	input.text = "启用"
	input.tooltip_text = explanation
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(input)
	_inputs[key] = input
	input.toggled.connect(func(enabled: bool): _change(key, enabled))

func _parameter_row(parent: VBoxContainer, key: String, title: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	parent.add_child(row)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size.x = 218
	label.add_theme_font_size_override("font_size", 13)
	if key == "gun_rate" or key == "gun_discharge_duration":
		label.tooltip_text = "参数即时发送；下次真实补弹时锁定。射速0立即调试停火。"
	else:
		label.tooltip_text = "即时生效" if key in Settings.LIVE_KEYS else "新开局后生效"
	label.add_theme_color_override("font_color", ACCENT if key in Settings.LIVE_KEYS else Color("eac475"))
	row.add_child(label)
	return row

func _section(parent: VBoxContainer, title: String) -> void:
	var label := Label.new()
	label.text = title
	label.add_theme_color_override("font_color", INK)
	label.add_theme_font_size_override("font_size", 15)
	label.custom_minimum_size.y = 39
	parent.add_child(label)

func _change(key: String, value: Variant) -> void:
	if _syncing:
		return
	_config[key] = value
	_config = Settings.validate(_config)
	_sync_inputs()
	settings_changed.emit(_config.duplicate(true))
	_notify("参数已更新" if key in Settings.LIVE_KEYS else "设置已记录；新开局后生效")

func _sync_inputs() -> void:
	_syncing = true
	for key: String in _inputs:
		var input: Control = _inputs[key]
		if input is SpinBox:
			input.value = float(_config[key])
		elif input is CheckButton:
			input.set_pressed_no_signal(bool(_config[key]))
		elif input is OptionButton:
			for index: int in range(input.item_count):
				if input.get_item_metadata(index) == _config[key]:
					input.select(index)
	_seed.value = float(_config["seed"])
	_speed.select([0.25, 0.5, 1.0, 2.0, 4.0].find(float(_config["time_scale"])))
	_update_peg_count()
	_syncing = false

func _save() -> void:
	var error := Settings.save_file(_config)
	_notify("配置已保存到用户目录" if error == OK else "配置保存失败：" + error_string(error))

func _load() -> void:
	_config = Settings.load_file()
	_sync_inputs()
	settings_changed.emit(_config.duplicate(true))
	speed_changed.emit(float(_config["time_scale"]))
	_notify("配置已加载；金色参数在新开局生效")

func _reset() -> void:
	_config = Settings.defaults()
	_sync_inputs()
	settings_changed.emit(_config.duplicate(true))
	speed_changed.emit(float(_config["time_scale"]))
	_notify("已恢复默认参数；新开局可完整应用")

func _random_seed() -> void:
	_seed.value = randi_range(0, 2147483647)
	_notify("新随机种子已记录；点击新开局应用")

func _notify(message: String) -> void:
	_notice.text = message
	# 仅界面提示寿命使用真实时间，暂停后仍可消失；不是游戏秒数设置。
	_notice_until = Time.get_ticks_msec() + 5000

func _plain_panel(rect: Rect2, fill: Color, border: Color) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.position = rect.position
	panel.size = rect.size
	panel.add_theme_stylebox_override("panel", _box(fill, border, 10))
	return panel

func _box(fill: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 10
	style.content_margin_bottom = 10
	return style

func _label(value: String, position: Vector2, font_size: int, color: Color, extent := Vector2(160, 25)) -> Label:
	var label := Label.new()
	label.text = value
	label.position = position
	label.size = extent
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(label)
	return label

func _button(value: String, position: Vector2, extent: Vector2, action: Callable) -> Button:
	var button := Button.new()
	button.text = value
	button.position = position
	button.size = extent
	button.pressed.connect(action)
	_root.add_child(button)
	return button

func _compact(value: float) -> String:
	if value >= 1000000000:
		return "%.2f十亿" % (value / 1000000000)
	if value >= 100000000:
		return "%.2f亿" % (value / 100000000)
	if value >= 10000:
		return "%.2f万" % (value / 10000)
	return "%.0f" % value

func _growth_threshold(sim_time: float) -> float:
	# 与 PinballPhysics 的弛缓指数相同；没有左侧遥测时才使用备用显示。
	var curve_time := float(_config["growth_curve_time"])
	var target_time := float(_config["growth_duration"])
	var curve_denominator := sqrt(1.0 + target_time / curve_time) - 1.0
	var curve_progress := (sqrt(1.0 + maxf(sim_time, 0.0) / curve_time) - 1.0) / curve_denominator
	return exp(minf(69.07755278982137, log(100.0) + log(float(_config["growth_target"]) / 100.0) * curve_progress))

func _number_text(value: int) -> String:
	var digits := str(value)
	var result := ""
	for index: int in range(digits.length()):
		if index > 0 and (digits.length() - index) % 3 == 0:
			result += ","
		result += digits[index]
	return result
