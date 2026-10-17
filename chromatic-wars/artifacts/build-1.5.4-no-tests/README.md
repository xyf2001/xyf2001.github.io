# 1.5.4 构建证据；未运行游戏或测试

根目录 `build_metadata.json`、`import.log`、`export.log` 绑定最终1.5.4运行源码及Windows EXE，资源导入与导出实际退出码均为0；脚本同时检查日志、Shader导入缓存MD5和构建前后源码SHA256。Godot4.6.3编辑器使用Linux/Xvfb、llvmpipe软件Vulkan，仅作资源导入；没有启动主场景、PCK、物理/性能测试或Windows EXE。

- `failed-ui-variable-shadow/`：实际导入进程退出0，但日志报告GameUI局部变量重名，外层构建判失败；修复后重新导入，不以进程0冒充成功。
- `superseded-performance-only/`：增加人工控制前的中间构建，不能代表最终源码。
- `superseded-ui-text/`：构建过程中改正暂停输入提示，源码快照变化，外层状态SOURCE CHANGED DURING BUILD，不用于交付。
- `superseded-manual-route/`：构建过程中将人工护盾/机枪输入改走持久命令环以保留溢出输入，源码快照变化，同样不用于交付。

最终根目录构建是在运行源码冻结后完成；没有改写历史失败日志。所有1.5.3及更早运行结果仅属于历史版本。EXE、ZIP和源码哈希见本目录元数据及交付目录清单；不包含本版FPS、GPU阶段占比、救援响应时延或实体显卡结论。
