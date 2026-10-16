# 颜色大战 · 实际测试报告

## 当前发布：1.4.3-air-aim（未测试）

按用户要求，本轮没有启动游戏或执行CPU/GPU规则、交互、性能、PCK运行测试。仅修改源码、静态审阅、资源导入、Windows导出与打包。改动包括出生门槛关联的左球质量/空气阻力、缩短保值防卡、机枪取消角度保持并以并行摘要索敌、模拟秒和游戏单位统一、实时己方普通粒子碰撞开关。有限空气推力不能保证任意自定义布局/高速撞击下小球绝不穿过；防卡误判率、转向手感、开关交互及实体显卡FPS均未经运行验证。导出日志属于构建证据；历史PASS不代表此版本。

## 历史发布：1.4.2-motion（未测试）

按用户要求，本轮未启动游戏、执行规则/交互/性能或PCK运行测试；仅源码审阅、资源导入、Windows导出与打包。针对用户反馈停弹、角落堆积和大球停住，改为每颗小粒子保持出生速率、补充碰撞后墙约束并增加大球最低移速。普通一粒一格与狙击/大球当前成本规则保持。实际前线染色速度、密集角落运动和FPS尚未运行验证，历史PASS不代表本轮。

## 历史发布：1.4.1-continuous-gun（未测试）

按用户要求，本轮未启动游戏、运行规则/场景/交互/性能或PCK测试；仅修改源码、静态审阅、资源导入与Windows导出打包。机枪改为固定高射速、逐发连续角度和首步时长；狙击只取消粒子物理偏转；狙击及大球染格改为当前粒子成本。实际连续弹幕观感、密集同色碰撞影响、平衡数值及FPS均未经运行验证，不能把历史PASS视为本轮通过。

## 历史发布：1.4.0-physics-rings（未测试）

按用户要求，本轮仅修改源码、静态审阅、导入资源和导出Windows包；没有运行游戏、CPU/GPU规则、场景交互、性能测量或内嵌PCK运行验证。新成本、环形风暴、机枪、大球部分消耗/吸收、同色碰撞、左侧防卡与预设固定柱编辑均尚未经过运行验证。平衡参数是待实机微调的初值，不能承诺RTX 5060 Ti帧率；下方旧测试属于旧规则，未更新为本轮新机制的验收。

## 历史发布：1.3.0-sandbox（未测试）

按用户持续要求，本轮没有运行CPU/GPU规则、场景、交互、性能或PCK运行测试；仅修改代码、导入资源、导出Windows并打包。新增飞行高能弹、阵营分链性能改动、固定柱/倍率宽度/基地位置/护盾上限编辑及流畅预设。下文所有测试结论均为历史版本记录，不代表当前构建。

## 历史发布：1.2.0-beam（未测试）

按用户明确要求，本轮仅修改、构建并打包，未运行CPU/GPU测试、场景烟雾检查或导出PCK运行验证。取消同阵营战场粒子及大球碰撞，狙击改为0.65模拟秒充能后的单次光束与0.18秒闪光。资源导入和Windows导出属于构建步骤，不代表运行验证。

下文全部为历史版本记录，包含上版底墙回归；不得把这些PASS归于当前构建。当前构建的`BUILD_INFO.json`将验证状态记为NOT TESTED。

测试日期：2026年10月16日（北京时间）。本报告区分真实执行的断言、源码审查结论及尚未执行的验收；**目前未达到用户全部完成定义**。

## 本轮发布范围：1.1.1-channel-wall倍率槽底墙

本轮仅给六个倍率槽增加实体底墙：左右各一段8px底座，与竖隔板连接，中央98px通路保持开放。底墙同时约束球球位置修正，保留每个物理子步开始时的接触侧，防止下方大球把小球挤过墙中线后向上解嵌。没有修改倍率判定、倍率数值、顶部重生规则、气流、GPU战场或性能设置。

| 本轮验证 | 结果与范围 | 证据 |
| --- | --- | --- |
| 专项物理回归 | PASS：27项，包含216组单球逆入、324组双球挤压、6处接缝、6个正常倍率入口、3种半径中央通行 | [原始日志](artifacts/tests/channel-floor-verified/channel_floor.log)、[结果](artifacts/tests/channel-floor-verified/results.json) |
| 导出包内物理回归 | PASS：工程外加载实际Windows EXE的内嵌PCK，重复27项；使用Linux引擎，不是Windows系统执行 | [日志](artifacts/tests/channel-floor-export/channel_floor.log)、[结果](artifacts/tests/channel-floor-export/results.json) |
| 原有CPU持续物理测试 | PASS：19项；主种子1200模拟秒，另两个种子各120秒；16球完整、1547次底部输出、11063次倍率，最长无进度37秒；真实耗时406.885秒 | [原始日志](artifacts/tests/channel-wall-verified-cpu/cpu.log)、[本次结果](artifacts/tests/channel-wall-verified-cpu/results.json)、[逐项记录](artifacts/tests/channel-wall-verified-cpu/REPORT.md) |
| 导入、Windows导出及内嵌资源启动 | PASS：退出0，无脚本/着色器错误；共享纹理、开局、实际Compute推进和画面采样通过 | [导入](artifacts/import_channel_wall_final.log)、[导出](artifacts/windows_export_channel_wall_final.log)、[PCK日志](artifacts/export_pck_channel_wall_final.log)、[结果](artifacts/channel_wall_final/export_pck.json)、[画面](artifacts/channel_wall_final/export_pck.png) |
| 运行源码范围 | PASS：与上一版18个运行文件逐项比对，仅两份底墙相关脚本及项目版本号改变 | [范围检查](artifacts/channel_wall_release/release_scope.json) |

