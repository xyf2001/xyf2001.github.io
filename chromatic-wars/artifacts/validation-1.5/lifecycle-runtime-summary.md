# 生命周期与主场景实际验证

测试设备为 llvmpipe 软件 Vulkan，不能代表 RTX 5060 Ti 性能。

| 实际运行 | 通过 | 失败 | 未测 | 退出码 |
|---|---:|---:|---:|---:|
| retirement_order_before_fix | 5 | 1 | 0 | 1 |
| retirement_order_after_fix | 3 | 0 | 0 | 0 |
| late_callbacks_and_reuse_rejection | 10 | 0 | 0 | 0 |
| final_actual_main_scene | 10 | 0 | 0 | 0 |

修复前快速重开留下3个旧节点；逐个记录证明其 pending=0、release_confirmed=true、资源数=0，因此是主控同步快路径漏移除，不是GPU回读未完成。修复后 retired=0。原始首次完整主场景失败日志、JSON和截图另保留在 runtime-before-fix/。

修复仅调整旧对象退役顺序。真实回读排空、代际隔离、start拒绝未完成对象复用、窗口关闭等待释放等保护均保留。

延迟回调夹具实际持有13个回调超过12帧；归还后pending=0并确认释放。旧回调事件数0，时间戳更新次数保持1，未污染新局核心库存和模拟时间。

最终实际主场景10项全部通过，包括左右场景、1/2/4倍速各至少3模拟秒及GPU完成栅栏、四阵营混合武器、截图、暂停、单步、连续快速重开和最终释放。单步最终GPU溢出为0，两侧错误为空。

这属于短程功能及资源验证，不替代1200模拟秒耐久测试。软件Vulkan约2 FPS，仅报告实际观测，不据此推断5060 Ti性能或优化百分比。

详细指标与逐项证据见 lifecycle-runtime-summary.json、runtime-final/runtime_results.json 和相应原始日志。
