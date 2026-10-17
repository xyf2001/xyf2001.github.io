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
signal stage_profile_requested
signal manual_weapon_requested(team: int, kind: int, energy: int)
signal territory_brush_changed(enabled: bool, team: int, radius: float)

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
var _diagnostic_payload: Dictionary = {}
var _diagnostic_state: Dictionary = {}
var diagnostic_provider: Callable
var _logged_device := ""
var _editor_toggle: CheckButton
var _peg_count: Label
var _rescue_feedback: Array[String] = ["", "", "", ""]
var _stage_profile_button: Button
var _active_team_count := 4
var _manual_team: OptionButton
var _manual_weapon: OptionButton
var _manual_energy: LineEdit
var _manual_status: Label
var _brush_toggle: CheckButton
var _brush_team: OptionButton
var _brush_radius: SpinBox
const MAX_MANUAL_ENERGY_TEXT := "9223372036854775807"

func setup(config: Dictionary) -> void:
	_config = Settings.validate(config)
	layer = 10
	if not _built:
		_build()
		_built = true
	_sync_inputs()
	set_active_team_count(_active_team_count)

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
	copy_diagnostics.text = "复制完整诊断与配置"
	copy_diagnostics.tooltip_text = "手动复制版本、设备、遥测和全部当前设置；区分开局配置、已提交参数与待新开局设置。不自动上传。"
	copy_diagnostics.add_theme_font_size_override("font_size", 11)
	copy_diagnostics.pressed.connect(_copy_complete_diagnostics)
	detail_box.add_child(copy_diagnostics)
	_stage_profile_button = Button.new()
	_stage_profile_button.text = "采集GPU阶段耗时"
	_stage_profile_button.add_theme_font_size_override("font_size", 11)
	_stage_profile_button.tooltip_text = "手动采样当前对局下一个模拟批次的一个微子步及最终绘制，不是整批耗时。不启动测试、不读取粒子表、不上传。暂停时需继续或单步。"
	_stage_profile_button.pressed.connect(func():
		stage_profile_requested.emit()
	)
	detail_box.add_child(_stage_profile_button)
	_ball_details = RichTextLabel.new()
	_ball_details.bbcode_enabled = false
	_ball_details.custom_minimum_size = Vector2(160, 36)
	_ball_details.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_ball_details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_ball_details.scroll_active = true
	_ball_details.selection_enabled = true
	_ball_details.add_theme_color_override("default_color", MUTED)
	_ball_details.add_theme_font_size_override("normal_font_size", 12)
	_ball_details.text = "左侧每个参战阵营4颗真实球\n右侧 GPU 驻留模拟\n\n暂停后可逐步观察。"
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
	_choice(items, "team_count", "参战阵营数量（新开局）", [["1 队 · 红方", 1], ["2 队 · 红绿", 2], ["3 队 · 红绿蓝", 3], ["4 队 · 全部", 4]])
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
	_section(items, "06  人工调试 · 单次武器与领土画笔")
	var manual_note := Label.new()
	manual_note.text = "只可选择本局参战阵营；更改阵营数量后需新开局。\n武器每次点击或Enter只输入一次；暂停也可入账，已到时发射仍可执行，后续计时需继续或单步。\n能量上限9223372036854775807；库存相加越界仍按原GPU保护暂停，不截断。"
	manual_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	manual_note.add_theme_font_size_override("font_size", 12)
	items.add_child(manual_note)
	var weapon_row := _parameter_row(items, "manual_weapon", "人工输入阵营 / 武器")
	weapon_row.get_child(0).tooltip_text = "仅本局参战阵营；选择本身不发送武器"
	_manual_team = OptionButton.new()
	_manual_team.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	weapon_row.add_child(_manual_team)
	_manual_weapon = OptionButton.new()
	for weapon_title: String in ["护盾", "大球", "狙击", "风暴", "机枪补弹"]:
		_manual_weapon.add_item(weapon_title)
	_manual_weapon.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	weapon_row.add_child(_manual_weapon)
	var energy_row := _parameter_row(items, "manual_energy", "单次整数能量")
	energy_row.get_child(0).tooltip_text = "每次点击只提交一次；暂停时也可入账，武器计时随模拟推进"
	_manual_energy = LineEdit.new()
	_manual_energy.text = "10000"
	_manual_energy.placeholder_text = "1～9223372036854775807"
	_manual_energy.tooltip_text = "只接受十进制正整数；超限会拒绝，输入保留，不转浮点或截断。"
	_manual_energy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_manual_energy.text_submitted.connect(func(_text: String): _submit_manual_weapon())
	energy_row.add_child(_manual_energy)
	var fire := Button.new()
	fire.text = "提交一次人工武器输入"
	fire.pressed.connect(_submit_manual_weapon)
	items.add_child(fire)
	_manual_status = Label.new()
	_manual_status.text = "尚未提交人工输入"
	_manual_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_manual_status.add_theme_font_size_override("font_size", 12)
	items.add_child(_manual_status)
	_brush_toggle = CheckButton.new()
	_brush_toggle.text = "人工领土画笔（开启后暂停）"
	_brush_toggle.toggled.connect(func(_enabled: bool): _emit_brush_settings())
	items.add_child(_brush_toggle)
	var brush_row := _parameter_row(items, "territory_brush", "画笔阵营 / 半径")
	brush_row.get_child(0).tooltip_text = "人工调试染色，单位与显示分辨率无关"
	_brush_team = OptionButton.new()
	_brush_team.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_brush_team.item_selected.connect(func(_index: int): _emit_brush_settings())
	brush_row.add_child(_brush_team)
	_brush_radius = SpinBox.new()
	_brush_radius.min_value = 4
	_brush_radius.max_value = 128
	_brush_radius.step = 1
	_brush_radius.value = 24
	_brush_radius.suffix = " 游戏单位"
	_brush_radius.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_brush_radius.value_changed.connect(func(_value: float): _emit_brush_settings())
	brush_row.add_child(_brush_radius)
	var brush_note := Label.new()
	brush_note.text = "人工染色不消耗武器能量。收起面板后在右侧地图左键按住拖动，右键关闭画笔。\n开启时暂停，可明确点击继续边运行边画；不会在地图外绘制，不改变左侧柱编辑。"
	brush_note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	brush_note.add_theme_font_size_override("font_size", 12)
	items.add_child(brush_note)
	var rescue_snapshot := Button.new()
	rescue_snapshot.text = "保命状态快照"
	rescue_snapshot.pressed.connect(func(): debug_requested.emit("rescue"))
	items.add_child(rescue_snapshot)