回归有效性：原版无底墙时，初始21项夹具出现12项失败；仅加入普通底墙、未处理球球挤压的中间方案，在最终相同27项夹具下仍有4项失败、31条逆入轨迹。最终底墙实现27项全部通过。双球夹具保留默认柱子和气流、无初始重叠；高速球从中央绕回上方后正常向下入槽属于合法倍率，不能判为穿墙。

中间测试和取消记录保留，版本范围及一次过严断言修正见[本轮证据说明](artifacts/channel_wall_final/README.md)。Windows实体系统、RTX 5060 Ti和新版完整GPU长局本轮未测；上一版GPU与性能记录继续按其版本阅读，不冒充本轮重跑。

## 上一版发布范围：1.1.0-perf1性能修复版

本报告包含两个版本的证据。**初版**是 GitHub 下载提交 `330d8788cd959786dd50e2acbc7448a2ef5f18bb` 中的交付工程；**本轮性能修复版**在该基础上修正空间分区、满容量发射和空大球槽扫描，增加真实设备诊断。未注明新版重跑的历史 PASS 只适用于初版，不能自动升级成新版验收。

用户反馈：RTX 5060 Ti、0.25×速度，真实风暴后约2 FPS。此项为用户运行反馈，云端无法代用户测量该显卡。当前不保证新版 Windows 达到60 FPS。

| 本轮验证项 | 当前状态 | 本轮证据或范围 |
| --- | --- | --- |
| GPU规则36项 | PASS：本轮实际执行36项通过 | [原始日志](artifacts/tests/performance-final-rules/gpu.log)、[结构化结果](artifacts/tests/performance-final-rules/results.json)、[逐项断言](artifacts/tests/performance-final-rules/REPORT.md) |
| 参数/UI规则5项 | PASS：本轮5项实际通过 | [本轮参数断言](artifacts/tests/performance-settings/REPORT.md)、[结构化结果](artifacts/tests/performance-settings/results.json) |
| 主场景5秒、Windows导出PCK资源 | PASS：重新导入/导出退出0；5模拟秒、暂停/单步及嵌入SPIR-V运行通过 | [主场景日志](artifacts/visual_smoke_performance_release.log)、[PCK日志](artifacts/export_pck_performance_release.log)、[PCK结果](artifacts/performance_release/export_pck.json)；不等于Windows实体系统测试 |
| 最终真实风暴剖析 | PASS：实际达到1万活跃、3次短采样、总能量840万守恒且溢出0 | [真实风暴结果](artifacts/storm_profile_final.json)、[对照汇总](artifacts/storm_profile_final_summary.md)；分段剖析有调度开销，不是RTX FPS |
| 最终均匀点阵匹配batch夹具 | NOT TESTED：最终方案未重跑 | 旧`perf_after_matched`只属于已撤回中间方案；最终改进证据为上述真实风暴剖析 |
| CPU19项与1200模拟秒低配置双系统长局 | HISTORICAL PASS：初版已测，本轮未重跑 | 历史C及`final-battle-1200`；不能宣称本轮已重跑20分钟 |
| Windows / RTX 5060 Ti新版实机、默认精确模式20–30分钟 | NOT TESTED | 仍需用户目标设备及默认配置验收 |

本轮最终方案采用8px空间格、128²格头、9个phase的紧凑中心调度；CCD每子步位移限制为`min(4, (8 - 2r) / 2)`，默认半径1.2、狙击速度620仍为每固定步2个GPU子步。满容量失败扫描在每次prepare内缓存；大球仅遍历两个uint组成的实际活跃掩码，保持ID顺序。正式领土计数在初始化、claim和调试染色时增量维护；普通粒子总量仅在低频或显式dirty快照前通过单invocation统计，不再为读UI统计整张领土地图。**初次并行统计方案已因软件Vulkan实测退化撤回。** 更完整的版本与证据说明见[性能修复记录](docs/性能修复记录.md)。

