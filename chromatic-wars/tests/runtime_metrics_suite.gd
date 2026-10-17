extends "res://tests/test_harness.gd"
const RuntimeMetrics = preload("res://tools/runtime_validation.gd")

func run_suite() -> void:
	var samples: Array[float] = []
	samples.resize(200)
	samples.fill(1.0)
	samples[198] = 100.0
	samples[199] = 300.0
	check(is_equal_approx(RuntimeMetrics.one_percent_low_fps(samples), 5.0), "低帧指标使用最慢1%帧的平均间隔", "200帧中最慢2帧100/300毫秒，平均200毫秒，应为5FPS；不能用p99倒数替代")
	samples.resize(150)
	samples.fill(2.0)
	samples[148] = 10.0
	samples[149] = 30.0
	check(is_equal_approx(RuntimeMetrics.one_percent_low_fps(samples), 50.0), "低帧样本数量向上取整", "150帧取ceil(1.5)=2，最慢两帧平均20毫秒，应为50FPS")
	var empty: Array[float] = []
	var single: Array[float] = [100.0]
	check(RuntimeMetrics.one_percent_low_fps(empty) == -1.0 and is_equal_approx(RuntimeMetrics.one_percent_low_fps(single), 10.0), "无帧不伪造低帧表现，单帧按实际间隔计算")
	finish()
