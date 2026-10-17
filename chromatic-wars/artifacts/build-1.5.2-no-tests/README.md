# 1.5.2 导出构建记录

本目录只记录资源导入、Shader资源编译及Windows导出，不包含游戏运行或物理/性能测试。`build_metadata.json`记录实际命令、退出状态、构建前后运行源码SHA256及导出EXE哈希；`import.log`、`export.log`为原始输出。

用户要求“修改但不测试”，因此游戏、CPU/GPU规则、Windows内嵌PCK运行、实体显卡及性能状态均为NOT TESTED。成功导入/导出不能证明游戏行为正确。

`superseded-terrain-only/`是加入狙击宽度、保命和机枪修正之前的中间构建记录，未用于最终下载。其当时未结束回填的元数据保留原样；不要将中间源码哈希或构建状态用于本次最终包。最终包以本目录顶层元数据及工程`BUILD_INFO.json`为准。