以下历史验收表保留已有测试与失败，按其明确版本范围阅读；最终版结果不得从旧性能记录中挑选正向数字替代。

右侧已实际运行 RenderingDevice Compute 管线，并通过主 RenderingDevice 的 `Texture2DRD` 显示领土、粒子、护盾与移动大球。正式模拟没有 CPU 逐粒子循环，也没有整帧 GPU→CPU→GPU 绘制路径。这里验证的是实现路径及软件 Vulkan 的实际执行：云机使用 **llvmpipe 软件 Vulkan**，不能把这些结果称为 Windows 实体显卡实测或60 FPS保证。

## 1. 测试环境与结果范围

| 项目 | 实际环境 |
| --- | --- |
| 系统 | Debian GNU/Linux 13，5 vCPU |
| 引擎 | Godot 4.6.3-stable，官方构建 `7d41c59c4`，标准版 |
| 图形 | Forward+ / Vulkan 1.4.305；`llvmpipe (LLVM 19.1.7, 256 bits)` |
| 驱动 | Mesa 25.0.7；软件实现，没有 Windows 实体显卡 |
| 窗口 | Linux 显示服务；CPU规则测试使用 headless，GPU规则与画面测试使用普通 Vulkan 窗口 |
| 默认游戏配置 | 16颗左球、1万普通粒子槽、512²领土、768²输出、逐粒子精确发射、1/120秒固定步长、0.25×目标速度 |
| 能量范围 | GPU累计上限2^63−1；CPU单笔输出精确上限2^53−1，超限停止并提示 |

PASS只表示对应输入、时长和断言实际通过。NOT TESTED表示未执行或现有检查不足以覆盖整项。

## 2. 可核对的实际证据与版本

| 编号 | 实际执行与结论 | 原始证据 |
| --- | --- | --- |
| C | 初版330d878：CPU规则19项PASS；主种子20261016运行1200模拟秒，20261017、20261018各120秒，共1440模拟秒；运行305.256真实秒；1340次真实物理落槽、10301次倍率；最长无进度45.992模拟秒 | [CPU原始日志](artifacts/tests/20261016T050746410355Z/cpu.log)、[结构化结果](artifacts/tests/20261016T050746410355Z/results.json)、[逐项断言](artifacts/tests/20261016T050746410355Z/REPORT.md) |
| G | 本轮性能修复版：真实Compute规则36项PASS，包括8px高速相向狙击不漏碰、64位能量进位/分类及四队不等领土增量计数 | [本轮GPU原始日志](artifacts/tests/performance-final-rules/gpu.log)、[结构化结果](artifacts/tests/performance-final-rules/results.json)、[36项断言](artifacts/tests/performance-final-rules/REPORT.md) |
| P1 | 本轮性能修复版：参数/UI规则5项PASS，默认精确模式与离散时间设置未通过降低精度放宽 | [参数原始日志](artifacts/tests/performance-settings/settings.log)、[5项断言](artifacts/tests/performance-settings/REPORT.md) |
| V1 | 本轮性能修复版：完整主场景5模拟秒PASS；实际共享纹理，暂停冻结，单步恰好1/120秒 | [主场景日志](artifacts/visual_smoke_performance_release.log)、[状态快照](artifacts/performance_release/visual_smoke.json)、[初始截图](artifacts/performance_release/01_初始四象限.png)、[运动截图](artifacts/performance_release/02_运动大球与粒子.png) |
| E1 | 本轮性能修复版：Godot资源导入、Windows导出退出0，无脚本/着色器错误；工程外加载内嵌PCK实际PASS | [导入日志](artifacts/import_performance_release.log)、[Windows导出日志](artifacts/windows_export_performance_release.log)、[PCK日志](artifacts/export_pck_performance_release.log)、[PCK状态与SPIR-V证据](artifacts/performance_release/export_pck.json)、[实际截图](artifacts/performance_release/export_pck.png) |
| G0 | 初版330d878：真实Compute规则32项PASS；包含快照同步、死队输出拒绝、混合精度标识，以及定时命令不提前/不丢失、批末大球出生时刻和1200秒附近时间精度4项回归 | [初版GPU原始日志](artifacts/tests/timed-output-after/gpu.log)、[结构化结果](artifacts/tests/timed-output-after/results.json)、[32项断言](artifacts/tests/timed-output-after/REPORT.md) |
| S | 初版330d878：10k/50k/100k各实际填满并运行12步，6项PASS；300k/1M为NOT TESTED，因此该套件总状态为NOT TESTED、退出码77 | [压力原始日志](artifacts/tests/20261016T050541811320Z/stress.log)、[结构化性能数据](artifacts/tests/20261016T050541811320Z/results.json) |
| V | 初版330d878：完整主场景5模拟秒，明确调试发射大球/风暴/狙击；实际共享纹理和截图；暂停停止模拟，单步恰好增加1/120秒 | [主场景日志](artifacts/visual_smoke_final.log)、[状态快照](artifacts/visual_smoke.json)、[初始画面](artifacts/01_初始四象限.png)、[运动大球与粒子](artifacts/02_运动大球与粒子.png) |
| L | 初版330d878：同帧连续3次快速重开后四核心与16球复位、旧节点数为0；实际倍率超2^53−1保留原值、阻止继续/单步并显示中文原因 | [生命周期与超限日志](artifacts/lifecycle_overflow_final.log)、[重开状态与资源观测](artifacts/lifecycle_smoke.json) |
| U | 初版330d878：使用Compatibility / OpenGL时，明确拒绝不支持的图形模式；中文错误可见、模拟时间为0、未回退CPU战场 | [最终不支持图形模式日志](artifacts/unsupported_gpu_delivery.log) |
| P | 初版330d878：参数/UI验证5项PASS：UI/物理边界一致、离散时间设置合法化、拒绝NaN/无穷、精确发射包能量为1、重开初始化期间等待新GPU状态而不沿用上局淘汰/库存卡 | [参数原始日志](artifacts/tests/20261016T054225848796Z/settings.log)、[逐项断言](artifacts/tests/20261016T054225848796Z/REPORT.md) |
| R | 初版330d878：测试收集器6项Python测试PASS：失败、无断言、进程错误、跳过、非结构化输出、超时均不会被误报为PASS | [Python测试日志](artifacts/test_runner_unit.log) |
| I | 初版330d878：源工程副本不复制.godot，干净导入退出0（27.857真实秒），无脚本/着色器/解析错误；随后独立用户目录启动10帧退出0（12.264秒），实际打印GPU共享纹理绑定完成；源文件哈希一致 | [干净导入与启动原始日志](artifacts/source_clean_import.log) |