func update_state(data: Dictionary) -> void:
	if not _built:
		return
	_diagnostic_state = data.duplicate()
	var time := float(data.get("sim_time", 0.0))
	_clock.text = "模拟 %02d:%02d" % [int(time) / 60, int(time) % 60]
	_pause.text = "继续" if bool(data.get("paused", false)) else "暂停"
	var stats: Dictionary = data.get("stats", {})
	set_active_team_count(int(data.get("active_team_count", stats.get("active_team_count", _active_team_count))))
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
		for index: int in _team_labels.size():
			if index >= _active_team_count:
				_show_disabled_team(index)
			else:
				_team_labels[index].text = "等待GPU状态验证\n护盾 —\n机枪 —\n紧急保命 —"
	var error_text := str(data.get("error", ""))
	_error.visible = not error_text.is_empty()
	_error.text = "模拟已停止\n" + error_text + "\n\n请修正参数或新开局。图形错误需要 Godot 4.3+、Forward+、Vulkan显卡与驱动。" if not error_text.is_empty() else ""
	var balls: Variant = pinball.get("balls", [])
	var diag := "GPU: %s\n本局参战 %d 队 · 弹药球 %d / %d\n在场粒子实际能量 %s\n高能权重 · 整数能量结算\n固定步长 %.3f 模拟毫秒\n" % [device, _active_team_count, int(pinball.get("active_count", pinball.get("active_balls", _active_team_count * 4))), _active_team_count * 4, energy_text, float(data.get("fixed_dt", _config["fixed_dt"])) * 1000]
	if balls is Array and not balls.is_empty():
		if _details_panel.visible:
			_update_ball_table(balls)
		var largest: Dictionary = {}
		for ball: Variant in balls:
			if ball is Dictionary and float(ball.get("value", ball.get("ammo", 0))) > float(largest.get("value", largest.get("ammo", -1))):
				largest = ball
		if not largest.is_empty():
			diag += "最大球 #%s · %s\n数值 %s / 半径 %.1f 游戏单位" % [str(largest.get("id", "—")), TEAM_NAMES[clampi(int(largest.get("team", 0)), 0, 3)], _compact(float(largest.get("value", largest.get("ammo", 0)))), float(largest.get("radius", 0))]
	var stage_profile: Dictionary = data.get("last_stage_profile", {})
	var stage_text := _stage_profile_text(stage_profile)
	_ball_details.text = stage_text + "\n\n" + diag
	_stage_profile_button.tooltip_text = "分阶段仅采样1个微子步+最终绘制，不代表整批阶段累计；整批总计另列。采集本身增加时间戳/列表开销，不新增粒子读回或自动上传；暂停时需继续或单步。\n\n" + stage_text
	# 保留旧顶层字段的小摘要。全量配置仅在点击复制时生成和序列化。
	_diagnostic_payload = {"version": ProjectSettings.get_setting("application/config/version", "initial"), "device": device, "fps": float(data.get("fps", 0.0)),
		"gpu_ms": gpu_ms, "sim_time": time, "paused": bool(data.get("paused", false)),
		"time_scale": data.get("settings", _config).get("time_scale", 1.0), "time_backlog": data.get("time_backlog", 0.0),
		"fixed_dt": data.get("fixed_dt", _config["fixed_dt"]), "particle_model": "weighted_integer_energy", "active_particle_energy": particle_energy,
		"friendly_particle_collisions": _config["friendly_particle_collisions"],
		"active_particles": count, "particle_capacity": stats.get("particle_capacity", _config["particle_capacity"]),
		"big_balls": big, "queue_energy": queue, "grid_size": grid,
		"render_size": _config["render_size"], "overflow_count": overflow}
	_diagnostic_text = JSON.stringify(_diagnostic_payload)
	if Time.get_ticks_msec() > _notice_until:
		_notice.text = "领土画笔：右图左键拖动 / 右键关闭  ·  可显式继续" if _brush_toggle.button_pressed else ("放柱模式：左键放置 / 右键删除  ·  参数内可关闭" if _editor_toggle.button_pressed else "空格 暂停  ·  N 单步  ·  R 重开  ·  Tab 参数")

