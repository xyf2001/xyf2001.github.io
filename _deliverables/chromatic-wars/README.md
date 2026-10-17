# 颜色大战 · 1.5.4-active-cells-rescue

- [Windows版下载](ChromaticWars-Windows-x64-Active-Cells-Rescue.zip)：完整解压后运行 `颜色大战.exe`，无需安装Godot。
- [Godot源码下载](ChromaticWars-Godot-Source-Active-Cells-Rescue.zip)：用Godot4.6.3标准版导入 `ChromaticWars/project.godot`。
- [源码](../../chromatic-wars/)、[修改与限制](../../chromatic-wars/docs/性能与救援1.5.4.md)、[构建/历史测试报告](../../chromatic-wars/TEST_REPORT.md)。
- [构建信息](BUILD-Active-Cells-Rescue.json)、[交付清单](MANIFEST-Active-Cells-Rescue.json)、[下载校验](SHA256SUMS.txt)。

九色碰撞只调度实际占据的普通网格，省去空格及不可能接触的精确查询、重复求根/归一化和小块命令上传；碰撞规则、粒子数、物理步和分辨率保留。新增默认关闭的手动GPU阶段采集，便于实机定位余下瓶颈。

紧急保命使用独立快速异步事件与立即补盾提交，不等待普通UI统计；救援能量保留防御储备，正常扩张不会提前耗掉。仍受GPU队列延迟和后续真实攻击影响。

参数设置新增1～4队（新开局生效）、人工领土画笔、指定阵营/武器的一次性int64能量输入。画笔开启后暂停，收起面板后在右侧左键拖动，右键退出；手动武器输入不自动重复。详见包内README。

**按用户要求，本版只修改与导出构建，没有启动游戏或执行CPU/GPU、性能、长局和Windows内嵌PCK运行测试。** 没有本版RTX5080同条件帧率结果，不宣称性能提升比例；构建成功不代表运行通过。旧版证据不能作为1.5.4通过。

保留[1.5.3 Windows](ChromaticWars-Windows-x64-GPU-Kernels.zip)、[1.5.2 Windows](ChromaticWars-Windows-x64-Continuous-Territory.zip)、[1.5.1 Windows](ChromaticWars-Windows-x64-Validated.zip)供回退。