L和U中的引擎`ERROR`是主动触发的预期故障，测试检查的是失败能否被正确报告和阻止继续模拟；这不代表这些场景正常运行。普通GPU规则运行的引擎错误检查独立执行。

### 本轮导出与主场景范围

新版工程资源导入与Windows x64导出均退出0。Linux Godot从工程外直接加载导出EXE的内嵌PCK，没有依赖源工程`--path`：GLSL原文不存在，实际加载`RDShaderFile`内嵌SPIR-V，编译错误为空。四队存活、盾枪各精确1M、16颗左球、共享纹理及四区像素正确；GPU推进到0.058333模拟秒时实际活跃8粒子。独立主场景烟测另实际完成5模拟秒，暂停冻结，单步增量0.008333秒。证据见E1/V1。**这两项只证明短烟测和跨平台导出资源可用，未在本轮重跑20分钟，也不等于Windows/RTX实体设备验证。**

### 初版导出资源与1200秒对局（历史证据）

- **初版PASS：Windows EXE实际导出，且内嵌PCK资源运行通过。** 资源重新导入后无脚本/着色器错误；导出的PE32+ x86_64包含字体许可。Linux Godot从工程外以`--main-pack`直接装载该EXE，没有传源工程`--path`。实际使用`RDShaderFile`内嵌SPIR-V（GLSL原文不存在），四核心存活、盾枪各1M、16颗左球、四区各25%、共享纹理有效；推进到0.075模拟秒后GPU活跃12粒子，截图像素四象限正确。见[重新导入日志](artifacts/import_delivery.log)、[最终导出日志](artifacts/windows_export_delivery.log)、[PCK日志](artifacts/export_pck_delivery.log)、[结构化结果](artifacts/export_pck.json)、[实际截图](artifacts/export_pck.png)。**NOT TESTED：Windows系统启动与实体显卡**；跨平台资源验证不能代替它们。
- **初版PASS：完整双系统小规模能量包对局，完成1200模拟秒。** 种子20261016，64普通粒子槽、64²领土、256²输出、每包最多4096能量，1/120固定步、每帧最多8步；使用初版已修复定时命令的代码；本轮8px空间格等性能修复不在该次执行范围内。实际运行1281.426真实秒（约21分21秒），CPU时间1200.00000000147、GPU时间1200.0；682次真实落槽输出、2次保命、2次淘汰，仍有2队与8颗左球，因达到目标时长结束，没有提前全灭。启动与完整时长2项断言PASS，无脚本/着色器错误，溢出0。见[原始日志](artifacts/tests/final-battle-1200/battle.log)、[完整状态与结构化结果](artifacts/tests/final-battle-1200/results.json)、[逐项报告](artifacts/tests/final-battle-1200/REPORT.md)。

