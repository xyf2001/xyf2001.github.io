class_name GPUCollisions
extends RefCounted
## 粒子空间分区和步长约束。具体碰撞在battle.glsl模式3/4/5完成。
## 8游戏单位格，普通半径<=3；9色中心格各3×3链表集合互不相交。
## 实际位移超出格查询覆盖的弹性加速粒子，由GPU独立链串行完整补查，不夹速度。
const WORLD_SIZE := 1024.0
const CELL_SIZE := 8.0
const SPATIAL_COLUMNS := 128
const COLOR_PHASES := 9
const PHASE_WIDTH := 43 # ceil(128 / 3)，每相位的紧凑中心格调度上界。

static func substep_count(dt: float, settings: Dictionary) -> int:
	# 步末建桶+3×3候选要求2*位移+两半径<=格宽，不能只改格宽而保留4游戏单位位移。
	# 普通粒子、聚能弹和大球均按真实飞行速度约束子步。
	var speed := maxf(float(settings.get("particle_speed", 140.0)), float(settings.get("sniper_speed", 620.0)))
	speed = maxf(speed, float(settings.get("ball_speed", 42.0)))
	var radius := clampf(float(settings.get("particle_radius", 1.4)), 0.5, 3.0)
	var displacement_limit := minf(4.0, (CELL_SIZE - 2.0 * radius) * 0.5)
	var max_dt := minf(1.0 / 120.0, displacement_limit / maxf(speed, 1.0))
	return maxi(1, int(ceil(dt / max_dt)))