func _stage_profile_text(profile: Dictionary) -> String:
	if profile.is_empty():
		return "阶段计时：未采集\n范围：1微子步+最终绘制，非整批"
	var status := str(profile.get("status", "unknown")).to_lower()
	var states := {"not_requested":"未采集", "not_collected":"未采集", "requested":"等待下个批次", "waiting_for_timestamps":"等待时间戳", "pending":"等待采集", "complete":"采集完成", "completed":"采集完成", "ready":"采集完成", "partial":"部分数据", "unavailable":"不可用", "error":"采集失败"}
	var text := "阶段计时：" + str(states.get(status, status))
	text += "\n分阶段：1微子步+最终绘制，非整批"
	if status in ["pending", "requested"]:
		text += "\n等待下个模拟批次；暂停时需继续或单步"
	if profile.has("batch_id"):
		text += "\n批次 " + str(profile.batch_id)
	if profile.has("batch_substeps"):
		text += " · 全批 " + str(profile.batch_substeps) + " 微子步"
	if profile.has("sampled_substep_index"):
		text += "\n采样微子步索引 " + str(profile.sampled_substep_index)
	if profile.has("sim_start") and profile.has("sim_end"):
		text += "\n批次模拟 %.3f→%.3f 秒" % [float(profile.sim_start), float(profile.sim_end)]
	if profile.has("sampled_substep_dt"):
		text += "\n采样步长 %.3f 模拟毫秒" % (float(profile.sampled_substep_dt) * 1000.0)
	var batch_ms: Variant = profile.get("batch_gpu_ms")
	if (batch_ms is int or batch_ms is float) and is_finite(float(batch_ms)):
		text += "\n整批GPU总计 %.3f ms" % float(batch_ms)
	elif status in ["complete", "completed", "ready", "partial"]:
		text += "\n整批GPU总计：缺测"
	var stages: Variant = profile.get("gpu_ms_by_mode", profile.get("stages_ms", {}))
	var stage_names := {"1":"发射/武器", "2":"运动", "3":"清空间索引", "4":"构建空间索引", "5":"九色碰撞", "6":"实体事件", "7":"统计", "8":"清画布", "9":"粒子绘制", "10":"画面合成", "11":"间接调度", "12":"池回收", "13":"首碰前缀", "14":"领土事件"}
	if stages is Dictionary:
		for stage: Variant in stages:
			var duration: Variant = stages[stage]
			var completeness := ""
			if duration is Dictionary:
				completeness = " (%s/%s)" % [str(duration.get("measured_dispatches", "?")), str(duration.get("expected_dispatches", "?"))]
				duration = duration.get("gpu_ms")
			var title := str(stage_names.get(str(stage), "阶段" + str(stage)))
			if (duration is int or duration is float) and is_finite(float(duration)):
				text += "\n%s %.3f ms%s" % [title, float(duration), completeness]
			else:
				text += "\n%s：缺测%s" % [title, completeness]
	if profile.has("missing_stage_pairs"):
		text += "\n缺测阶段对 " + str(profile.missing_stage_pairs)
	if int(profile.get("skipped_substeps", 0)) > 0:
		text += "\n另有 %d 微子步未分阶段采样" % int(profile.skipped_substeps)
	if profile.has("reason"):
		text += "\n" + str(profile.reason)
	return text

