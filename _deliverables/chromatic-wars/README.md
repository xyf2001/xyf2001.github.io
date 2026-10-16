# 颜色大战 · 1.1.0-perf1 性能修复版

- `ChromaticWars-Windows-x64-Performance1.zip`：Windows性能修复版。点击文件后选择Download raw file或View raw，下载并解压到新文件夹，运行`颜色大战.exe`。
- `ChromaticWars-Godot-Source-Performance1.zip`：完整可编辑Godot4.6.3工程。
- `SHA256SUMS.txt`：两个ZIP的SHA256校验。

本轮针对用户反馈RTX5060Ti在0.25×、风暴后约2FPS：细化8px空间格并配套CCD子步、紧凑九色调度、满槽缓存、有序大球掩码、增量面积统计。右下战场诊断“复制”可复制真实Vulkan设备/FPS/配置。

GPU36项、参数5项、完整主场景5模拟秒/暂停/单步以及导出内嵌PCK资源验证通过。软件Vulkan真实风暴1万活跃粒子守恒、溢出0；3次拆列表剖析中位墙时420.010→150.188ms。该数据不是RTX5060Ti实际帧率保证；新版Windows实机与完整20分钟长局未代用户验证。

测试报告与性能说明在两个ZIP内的TEST_REPORT.md、docs/性能修复记录.md及artifacts目录。旧版交付仍可从历史提交330d878下载，本轮未把旧版长局冒充新版验收。
