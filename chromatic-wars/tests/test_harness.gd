extends SceneTree
## 仅供自动测试。逐项原始记录以 CHROMATIC_TEST JSON 输出，禁止把未执行项目当 PASS。

var failures: int = 0
var passes: int = 0
var untested: int = 0
var options: Dictionary = {}

func _initialize() -> void:
	var argv := OS.get_cmdline_user_args()
	var i := 0
	while i + 1 < argv.size():
		options[argv[i].trim_prefix("--")] = argv[i + 1]
		i += 2
	call_deferred("run_suite")

func record(status: String, case_name: String, detail: String = "", metrics: Dictionary = {}) -> void:
	if status == "PASS":
		passes += 1
	elif status == "FAIL":
		failures += 1
	else:
		untested += 1
	var data := {"status": status, "name": case_name, "detail": detail}
	if not metrics.is_empty():
		data["metrics"] = metrics
	print("CHROMATIC_TEST " + JSON.stringify(data))

func check(condition: bool, case_name: String, detail: String = "", metrics: Dictionary = {}) -> bool:
	record("PASS" if condition else "FAIL", case_name, detail, metrics)
	return condition

func finish() -> void:
	print("测试完成：PASS=%d FAIL=%d NOT TESTED=%d" % [passes, failures, untested])
	quit(1 if failures > 0 or passes == 0 and untested == 0 else (77 if untested > 0 else 0))

func run_suite() -> void:
	record("FAIL", "测试入口", "未实现 run_suite")
	finish()
