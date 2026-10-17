# 颜色大战 · 1.5.2-continuous-territory

- [Windows版下载](ChromaticWars-Windows-x64-Continuous-Territory.zip)：完整解压后运行 `颜色大战.exe`，无需安装Godot。
- [Godot源码下载](ChromaticWars-Godot-Source-Continuous-Territory.zip)：用Godot4.6.3标准版导入 `ChromaticWars/project.godot`。
- [直接阅读源码](../../chromatic-wars/)、[本版构建与历史测试报告](../../chromatic-wars/TEST_REPORT.md)。
- [构建信息及源码哈希](BUILD-Continuous-Territory.json)、[交付清单](MANIFEST-Continuous-Territory.json)、[下载校验](SHA256SUMS.txt)。

本版采用有限半径连续扫掠染地，每次实际改变非己方格子归属扣1整数能量，余能继续；首接触前缀避免首次实体抵消时遗漏碰前染地。真实弹道间仍可能有空隙，后续碰撞链也尚非全局连续事件排序。

狙击弹实际宽度随能量有界增长，主弹使用白芯长尾，次级弹使用阵营色短尾；宽弹使用独立空间查询。紧急保命补盾不再在生效当步被扩张染地耗尽，新增保命结果提示。机枪清理失效威胁，限制补地时的固定朝向停留，在锁定/补地时逐发小角度扫射，保持射速和补弹后10模拟秒的整数库存分配。

**按用户“修改但不测试”的要求，本版只修改与导出构建，没有启动游戏、运行CPU/GPU测试、性能测试或加载Windows内嵌PCK。** 包中的1.5.1及更早测试均为历史，不能作为1.5.2结果。不承诺帧率或RTX5060Ti表现，已知限制详见报告。

友方碰撞开关、预设/自定义固定柱增删与保存、倍率通道宽度、基地位置和护盾宽度设置均保留。未降低领土或画面分辨率。

历史版本供回退：[1.5.1 Windows](ChromaticWars-Windows-x64-Validated.zip)、[1.5.1源码](ChromaticWars-Godot-Source-Validated.zip)。该版本也有未完成验收项，见其包内报告。