该局观测视口14.07 FPS，结束时64活跃普通粒子、3颗大球、85条未完成命令、340环槽占用和约31.92亿待发能量。明确小容量导致大量积压；这些数字不代表默认配置性能或所有库存已释放。遥测另记录15条死队普通命令被拒绝；淘汰前已积压输出与死亡通知交错时的全局能量处置仍需专项验收，不能据此长局声称全部能量路径已证明守恒。**默认逐粒子精确画质20–30分钟、多种子完整GPU长局及长期显存仍为NOT TESTED。**

[旧1200秒目标运行](artifacts/tests/20261016T053719727221Z/battle.log)已被上述最终版本取代；日志未完成1200模拟秒、没有最终通过断言，不作为长局通过证据。[更早的30秒运行记录](artifacts/tests/20261016T053147037627Z/REPORT.md)也只证明当时明确低精度配置的30秒运行，不能验证定时修复后的最终版本、默认画质或20分钟稳定性。

## 3. 对照用户第8节逐项验收

下列验收表是初版330d878的历史范围，表内G0表示当时已执行的32项规则套件；本轮G的36项已实际通过。本表分别说明已测部分与剩余范围，避免历史局部断言被误解为新版整项完成。

### 启动与显示

| 验收项 | 实际结论与边界 |
| --- | --- |
| 项目导入、GDScript/GLSL编译、Windows Forward+启动 | **初版PASS：** Linux Vulkan规则与主场景实际启动，GDScript执行、GLSL编译和管线绑定完成（G0/V）。**NOT TESTED：** Windows系统实际启动、不同显卡驱动，以及Godot4.3兼容分支。历史导入故障记录见第6节。 |
| 开局四象限、四核心可见、四队存活，盾枪各精确1M | **PASS：** GPU团队缓冲整数、25%面积、角落归属和实际画面检查（G0/V）；没有用开局免死时段掩盖状态。 |
| 显存渲染、无黑屏、路径标识、无每帧整帧回读 | **PASS：** 普通Vulkan窗口实际显示共享Texture2DRD及中文路径标识（G0/V）；正式路径源码审查无整帧读回和ImageTexture更新。**NOT TESTED：** Windows硬件驱动。 |

### 左侧物理和计数

| 验收项 | 实际结论与边界 |
| --- | --- |
| 正常模拟16球持续循环、不丢球、不变17球、重生值2 | **PASS：** 初始每队4球，输出重生值2，多种子CPU累计1440模拟秒每秒检查数量/边界/有限值（C）；主场景并行运行5秒（V）。CPU长局不能替代完整GPU长局。 |
| 六倍率口净宽不同、完整圆立即触发、超宽拒绝、左右×8不卡死 | **PASS：** 净宽37/47/67、中央98，镜像和逐口完整圆/超宽拒绝测试；多种子每球均取得进度，无连续120秒无进度（C）。**NOT TESTED：** 所有可调参数组合及长期极端密集入口。 |
| 小球上推、大球下落、高数值小半径仍受上推 | **PASS：** 同位置按真实半径求力、空间范围、小球正式积分上推和高门槛小半径测试（C）。**NOT TESTED：** 人工长期观感及任意参数组合拥堵验收。 |
| 门槛连续线性、旧球锁定、重生更新、四颜色一致 | **PASS：** 1001时间点与独立线性公式一致；旧球600秒后半径/T_birth不变，完整输出后重置2并更新门槛（C）；四队使用同一物理规则。四颜色的全部状态组合未穷举。 |
| 柱子分散、最大球不卡、输送带无缝且显示/输出一致、至少100次日志 | **PASS：** 多种子实体循环进度；120个独立坐标/相位参考输入全部匹配；固定位置与内容分别计数；1340次正式物理落槽日志（C）。**NOT TESTED：** 所有最大半径配置的专项柱阵穷举及人工连续录像验收。 |

### 右侧规则

