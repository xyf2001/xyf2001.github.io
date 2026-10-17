# 实际自动测试记录

总状态：**PASS**

原始输出与结构化结果保存在同一目录。此记录仅证明实际执行的断言；不替代 Windows、画面观感和真实显卡性能验收。

## settings：PASS

实际通过 47 项断言

原始日志：`settings.log`

- PASS：参数UI可接受范围与实际物理一致 — 低重力/大摩擦/最小球半径都按同一边界验证，不在物理层静默改为另一数值
- PASS：离散时步与速度配置不产生显示错位 — 手改存档中的非菜单数值安全回到明确默认值
- PASS：配置拒绝NaN和无穷 — 非法数值不会进入物理或GPU参数
- PASS：精确发射模式的包能量为一 — 存量包的混合标识由独立实际GPU测试验证
- PASS：旧配置迁移到固定射速与360颗风暴 — 旧默认射速与96颗环更新，保留用户关闭友方碰撞的选择
- PASS：旧自定义射速迁移为恒定值 — 不再保留时间渐增射速；每圈360是固定规则
- PASS：新参数有界且保留明确调试停火 — 非法碰撞布尔值不会静默关物理；0射速是显式调试选项
- PASS：增长缓和与索敌冷却拒绝非有限值 — 
- PASS：目标切换默认0.5模拟秒并保留显式自定义 — 缺失字段使用新默认，不把合法旧0.08或自定义0静默覆盖
- PASS：机枪发完时长默认10模拟秒且独立于旧射速增长字段 — 新时长即时生效；旧gun_duration不能被误当作补弹发完时长
- PASS：删除的进程发射成本不进入有效配置或即时更新 — 旧存档字段不能恢复已删除的发射成本机制；保留高能粒子的整数能量
- PASS：直接GPUWorld配置与实际GPU参数一致 · partial空配置 — 无需创建RenderingDevice或运行GPU；验证真实configure与224字节参数编码，不以测试get默认值遮盖缺失字段
- PASS：直接GPUWorld配置与实际GPU参数一致 · 显式旧0.08 — 无需创建RenderingDevice或运行GPU；验证真实configure与224字节参数编码，不以测试get默认值遮盖缺失字段
- PASS：直接GPUWorld配置与实际GPU参数一致 · 显式0 — 无需创建RenderingDevice或运行GPU；验证真实configure与224字节参数编码，不以测试get默认值遮盖缺失字段
- PASS：直接GPUWorld配置与实际GPU参数一致 · 显式0.35 — 无需创建RenderingDevice或运行GPU；验证真实configure与224字节参数编码，不以测试get默认值遮盖缺失字段
- PASS：直接GPUWorld配置与实际GPU参数一致 · NaN — 无需创建RenderingDevice或运行GPU；验证真实configure与224字节参数编码，不以测试get默认值遮盖缺失字段
- PASS：直接GPUWorld配置与实际GPU参数一致 · 无穷 — 无需创建RenderingDevice或运行GPU；验证真实configure与224字节参数编码，不以测试get默认值遮盖缺失字段
- PASS：直接GPUWorld配置与实际GPU参数一致 · 超出上限 — 无需创建RenderingDevice或运行GPU；验证真实configure与224字节参数编码，不以测试get默认值遮盖缺失字段
- PASS：直接GPUWorld配置与实际GPU参数一致 · 负值 — 无需创建RenderingDevice或运行GPU；验证真实configure与224字节参数编码，不以测试get默认值遮盖缺失字段
- PASS：直接GPUWorld配置与实际GPU参数一致 · 非法类型 — 无需创建RenderingDevice或运行GPU；验证真实configure与224字节参数编码，不以测试get默认值遮盖缺失字段
- PASS：机枪发完时长设置与真实GPU参数一致 · partial空配置 — 实际validate/configure与236字节编码均拒绝非法数值，不创建RenderingDevice
- PASS：机枪发完时长设置与真实GPU参数一致 · 显式2秒 — 实际validate/configure与236字节编码均拒绝非法数值，不创建RenderingDevice
- PASS：机枪发完时长设置与真实GPU参数一致 · 旧射速时长不复用 — 实际validate/configure与236字节编码均拒绝非法数值，不创建RenderingDevice
- PASS：机枪发完时长设置与真实GPU参数一致 · NaN — 实际validate/configure与236字节编码均拒绝非法数值，不创建RenderingDevice
- PASS：机枪发完时长设置与真实GPU参数一致 · 正无穷 — 实际validate/configure与236字节编码均拒绝非法数值，不创建RenderingDevice
- PASS：机枪发完时长设置与真实GPU参数一致 · 负无穷 — 实际validate/configure与236字节编码均拒绝非法数值，不创建RenderingDevice
- PASS：机枪发完时长设置与真实GPU参数一致 · 超过上限 — 实际validate/configure与236字节编码均拒绝非法数值，不创建RenderingDevice
- PASS：机枪发完时长设置与真实GPU参数一致 · 零值 — 实际validate/configure与236字节编码均拒绝非法数值，不创建RenderingDevice
- PASS：机枪发完时长设置与真实GPU参数一致 · 负值 — 实际validate/configure与236字节编码均拒绝非法数值，不创建RenderingDevice
- PASS：机枪发完时长设置与真实GPU参数一致 · 非法类型 — 实际validate/configure与236字节编码均拒绝非法数值，不创建RenderingDevice
- PASS：真实即时更新采用新时长且不能恢复旧成本 — 未启动GPU的真实update_settings路径；旧成本参数槽清零，新时长按236字节写入
- PASS：曲线冷却分裂角与友方碰撞开关均可即时更新 — 
- PASS：新配置保留高分辨率真实碰撞与固定柱编辑 — 迁移不降画质、不丢布局
- PASS：配置持久化包含新参数与碰撞开关 — 真实写入再读取用户配置，测试后恢复此前文件
- PASS：机枪补弹发完时长真实存档往返保留自定义值 — 独立新字段持久化，不复用历史gun_duration
- PASS：真实旧存档读取会迁移旧别名并补齐新字段 — gun_rate_end别名不被默认gun_end遮盖；缺失目标CD采用0.5模拟秒
- PASS：真实旧存档保留用户显式目标切换CD — 旧默认与显式自定义无法可靠区分，因此保留所有合法存档值
- PASS：真实旧成本存档读取并重存后永久丢弃废弃字段 — 缺失新时长使用10模拟秒；有效配置与磁盘文件均无旧成本，不能在重启时复活
- PASS：UI门槛备用显示与真实弛缓指数一致 — 包含长期上限；不继续显示旧线性门槛
- PASS：设置面板暴露有效新参数且不显示废弃风暴数量开关 — 目标切换CD控件默认0.5模拟秒，保持即时更新
- PASS：实际参数面板使用10模拟秒发完时长并删除旧成本控件 — 核真实SpinBox边界、中文标签、单位与即时生效提示，不读取源码猜测UI
- PASS：实际UI修改补弹时长同步有效配置与控件 — 
- PASS：实际UI诊断仅报告遥测粒子能量而不恢复进程成本 — 直接update_state读取实际active_packet_energy，忽略旧current_particle_cost遥测，JSON不含成本字段
- PASS：友方碰撞关闭同步到UI与配置 — 
- PASS：友方碰撞重新开启不会丢失开关状态 — 
- PASS：真实面板展示超过2^53库存仍保留整数低位 — 直接调用实际update_state检查完整数值及悬停提示，避免先转float64造成尾数丢失
- PASS：重开初始化不显示上局淘汰与库存 — 没有新GPU遥测时明确等待验证，不能把旧状态当开局状态
