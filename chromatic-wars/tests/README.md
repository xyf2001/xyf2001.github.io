# 可重复的真实运行测试

在项目根目录运行，Python仅负责启动Godot、硬截止、收集真实断言与保存日志：

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 tools/run_tests.py --godot /实际路径/Godot --suite cpu --duration 1200 --timeout 900
python3 tools/run_tests.py --godot /实际路径/Godot --suite gpu --timeout 180
python3 tools/run_tests.py --godot /实际路径/Godot --suite stress --timeout 300
python3 tests/check_output_log.py artifacts/tests/实际时间/cpu.log --output artifacts/tests/实际时间/physical_outputs.json
```

Windows可用`python tools/run_tests.py --godot "C:/Godot/Godot_v4.6.3-stable_win64_console.exe"`。CPU套件使用无窗口模式；GPU与压力套件必须实际普通窗口Forward+/Vulkan。Linux可用现成DISPLAY，或`--wrapper "xvfb-run -a"`；Xvfb只是显示服务，仍须具备可用Vulkan实现。软件Vulkan的结果不能代表真实显卡帧率。

结果位于`artifacts/tests/<UTC时间>/`：原始`.log`、`results.json`、`REPORT.md`，GPU套件另存实际视口截图`gpu_initial.png`。退出码0表示请求范围内通过，1表示失败（包括无断言、崩溃、超时、脚本错误），77表示仍含NOT TESTED。6个Python测试专门验证不会把空测试、跳过或引擎失败误报为PASS。

CPU默认主种子1200模拟秒，另外两个种子各120秒。`--duration 120`可以缩短为三次120秒回归；这个结果不能证明20分钟长局。套件分别记录120次人工坐标/相位输入与至少100次正式物理落槽日志，二者明确区分。物理模块的显式故障（例如超过可精确表示范围）也会使有限值检查失败。每60模拟秒打印真实进度与最大速度，便于区分慢模拟与卡死。

GPU规则测试用真实Compute执行注入、移动、空间分区、碰撞、染色、护盾和保命握手。CPU只在这些独立测试中读取最多64个普通粒子、64个大球、少量团队状态与地块，并对照独立能量守恒公式；它不构成游戏的CPU回退路径。截图是单次Debug视口取图，正式游戏渲染不调用该路径。

压力测试实际填满10k、50k、100k粒子，每档运行12个完整固定物理步，记录活跃数量、能量、碰撞格占用、溢出、观测视口FPS、GPU耗时和显存缓冲/纹理估计。测试场景是均匀同队二维点阵；它验证实际容量及基础吞吐，不证明密集多队战局60 FPS。默认明确将300k、1M标为NOT TESTED，可在有足够性能的真实显卡上加`--capacity 300000`或`--capacity 1000000`实际测试对应档位。

自动脚本不能替代Windows实际启动/导出、完整GPU对局20–30分钟、多种子整局、交互观感和长期显存泄漏人工验收。请在`TEST_REPORT.md`逐项记录这些项目的实际状态，不可用CPU长局或短GPU规则测试替代。