| 验收项 | 实际结论与边界 |
| --- | --- |
| 己方领土不耗能、敌/中立格扣1、墙反弹 | **PASS：** 实际Compute中己地8点包保留、变更一格8→7且消耗计数增1、墙碰后位置/速度正确（G0）。 |
| 同队弹开、异队等消、密集同格无截断/泄漏 | **PASS：** 同队能量1粒子反弹不减能；异队10对4剩6且总消耗8；40颗同格检查在场+消耗守恒；2000速度相向狙击不漏碰（G0）。**NOT TESTED：** 高容量极端密集全场长期竞态及不同GPU一致性。 |
| 机枪360°、补安全半径、不锁细线、线性加速、库存用尽停火 | **NOT TESTED（整项）：** 主场景可见运行；代码提供连续旋转、有限防御瞄准、领土扇区评分和线性射速。现有独立断言检查充能独立及死亡转移，不足以证明整局瞄准策略、各时间点实际射速和库存耗尽行为。 |
| 风暴360°分批、狙击窄束推进/散射、大球移动/缩小/墙反弹 | **PASS（部分）：** 小额风暴不增能、狙击高速实体碰撞、真实领土扣能、大球可见并移动（G0/V）。**NOT TESTED（其余）：** 360°角度分布、狙击完整窄束推进/散射、全能量区间大球缩小和大球专项墙反弹均未形成完整独立验收断言。 |
| 同色大球弹开、异色大球等消、普通粒子推动大球 | **PASS：** 两颗同队40点球速度交换且总80；异队40对10剩30；普通粒子使40→39且大球获得非零冲量（G0）。 |
| 大球碰盾分离反弹、不粘盾、同次破盾不致死 | **PASS：** 盾2对球10，核心存活，球分离反射剩8；再推进8固定步不重复扣能（G0）。 |
| 有盾不死、无盾先救最大球、180秒模拟CD、失败才淘汰 | **PASS：** CPU抽最大1024只重生该球（C）；GPU多核多命中唯一待定、跨8步锁存、正式nonce握手补777并设置180秒CD、无球回复0淘汰、CD中致命淘汰、待定期间已补盾抵挡迟到失败回复（G0）。**NOT TESTED：** 默认配置长期全局所有事件交错。 |
| 死亡枪库存变风暴、四左球变大球、可连锁但不能复活 | **PASS（基础规则）：** 11枪库存转余波并按实际已发/待发/消耗核算；CPU四球抽取一次并停止循环；GPU明确death标记允许4球总能量30；死队普通即时武器被拒绝、护盾不能复活（C/G0）。**NOT TESTED：** 完整对局自然连锁死亡/同归于尽的专项验收。 |

### 性能、正确性和长局

| 验收项 | 实际结论与边界 |
| --- | --- |
| 10k/50k/100k；有条件再测300k/1M；记录性能/溢出 | **PASS：** 三档实际活跃数量与12步守恒/无溢出（S），数值见第4节。**NOT TESTED：** 300k、1M与实体显卡；本机不作60 FPS承诺。 |
| 小规模独立能量守恒、护盾扣减、领土一致性 | **PASS：** G0实际Compute与独立整数公式对照，不由CPU运行正式战场；含精确能量1和显式能量包输入。**NOT TESTED：** 相同大规模场景两种模式轨迹逐点一致；打包本来就改变局部几何，不能据能量守恒声称轨迹等价。 |
| 20–30分钟完整对局、多种子、卡球/黑屏/异常淘汰/溢出/长期显存 | **PASS（限定配置）：** 第2节初版64槽能量包双系统完成1200模拟秒、2次保命/2次淘汰、无运行错误和溢出。**NOT TESTED：** 默认精确画质20–30分钟、多种子完整GPU局、长期显存泄漏，以及淘汰时积压输出的全局守恒专项。C另为左侧CPU长局；均不能替代尚未执行的范围。 |
| 加速/暂停/继续/重开资源、退出、参数面板、中文 | **PASS（已执行部分）：** 主场景暂停与精确单步（V）、3次快速重开retired=0及短期资源观测（L）、参数合法性（P）、中文截图、无RD拒绝（U）。**NOT TESTED：** 每档速度确定性对照、长时间反复重开显存、全部配置保存/加载/重置的交互操作及各屏幕DPI/中文字符串穷举。 |

## 4. 软件Vulkan压力数据与本轮待补结果

以下10k/50k/100k数据仅对应初版330d878及历史S套件，本轮没有重跑该三档验收。实际场景是**同队均匀二维点阵、64²领土、256²输出、每档12个完整固定步（0.1模拟秒）**。执行了真实运动、空间链表、碰撞、领土与渲染pass，属于容量和基础吞吐检查。它不代表密集四队战局、默认512²/768²画质或长时间稳定帧率。

| 活跃粒子数 | 观测视口FPS | GPU批次时间 | 缓冲/纹理估算 | 最高格占用 | 溢出计数 | 守恒 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 10,000 | 52.50 | 27.88 ms | 1.26 MiB | 4 | 0 | PASS |
| 50,000 | 11.50 | 188.57 ms | 3.86 MiB | 18 | 0 | PASS |
| 100,000 | 4.79 | 463.42 ms | 7.10 MiB | 32 | 0 | PASS |
| 300,000 / 1,000,000 | NOT TESTED | NOT TESTED | 未实测 | 未实测 | 未实测 | 未实测 |

GPU时间来自主RenderingDevice时间戳，表示该次GPU工作批次；与视口FPS采样并非互为倒数。显存数字仅为项目缓冲/纹理估算，不含完整引擎、驱动或窗口开销；软件Vulkan也没有可据此外推的实体显卡显存表现。

### 本轮最终代码：真实风暴短采样