func show_stage_profile_request(accepted: bool) -> void:
	_notify("已请求阶段采集；等待下个模拟批次，暂停时请继续或单步" if accepted else "采集未提交：GPU未就绪或已有请求等待完成")

func _copy_complete_diagnostics() -> void:
	if diagnostic_provider.is_valid():
		var fresh: Variant = diagnostic_provider.call()
		if fresh is Dictionary:
			update_state(fresh)
	var payload := _diagnostic_payload.duplicate(true)
	var configuration: Dictionary = _diagnostic_state.get("configuration", {})
	if configuration.is_empty():
		configuration = {"desired":_config.duplicate(true), "source":{"desired":"UI configuration only; runtime provider unavailable"}, "gpu_parameters_confirmed":false}
	var submitted: Dictionary = configuration.get("gpu_submitted", {})
	# 顶层名称与旧诊断兼容，渲染尺寸使用本局已提交值，不误报待重开的UI值。
	for key: String in ["particle_capacity", "grid_size", "render_size"]:
		if submitted.has(key):
			payload[key] = submitted[key]
	if submitted.has("friendly_particle_collisions"):
		payload["friendly_particle_collisions"] = submitted["friendly_particle_collisions"]
	payload["diagnostic_schema"] = 2
	payload["capture"] = {"source":"manual_copy", "utc":Time.get_datetime_string_from_system(true), "gpu_readback_requested":false, "automatic_upload":false,
		"gpu_telemetry_sim_time":_diagnostic_state.get("stats", {}).get("sim_time", null)}
	payload["engine"] = {"godot":Engine.get_version_info(), "os":OS.get_name(), "rendering_method":RenderingServer.get_current_rendering_method(), "rendering_driver":RenderingServer.get_current_rendering_driver_name()}
	payload["settings"] = configuration
	payload["runtime"] = _diagnostic_state.get("diagnostic_runtime", {})
	payload["last_stage_profile"] = _diagnostic_state.get("last_stage_profile", {})
	payload["active_team_count"] = _active_team_count
	payload["manual_controls"] = manual_controls_snapshot()
	payload["territory_brush"] = _diagnostic_state.get("territory_brush", {})
	payload["telemetry"] = _diagnostic_state.get("stats", {})
	payload["pinball"] = _diagnostic_state.get("pinball", {})
	payload["error"] = _diagnostic_state.get("error", "")
	payload["encoding"] = {"vectors":"component objects; custom/actual pegs use x,y,z with z=radius in game units", "objects":"font and other engine objects omitted", "nonfinite_numbers":"null", "integers":"decimal JSON integers; use lossless parsing for values above 2^53"}
	_diagnostic_text = JSON.stringify(_json_safe(payload))
	DisplayServer.clipboard_set(_diagnostic_text)
	print("CHROMATIC_DIAGNOSTICS " + _diagnostic_text)
	_notify("已复制完整诊断与配置；未上传")

