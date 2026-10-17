# 颜色大战 · 1.5.3-gpu-kernels

- [Windows版下载](ChromaticWars-Windows-x64-GPU-Kernels.zip)：完整解压后运行 `颜色大战.exe`，无需安装Godot。
- [Godot源码下载](ChromaticWars-Godot-Source-GPU-Kernels.zip)：用Godot4.6.3标准版导入 `ChromaticWars/project.godot`。
- [直接阅读源码](../../chromatic-wars/)、[构建与历史测试报告](../../chromatic-wars/TEST_REPORT.md)、[本次GPU调整](../../chromatic-wars/docs/GPU管线1.5.3.md)。
- [构建信息和源码哈希](BUILD-GPU-Kernels.json)、[交付清单](MANIFEST-GPU-Kernels.json)、[下载校验](SHA256SUMS.txt)。

本版针对1.5.2新增的GPU开销，将各阶段改为专用Compute管线；首接触几何查询并行，屏障后按原顺序单写者染地及能量扣账。省去全己区域的精确扫描，以及高能实体不可能耗尽时的重复排序扫描；低能段保留TOI顺序。未降低地图或画面分辨率，未关闭碰撞规则。

新增右侧“复制完整诊断与配置”，点击后把全部当前设置和已有遥测复制到本机剪贴板并记录在本地日志，区分当前生效、已提交与等待新开局参数，不自动上传、不额外读回GPU。默认改为真正1倍速，旧未标记0.25倍速首次升级迁移为1倍速；用户之后仍可选择并保存慢速。计算能及时完成时1现实秒对应1模拟秒，积压时仍保留固定步。

**按用户“修改但不测试”的要求，本版只修改与导出构建，没有启动游戏或执行CPU/GPU、性能、长局和Windows内嵌PCK运行测试。** 用户给出的RTX5080、2067粒子、4FPS/174ms是1.5.2单次反馈，不是云端基准；没有新版同条件结果或可宣称的性能提升比例。包内旧测试不能作为1.5.3通过。

此前连续染地、狙击主次弹宽度/尾迹、紧急保命、机枪微扫、10模拟秒补弹、固定柱编辑与其他规则保留。详细限制见报告。

历史回退：[1.5.2 Windows](ChromaticWars-Windows-x64-Continuous-Territory.zip)、[1.5.2源码](ChromaticWars-Godot-Source-Continuous-Territory.zip)、[1.5.1 Windows](ChromaticWars-Windows-x64-Validated.zip)。旧版仍有各自未完成验收项。