两版均通过正式`output(team, storm, 100000)`发射四队风暴，默认精确模式、1万容量、512²领土、768²输出，不用调试点阵填充。均经26个1/120秒固定步实际达到10000活跃粒子，再采样3次；每次1个固定步、实际2个GPU子步。所有样本保持10000活跃、总能量8400000、溢出0。

| 实测中位数 | 初版 | 本轮最终代码 |
| --- | ---: | ---: |
| 九色碰撞GPU时间 | 244.620 ms | 49.673 ms |
| 领土/护盾/大球事件GPU时间 | 34.904 ms | 6.397 ms |
| 统计GPU时间 | 6.276 ms | 0.739 ms |
| 发射准备GPU时间 | 4.634 ms | 1.020 ms |
| 画面计算GPU时间 | 16.618 ms | 21.051 ms |
| 墙时，含小表及时间戳等待 | 420.010 ms | 150.188 ms |

实际证据：[初版剖析](artifacts/storm_profile_before.json)、[最终剖析](artifacts/storm_profile_final.json)、[配置与源文件哈希汇总](artifacts/storm_profile_final_summary.json)。**仅3次样本，且为取得阶段时间戳将各dispatch拆成独立compute list，改变了原调度成本；这些数值不能直接转换为原游戏FPS，更不是RTX5060Ti实测。** 最终三次墙时89.844/150.188/226.328ms，存在明显波动；画面计算阶段本轮中位数更高，未将其删去。16px与8px格的最大占用56/17仅为各自诊断，因格面积不同，不能拿该比例计算提速。

本轮没有再跑最终代码的均匀点阵匹配batch夹具。此前[初版基线](artifacts/perf_before_matched.json)和[被撤回并行统计方案的退化结果](artifacts/perf_after_matched.json)完整保留，用于说明中间方案撤回，不能当作最终性能数据。`*_legacy_cached_timestamp.*`中的缓存时间可能滞后一批；`*_per_scenario_id_legacy.*`的batch ID未跨场景唯一。这些旧记录仅解释测试修正历史，不作为最终GPU对照。详见[性能修复记录](docs/性能修复记录.md)。

## 5. 架构核验与已知限制

实际GPU规则与画面运行配合源码审查，确认正式路径使用主RenderingDevice、SSBO、storage image及共享Texture2DRD；右侧普通粒子、领土、大球、盾与核心权威状态在RenderingDevice资源内更新。CPU只推进左侧球、时间、UI、少量发射命令及保命握手。正式约每0.25真实秒读取256B统计、512B团队与4096B大球遥测，约4.75KiB；没有读取普通粒子表或整张画面后重新上传。独立规则测试的小样本读回与明确截图不属于日常画面路径。

不同dispatch之间有compute barrier；本轮空间完整链表使用8px格与128²格头，配合九色紧凑中心调度，未使用旧参考工程每格仅检查32颗的固定截断。领土/护盾/大球事件仍由单GPU invocation顺序结算，这是**重大吞吐限制**；大球只扫描实际活跃ID，但有B颗大球时仍有O(N×B+B²)、B≤64成本，密集局部普通粒子也可能出现昂贵配对。容量选项不代表对应帧率保证。上述架构说明来自本轮源码，运行断言范围以顶部状态表为准。

精确模式新发射普通/狙击实体能量为1；打包模式明确采用整数权重近似，轨迹、局部压力及动量分布与单粒子不同。打包切回精确后，旧包仍存在时遥测标为mixed，界面说明存量近似，不能提前声称全场逐粒子精确。容量/地图/输出/固定步长/种子/初始库存重开生效；诊断固定步长取实际active_dt。CPU超限后保留原值并阻止继续/单步，GPU累计超限也停止，均不静默截断成小值。

真实左侧输出附带固定步模拟时刻，GPU在对应步骤才执行，避免一个批次内的后续落槽结果在批首提前生效；尚未到本批时刻的命令保留在CPU队列。事件时刻与GPU时钟统一使用float32域，避免1200秒附近批末事件被量化后迟一批。初版G0实际检查了未来护盾在2步和空flush后仍未生效、到第4步只加17一次、批末大球出生门槛取第4步，以及1200秒附近定时29护盾准确生效。该回归不等于完整长局验证。

盾/枪优先槽每队每类每次flush只接受首条，重复补给保留至后续flush，大球/命令环容量满也会延后；未承诺每档倍速的轨迹完全一致。

未完成或仍有风险的范围：Windows不同显卡兼容性、默认画质完整长局与平衡、机枪长期策略、极端高密度性能、300k/1M实际压力、长期显存增长、所有参数组合和人工观感验收。Godot4.3兼容分支尚未实测；推荐使用已测4.6.3。这里不声称所有物理规则和所有交错情形都已被证明正确。

## 6. 保留的失败记录与修复说明

历史失败原样保留，不以末次PASS覆盖或删除；下列初版修复记录不表示本轮已重跑同样长局：

