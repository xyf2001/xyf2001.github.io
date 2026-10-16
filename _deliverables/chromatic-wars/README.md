# 颜色大战 · 1.1.1-channel-wall 倍率槽底墙修复版

- `ChromaticWars-Windows-x64-ChannelWall.zip`：Windows修复版，下载后解压到新文件夹，运行`颜色大战.exe`。
- `ChromaticWars-Godot-Source-ChannelWall.zip`：可编辑Godot 4.6.3完整工程。
- `SHA256SUMS.txt`：两个ZIP的SHA256校验。

本轮仅给六个倍率槽补上8px实体底墙，阻止下方反弹球、被大球挤压的小球穿墙误触倍率；中央98px通路及正常从上方入槽的倍率规则保持不变。

专项27项回归通过，覆盖216组单球逆入、324组双球挤压及接缝/正常入口/中央通行；实际EXE内嵌PCK重复27项通过。原有CPU19项通过：主种子20分钟、另两种子各2分钟，16球完整，1547次底部输出，最长无进度37模拟秒。最终导出资源、Compute启动和画面检查通过。

测试使用Linux Godot及软件Vulkan；未代用户执行Windows/RTX实机验收，也未在本轮重跑完整GPU长局。详情和中间失败诊断保留在ZIP内的`TEST_REPORT.md`及`artifacts/channel_wall_final/README.md`。上一性能版仍保留于历史提交`f5f5ea648286371b55c4c34811776516100ba7eb`。