func _json_safe(value: Variant, depth: int = 0) -> Variant:
	if depth > 20:
		return null
	if value is Dictionary:
		var safe: Dictionary = {}
		for key: Variant in value:
			var entry: Variant = value[key]
			if str(key) == "font" or entry is Object or entry is Callable or entry is Signal or entry is RID:
				continue
			safe[str(key)] = _json_safe(entry, depth + 1)
		return safe
	if value is Array or value is PackedByteArray or value is PackedInt32Array or value is PackedInt64Array or value is PackedFloat32Array or value is PackedFloat64Array or value is PackedStringArray or value is PackedVector2Array or value is PackedVector3Array or value is PackedColorArray:
		var safe_array: Array = []
		for entry: Variant in value:
			if entry is Object or entry is Callable or entry is Signal or entry is RID:
				continue
			safe_array.append(_json_safe(entry, depth + 1))
		return safe_array
	if value is Vector2 or value is Vector2i:
		return {"x":_json_safe(value.x, depth + 1), "y":_json_safe(value.y, depth + 1)}
	if value is Vector3 or value is Vector3i:
		return {"x":_json_safe(value.x, depth + 1), "y":_json_safe(value.y, depth + 1), "z":_json_safe(value.z, depth + 1)}
	if value is Color:
		return {"r":_json_safe(value.r, depth + 1), "g":_json_safe(value.g, depth + 1), "b":_json_safe(value.b, depth + 1), "a":_json_safe(value.a, depth + 1)}
	if value is Rect2 or value is Rect2i:
		return {"position":_json_safe(value.position, depth + 1), "size":_json_safe(value.size, depth + 1)}
	if value is float:
		return value if is_finite(value) else null
	if value is StringName:
		return str(value)
	if value == null or value is bool or value is int or value is String:
		return value
	return null

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
	if index >= _active_team_count or not bool(team.get("enabled", true)):
		_show_disabled_team(index)
		return
	_team_labels[index].modulate = Color.WHITE
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

func set_active_team_count(value: int) -> void:
	var count := clampi(value, 1, 4)
	if count == _active_team_count and _manual_team != null and _manual_team.item_count == count and _brush_team != null and _brush_team.item_count == count:
		return
	_active_team_count = count
	for selector: OptionButton in [_manual_team, _brush_team]:
		if selector == null:
			continue
		var previous := int(selector.get_selected_metadata()) if selector.selected >= 0 else 0
		selector.clear()
		for team: int in count:
			selector.add_item(TEAM_NAMES[team])
			selector.set_item_metadata(team, team)
		selector.select(clampi(previous, 0, count - 1))
	for team: int in _team_labels.size():
		if team >= count:
			_show_disabled_team(team)
		else:
			_team_labels[team].modulate = Color.WHITE

func _show_disabled_team(team: int) -> void:
	_team_labels[team].text = "未参战\n本局不生成核心/武器/弹药球\n阵营数量需新开局生效"
	_team_labels[team].tooltip_text = "本局只启用前%d个阵营" % _active_team_count
	_team_labels[team].modulate = Color(0.55, 0.55, 0.55)

