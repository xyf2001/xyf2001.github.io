extends "res://tools/validation_matrix.gd"
## 同一活跃数与不同容量矩阵；基准条件写入JSON，不降低正式分辨率。
func run() -> void:
 if not options.has("json"):
  options["json"] = str(options.get("artifact-dir","res://artifacts")).path_join("matrix.json")
 if not options.has("samples"): options["samples"]="60"
 if not options.has("warmup"): options["warmup"]="10"
 await super.run()
