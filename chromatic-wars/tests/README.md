# 实际运行验证

Python启动器只负责启动Godot、截止时间和真实断言收集；无断言、引擎错误、崩溃和超时均不能报告通过。

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 tools/run_tests.py --godot /路径/Godot --suite all --duration 1800 --timeout 1800
python3 tools/run_tests.py --godot /路径/Godot --suite stress --timeout 1800
python3 tools/run_tests.py --godot /路径/Godot --suite battle --duration 1200 --speed 1 --wall-seconds 3600 --timeout 3900
```

`all`包括设置、通道底墙、CPU长局、弹球属性、GPU碰撞/能量、武器和基础GPU回归。`stress`、`battle`须显式选择。CPU/设置套件使用headless；GPU套件必须普通窗口Forward+ / Vulkan，不能用headless假代替。Linux可用现成DISPLAY或`--wrapper 'xvfb-run -a'`。Xvfb仅提供显示服务；仍须有Vulkan。软件Vulkan结果不代表RTX 5060 Ti实际性能。

结果保存在`artifacts/tests/<UTC时间>/`：原始`.log`、`results.json`、`REPORT.md`。退出码0为所请求范围通过，1为失败，77为含未测试项目。每项断言均输出`CHROMATIC_TEST` JSON。正式遥测和性能矩阵只读小表/有限采样；物理规则测试的独立小夹具<=4096槽显式使用all_particles调试读回核对全部状态，防止free pool复用非前64物理ID造成遗漏。规则测试的调试读回成本不用于性能对比。

`tools/validation_matrix.gd`使用可复制到旧项目的同一确定性初始条件夹具，正式Compute负责所有后续运动和碰撞。矩阵包括1000/5000/10000/30000/50000/100000活跃粒子、相同1000或10000活跃而容量10k/100k/1M的对照，以及密集交汇、高速狙击、四队风暴。所有档位保持512领土格、768渲染像素、相同固定步长和同阵营碰撞，机枪显式`gun_rate=0`。均匀场景将另外三个核心置死，避免长采样意外核心命中改变活跃数量；物理碰撞仍启用。

```bash
Godot --path . --rendering-method forward_plus --rendering-driver vulkan --audio-driver Dummy --script res://tools/validation_matrix.gd -- --samples 60 --warmup 10 --profiling false --json res://artifacts/validation/formal.json
Godot --path . --rendering-method forward_plus --rendering-driver vulkan --audio-driver Dummy --script res://tools/validation_matrix.gd -- --cases uniform:10000:10000,dense_crossing:1000:10000 --samples 12 --warmup 3 --profiling true --json res://artifacts/validation/counters.json
```

优化对比主矩阵必须`profiling=false`，避免新版本原子计数开销造成不公平。另行短测开启计数，报告实际候选/接触；旧版没有候选计数时使用null。每批4字节异步完成栅栏，只在初末读小表。逐批匹配GPU timestamp，按pass记录运动、空间索引、9色碰撞、串行事件、绘制。报告真实drawn FPS均值/1% low、p50/p95/p99帧时间，也分别报告完成固定物理步的吞吐。异步等待期间视口仍可重绘，drawn FPS不能等同于模拟FPS。主线程排队、渲染线程提交CPU时间、异步完成等待墙钟时间分别记录；后者包括驱动/调度延迟，不能称精确CPU-GPU同步时间。分配字节是应用缓冲区/纹理大小，不能冒称物理显存驻留。

冻结baseline和修改后必须使用完全相同夹具、采样、地图、分辨率、时间步长、发射模式、后端、CPU affinity和线程数。共享主机调度波动在原始样本中保留，不用短样本的中位数宣称精确优化百分比。

`battle`保持真实10000容量、512领土格、768渲染像素和正式弹药成本，绘制左右系统。`--speed 1/2/4`是按真实时钟累积的目标倍率；软件设备追不上时不跳过固定物理。达到wall budget但未达到目标模拟时长时报告NOT TESTED，并记录实际时长。最终小表GPU完成栅栏避免把CPU排队时间冒称已完成GPU对局。禁止再以旧64格地图/4096能量包小规模长局冒充默认对局。