func _parse_manual_energy(raw: String) -> Dictionary:
	var text := raw.strip_edges()
	if text.is_empty():
		return {"ok":false, "error":"请输入十进制正整数能量"}
	for index: int in text.length():
		var digit := text.unicode_at(index)
		if digit < 48 or digit > 57:
			return {"ok":false, "error":"能量只接受十进制数字，不接受负号、小数或指数"}
	var first := 0
	while first < text.length() and text.unicode_at(first) == 48:
		first += 1
	text = text.substr(first)
	if text.is_empty():
		return {"ok":false, "error":"能量必须至少为1，未提交"}
	if text.length() > MAX_MANUAL_ENERGY_TEXT.length():
		return {"ok":false, "error":"能量超过9223372036854775807，未提交；输入未截断"}
	if text.length() == MAX_MANUAL_ENERGY_TEXT.length():
		for index: int in text.length():
			if text.unicode_at(index) > MAX_MANUAL_ENERGY_TEXT.unicode_at(index):
				return {"ok":false, "error":"能量超过9223372036854775807，未提交；输入未截断"}
			if text.unicode_at(index) < MAX_MANUAL_ENERGY_TEXT.unicode_at(index):
				break
	# 长度和逐字符上界已检查，只有这里才转换，绝不先经过float或有溢出风险的int。
	return {"ok":true, "energy":text.to_int()}

func _submit_manual_weapon() -> void:
	var parsed := _parse_manual_energy(_manual_energy.text)
	if not bool(parsed.ok):
		show_manual_feedback(str(parsed.error))
		return
	var team := int(_manual_team.get_selected_metadata()) if _manual_team.selected >= 0 else -1
	if team < 0 or team >= _active_team_count:
		show_manual_feedback("未选择本局参战阵营，未提交")
		return
	manual_weapon_requested.emit(team, _manual_weapon.selected, int(parsed.energy))

func show_manual_feedback(message: String) -> void:
	if _manual_status != null:
		_manual_status.text = message
	_notify(message)

func _emit_brush_settings() -> void:
	if _brush_toggle == null or _brush_team == null or _brush_radius == null:
		return
	var team := int(_brush_team.get_selected_metadata()) if _brush_team.selected >= 0 else 0
	territory_brush_changed.emit(_brush_toggle.button_pressed, team, _brush_radius.value)

func set_territory_brush_enabled(enabled: bool) -> void:
	if _brush_toggle != null:
		_brush_toggle.set_pressed_no_signal(enabled)

func territory_pointer_blocked(screen_position: Vector2) -> bool:
	# 全屏根与战场TextureRect都设置为IGNORE，不把它们误认为挡笔控件。
	for panel: Control in [_panel, _details_panel]:
		if panel != null and panel.is_visible_in_tree() and panel.get_global_rect().has_point(screen_position):
			return true
	var hovered := _root.get_viewport().gui_get_hovered_control()
	return hovered != null and hovered != _root and hovered.mouse_filter != Control.MOUSE_FILTER_IGNORE

func manual_controls_snapshot() -> Dictionary:
	return {"active_team_count":_active_team_count,
		"maximum_manual_energy":MAX_MANUAL_ENERGY_TEXT, "manual_energy_encoding":"exact int64; normal pinball float output remains separate",
		"weapon_team":int(_manual_team.get_selected_metadata()) if _manual_team != null and _manual_team.selected >= 0 else -1,
		"weapon_kind":_manual_weapon.selected if _manual_weapon != null else -1,
		"weapon_energy_input":_manual_energy.text if _manual_energy != null else "",
		"territory_brush_enabled":_brush_toggle != null and _brush_toggle.button_pressed,
		"territory_brush_team":int(_brush_team.get_selected_metadata()) if _brush_team != null and _brush_team.selected >= 0 else -1,
		"territory_brush_radius":_brush_radius.value if _brush_radius != null else 0.0}

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