- [首次短CPU测试](artifacts/tests/20261016T045725864364Z/REPORT.md)：正式物理落槽仅12次，未达到100次，真实FAIL；120个人工坐标/相位输入不能冒充100次自然物理输出。之后延长实际模拟，C记录1340次正式输出。
- [提前中止的CPU运行](artifacts/tests/20261016T045737176547Z/results.json)：进程退出−15，结果FAIL，未用作长局证据。
- [300秒硬截止](artifacts/tests/20261016T050049344900Z/results.json)：300.018真实秒被终止，结果FAIL。诊断是截止不足以完成该云机完整CPU运行；后续提高截止并实际完成C的305.256秒运行，没有把超时标成PASS。
- [初版截图采样FAIL](artifacts/tests/20261016T050050799510Z/REPORT.md)：视口缩放后的采样坐标错误。修正测试坐标映射后重新运行并检查真实截图，初版G0通过；没有用纯源码推断取代画面检查。
- [初版死亡库存断言FAIL](artifacts/tests/20261016T050228494557Z/REPORT.md)：断言只看剩余风暴库存，忽略测试推进期间已真实发射的能量。改为在场+待发+消耗的独立守恒核算后重测；不是人为增加库存迎合断言。
- [早期导入日志](artifacts/import_final.log)保留了GDScript局部变量类型推断错误；已修正明确类型，之后主场景/GPU测试实际运行成功。该旧文件名带final不表示它是最终有效结论。
- 收尾静态审查发现死队普通即时武器未拒绝、打包切精确误标、实际步长与诊断不一致、CPU超限未在界面锁停。现已修正：初版G0新增死队拒绝、四球死亡余波及mixed三项实际Compute断言；L主动触发CPU真实倍率超限验证中文显示和锁停。步长诊断传实际值，相关范围见P与上述未测试项。
- [定时回归修复前FAIL](artifacts/tests/timed-output-before/REPORT.md)：安排4步后才生效的护盾在前2步已提前充入，实际复现批处理忽略落槽时刻的问题。现已传递模拟时刻并在CPU/GPU保留未到期命令，统一float32时间域；[修复后32项PASS](artifacts/tests/timed-output-after/REPORT.md)包含不提前、到期一次、批末大球出生门槛及1200秒附近精度4项实际Compute回归。旧完整对局运行已停止并由最终代码重新开始，不能沿用旧运行作为修复后长局证据。

## 7. 可重复执行

在项目根目录，指定官方Godot4.6.3路径。以下是对应已执行工作流的复现命令；Linux的GPU命令需可用DISPLAY与Vulkan，可用`--wrapper "xvfb-run -a"`提供窗口服务。Xvfb并不提供GPU，不能把headless规则检查当作Compute验证。

```bash
python3 -m unittest discover -s tests -p 'test_*.py' -v
python3 tools/run_tests.py --godot /opt/godot/4.6.3/Godot_v4.6.3-stable_linux.x86_64 --suite cpu --duration 1200 --timeout 900
python3 tools/run_tests.py --godot /opt/godot/4.6.3/Godot_v4.6.3-stable_linux.x86_64 --suite gpu --timeout 300
python3 tools/run_tests.py --godot /opt/godot/4.6.3/Godot_v4.6.3-stable_linux.x86_64 --suite settings --timeout 120
python3 tools/run_tests.py --godot /opt/godot/4.6.3/Godot_v4.6.3-stable_linux.x86_64 --suite stress --timeout 300
godot --path . --rendering-method forward_plus --rendering-driver vulkan --script res://tools/visual_smoke.gd
godot --path . --rendering-method forward_plus --rendering-driver vulkan --script res://tools/lifecycle_smoke.gd
godot --path . --rendering-method gl_compatibility --script res://tools/unsupported_gpu_smoke.gd
```

Windows应在正常桌面会话使用同版本官方编辑器/控制台程序运行GPU套件，安装匹配的导出模板后按README导出。最终成品需在Windows10/11实体显卡上实际启动，观察默认画面并执行长局与性能验收。退出码0只表示请求范围内全部实际断言通过，1表示失败，77表示仍含NOT TESTED。

## 8. 交付结论

初版已提供可编辑Godot工程、中文README/CHANGELOG、真实Compute规则与画面证据、自动CPU/GPU/参数/压力测试及Windows导出文件。**初版右侧RenderingDevice常驻模拟与共享纹理显示路径已验证，没有逐帧整图CPU回读；本轮1.1.0-perf1已实际通过GPU36项、参数5项、5模拟秒主场景及导出PCK资源验证，真实风暴性能证据仅限3次分段短采样。Windows硬件兼容性、默认完整长局与全部性能/人工验收尚未完成，不能宣称已满足全部完成定义。**
