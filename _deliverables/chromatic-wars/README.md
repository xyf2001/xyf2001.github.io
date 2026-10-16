# 颜色大战下载

- `ChromaticWars-Windows-x64.zip`：Windows成品，约37.8MB。点击该文件后选择Download raw file或View raw，下载并解压，运行`颜色大战.exe`。
- `ChromaticWars-Godot-Source.zip`：可编辑Godot工程，约1.6MB。解压后用Godot4.6.3标准版导入`ChromaticWars/project.godot`。
- `SHA256SUMS.txt`：两个ZIP的SHA256校验。

测试报告、截图和原始日志在两个ZIP内的TEST_REPORT.md与artifacts目录。
CPU19项、GPU32项及明确64槽能量包配置1200模拟秒已经实际验证；GPU测试环境为软件Vulkan。
Windows系统/实体显卡、默认精确画质长局与高容量硬件性能尚未完成验证，不能声称全部验收通过。
右侧实际使用RenderingDevice Compute常驻模拟与Texture2DRD显示，无逐帧整图CPU回读。
