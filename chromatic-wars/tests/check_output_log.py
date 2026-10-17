#!/usr/bin/env python3
"""从真实物理落槽原始日志独立复核显示矩形、位置计数与输出。"""
import argparse
import json
import math
from pathlib import Path


def inspect_log(path: Path) -> dict:
    events = []
    errors = []
    position_counts = [0] * 6
    content_counts = [0] * 6
    kinds = [0, 1, 2, 0, 3, 4]
    labels = ["护盾", "大球", "狙击", "风暴", "机枪"]
    left, right = 16.0, 464.0
    cell_width = (right - left) / 6
    for line_number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
        if not line.startswith("PHYSICAL_OUTPUT "):
            continue
        try:
            event = json.loads(line.removeprefix("PHYSICAL_OUTPUT "))
            events.append(event)
            x, phase = float(event["x"]), float(event["phase"])
            if not math.isfinite(x) or not 0 <= phase < 6 or not left <= x <= right:
                raise ValueError("坐标或相位超出合法范围")
            selected = None
            # 独立参考根据连续移动的可见矩形覆盖落点，而非直接调用游戏sample。
            for cell in range(-2, 14):
                raw_left = left + (cell - phase) * cell_width
                lo, hi = max(left, raw_left), min(right, raw_left + cell_width)
                if hi > lo and lo <= min(x, right - 1e-6) < hi:
                    selected = cell % 6
                    break
            if selected is None:
                raise ValueError("落点没有被任何可见武器矩形覆盖")
            position = min(5, int((x - left) // cell_width))
            expected_kind = kinds[selected]
            if (int(event["position_slot"]) != position or int(event["content_slot"]) != selected
                    or int(event["kind"]) != expected_kind or event["label"] != labels[expected_kind]):
                raise ValueError(f"显示与输出不符：独立显示kind={expected_kind}, content={selected}, position={position}；真实记录={event}")
            position_counts[position] += 1
            content_counts[selected] += 1
        except (ValueError, KeyError, TypeError) as error:
            errors.append({"line": line_number, "error": str(error)})
    status = "PASS" if len(events) >= 100 and not errors else "FAIL"
    return {"status": status, "name": "独立复核至少100次真实物理落槽与显示", "detail": "逐条比较正式物理原始落点与相位对应的连续可见矩形，包含标签及独立位置/内容索引",
            "metrics": {"events": len(events), "mismatches": len(errors), "position_counts": position_counts,
                        "content_counts": content_counts, "source": str(path)}, "errors": errors}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = inspect_log(args.log)
    text = json.dumps(result, ensure_ascii=False, indent=2)
    if args.output:
        args.output.write_text(text + "\n", encoding="utf-8")
    print("CHROMATIC_TEST " + json.dumps(result, ensure_ascii=False))
    return 0 if result["status"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
