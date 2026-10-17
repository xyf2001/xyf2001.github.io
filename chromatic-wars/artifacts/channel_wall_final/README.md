# 1.1.1-channel-wall 证据版本范围

最终源码与构建的验收记录：
- `tests/channel-floor-verified`：最终27项专项物理回归。
- `tests/channel-floor-export`：工程外装载最终EXE内嵌PCK，同样27项物理回归。
- `tests/channel-wall-verified-cpu`：最终源码CPU持续物理测试。
- 本目录`export_pck.json/png`与`export_pck_channel_wall_final.log`：最终导出资源、Compute启动与画面。

中间记录保留，不能冒充最终验收：
- `channel-floor-before`：无底墙旧版，初始21项中12项失败。
- `channel-floor-after`：仅加普通底墙，初始单球21项通过；尚未覆盖双球挤压。
- `channel-floor-pair-before`：首次双球检查，包含一条正常回流误报。
- `channel-floor-caps-only-baseline`：相同最终夹具针对仅加普通底墙中间代码；4项失败、31条逆入轨迹。两份中间脚本保存为本目录`caps_only_baseline_*.gd.txt`。
- `channel-floor-final`：接触侧修复后使用了过严的“任何倍率都失败”断言；4个高速球绕回上方、向下正常入槽被误判。`normal_top_entry_trace.log`记录触发前实际位置约y371–372、速度向下，证实属于正常入口；正式夹具允许这种合法路径。
- `channel-wall-cpu`：仅普通底墙中间代码的19项CPU长局通过，不能替代最终源码测试。
- `channel-wall-final-cpu`：专项测试定位上述4个误报期间主动取消，Godot退出-15，不是最终验收失败。
- `channel_wall_release`、无`_final`后缀的本轮导入/导出/PCK日志：普通底墙中间构建；其中`release_scope.json`对最终两脚本范围仍适用。

最终双球检查在正式触发信号发出、顶部重生之前观察实际位置与速度，不读取`step_origin`或底墙内部几何。来自上方入口附近并向下运动的球允许倍率；首次正常底部输出后结束该夹具，避免把重生后活动混入原来的逆入检查。
