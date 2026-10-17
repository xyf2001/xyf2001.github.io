# 实际自动测试记录

总状态：**PASS**

原始输出与结构化结果保存在同一目录。此记录仅证明实际执行的断言；不替代 Windows、画面观感和真实显卡性能验收。

## battle：PASS

实际通过 6 项断言

原始日志：`battle.log`

- PASS：长局GPU启动 — 
- PASS：长局原始结果文件可写 — /workspace/xyf2001.github.io/chromatic-wars/artifacts/validation-1.5.1/long-sequence-final/battle-1x/battle_1.0x.json
- PASS：长局原始结果保存完成 — /workspace/xyf2001.github.io/chromatic-wars/artifacts/validation-1.5.1/long-sequence-final/battle-1x/battle_1.0x.json
- PASS：长局最终物理与GPU完成状态 — 最终栅栏后重新核对GPU时钟、整数溢出、CPU弹球错误和运行时异常
- PASS：请求的对局模拟时长覆盖 — 实际完成所请求时长；不因时限宣布胜负
- PASS：20分钟完整左右系统耐久 — 正式分辨率和真实碰撞达到至少1200模拟秒
