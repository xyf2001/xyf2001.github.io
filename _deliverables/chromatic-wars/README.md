# 颜色大战 · 1.5.1-energy-magazine

- [Windows版下载](ChromaticWars-Windows-x64-Validated.zip)：下载后完整解压，双击`颜色大战.exe`，无需安装Godot。
- [Godot源码下载](ChromaticWars-Godot-Source-Validated.zip)：完整可编辑工程，用Godot4.6.3标准版导入`ChromaticWars/project.godot`。
- [直接阅读源码](../../chromatic-wars/)及[实际测试报告](../../chromatic-wars/TEST_REPORT.md)。
- [构建信息与源码哈希](BUILD-Validated.json)、[交付清单](MANIFEST-Validated.json)、[下载文件校验](SHA256SUMS.txt)。

本版删除随时间增长的发射成本。机枪固定射速，每次补弹将剩余库存加新输入均匀分配到接下来10模拟秒，弹药越多、每发越强；整数余数均匀分散，补弹不重置射击相位和瞄准。普通高能粒子、狙击和大球每染格只消耗1能量，余能继续。友方真实碰撞、敌方64位等量抵消、大球碰前质量和部分损耗、最多3圈风暴、三级狙击及护盾逐格扩张均保留。预设固定柱可添加、删除、恢复并保存。GPU活跃ID与间接调度减少空池扫描，没有降低地图或渲染分辨率。

机枪目标切换CD默认0.5模拟秒，有效目标持续追踪，失效立即重选；槽位代号防止重生实体被当作旧目标。狙击70/30的分配对象仍待确认，当前暂保留开发稿父/子分配；整数守恒通过不代表该语义已经确认。

本轮实际运行规则、接触、活跃池、左侧多种子长模拟、容量/活跃规模性能及主场景验证。云端使用Linux/llvmpipe软件Vulkan；Windows导出文件由Linux Godot验证内嵌资源，**不能代替Windows系统或RTX5060Ti实机测试，也不保证60FPS**。完整长局、倍速及导出各项实际结论以包内`TEST_REPORT.md`和`BUILD_INFO.json`为准；未完成项不会标为通过。

满物理池仍会保留弹药等待空槽，背压或人工停火会延长名义10秒发完时长；库存不足射击槽数时有稀疏空槽。极密真实碰撞和串行事件仍是性能限制。宽球在倍率入口静态搭桥时需要保值防卡，不能宣称所有卡球已消除。RTX5060Ti建议从默认1万容量、512²领土、768²画面、1/120固定步、友方碰撞开启开始，再按诊断提高容量和画面尺寸，见包内`docs/RTX5060Ti验收建议.md`。

旧版保留供回退：[1.4.3 Windows](ChromaticWars-Windows-x64-Air-Aim.zip)、[1.4.3源码](ChromaticWars-Godot-Source-Air-Aim.zip)。旧版按当时要求没有运行测试，历史记录不代表本版结果。
