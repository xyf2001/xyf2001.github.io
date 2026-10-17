#!/usr/bin/env python3
"""Merge completed final-rule evidence into the report, retaining all history."""
import json
from pathlib import Path

ROOT = Path('/workspace/xyf2001.github.io/chromatic-wars')
BASE = ROOT / 'artifacts/validation-1.5.1'
DRAFT = Path('/workspace/chromatic-tools/TEST_REPORT_1_5_1_prefix_draft.md')
MARK = '## 历史检查点：1.5.0-validated（含旧发射成本）'

def load(path):
    return json.loads(path.read_text())

def main():
    release = load(BASE / 'release_validation.json')
    sequence = load(BASE / 'long-sequence-final/sequence_status.json')
    if release.get('status') != 'PARTIAL' or sequence.get('status') != 'INTERRUPTED' or len(sequence.get('runs', [])) != 3:
        raise RuntimeError('Do not merge a running, failed or incomplete sequence')
    current = (ROOT / 'TEST_REPORT.md').read_text()
    if current.count(MARK) != 1:
        raise RuntimeError('Historical report boundary is missing or ambiguous')
    history = current[current.index(MARK):]
    text = DRAFT.read_text()
    text = text.replace('最新完整对局与倍速耐久仍在运行，尚不宣称20分钟长局通过。',
        '当前规则回归、性能、主场景、导出及独立1×/2×已有真实结束结果；4×按用户“停止测试 直接输出”指示中止，不计通过。总验收标为 **PARTIAL**：软件Vulkan不能代替RTX或原生Windows，未确认的分配语义及各项实际覆盖范围详见下文。')
    text = text.replace('源码ZIP、Windows压缩包与下载链接由最终交付步骤补齐；此草稿不声称下载包已经发布。',
        '源码ZIP与Windows压缩包位于仓库 `_deliverables/chromatic-wars/`，分别为 `ChromaticWars-Godot-Source-Validated.zip` 与 `ChromaticWars-Windows-x64-Validated.zip`。解压Windows包后双击 `颜色大战.exe`，编辑源码时用Godot4.6.3导入 `ChromaticWars/project.godot`；具体SHA及验证状态见交付校验与 `BUILD_INFO.json`。')
    text = text.replace('236字节参数编码', '参数偏移236编码')
    start = text.index('## 完整对局与倍速耐久待合并')
    end = text.index('## 尚未解决的边界与RTX实机建议', start)
    lines = [
        '## 当前构建的完整双系统与倍速耐久实测', '',
        '三个独立新开局均用种子20261017，正式512²领土/768²渲染、1万粒子容量、1/120模拟秒、友方碰撞开启，冻结运行代码与验证工具。1×请求1200模拟秒，2×/4×各请求120模拟秒。前两次完成最终GPU小表栅栏及资源关闭；4×按用户明确指示中止，无最终GPU栅栏或资源回收验收，不计完整通过。没有沿用旧成本版本的中断局。', '',
        '| 目标倍率 | 请求/实际CPU模拟秒 | GPU完成模拟秒 | 实际墙秒＋结束栅栏秒 | 绘制平均/1%low FPS | 正常输出 | 倍率触发 | 防卡 | 最大球能量 | 平均输出能量 | 保命/死亡 |',
        '| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |',
    ]
    rows = []
    for speed in (1, 2):
        folder = BASE / f'long-sequence-final/battle-{speed}x'
        files = list(folder.glob('battle_*x.json'))
        if len(files) != 1:
            raise RuntimeError('Missing final battle result')
        d = load(files[0]); rows.append(d)
        if not d.get('final_validation_ok') or d.get('runtime_error') or d.get('pinball_error'):
            raise RuntimeError('Failed final physics state')
        lines.append(f"| {speed}× | {d['target_duration_sim_seconds']:.0f} / {d['sim_seconds']:.3f} | {d['gpu_sim_seconds']:.3f} | {d['wall_seconds']:.3f}＋{d['completion_fence_wall_seconds']:.3f} | {d['observed_drawn_fps']:.3f} / {d['drawn_fps_1pct_low']:.3f} | {d['outputs']} | {d['multiplier_triggers']} | {d['unstuck_events']} | {d['maximum_observed_ammo']} | {d['average_output_energy']:.2f} | {d['rescues']} / {d['deaths']} |")
    lines.append('| 4× | 120 / 用户中止 | 无最终栅栏 | 无最终测量 | 未完成 | 未完成 | 未完成 | 未完成 | 未完成 | 未完成 | 未完成 |')
    lines += ['', '实际范围与结局：', '']
    for item, d in zip(release['actual_independent_battles'], rows):
        speed = item['requested_speed']
        covered = '达到请求时长' if item['requested_duration_covered'] else '未达到请求时长'
        endurance = '达到1200模拟秒，20分钟双系统耐久通过' if item['twenty_minute_endurance_observed'] else '不足1200模拟秒，20分钟耐久不计通过'
        ending = f"自然结局 `{json.dumps(d['outcome'], ensure_ascii=False, separators=(',', ':'))}`" if d['natural_end'] else '没有观测到自然结局，没有按时长强制判胜'
        if not d['natural_end'] and d.get('outcome', {}).get('living') is not None:
            ending += f"；终态存活队伍索引 `{d['outcome']['living']}`"
        if d['timed_out']:
            ending += '；实际墙钟预算用尽'
        lines.append(f"- **{speed}×**：{covered}；{endurance}；{ending}。真实Godot退出 `{item['actual_godot_exit']}`，套件汇总 `{item['suite_status']}`；实际模拟吞吐 {d['achieved_completed_sim_seconds_per_wall_second']:.4f} 模拟秒/墙秒，累计物理子步 {d['gpu_substeps']}，最大采样活跃 {d['max_active_sampled']} 普通粒子、{d['max_big_sampled']} 大球。")
    stopped = release['actual_independent_battles'][2]
    last = stopped['last_periodic_progress']
    lines.append(f"- **4×**：用户要求立即停测，未完成120秒或20分钟验收。末次周期遥测为GPU {last['gpu_sim_seconds_completed']:.3f}模拟秒、CPU已提交 {last['sim_seconds_scheduled']:.3f}模拟秒、{last['wall_seconds']:.3f}墙秒、{last['outputs']}次输出；这些是中止前采样，不是最终完成栅栏。实际Godot退出-15、runner退出1，原始FAIL状态保留并用 `battle-4x/STOP_REASON.json` 说明人为中断原因，不改写为PASS。")
    lines += ['',
        '1×/2×最终物理/GPU栅栏检查通过，运行异常、弹球异常与整数溢出均为0；这不等于软件设备实时达到目标倍速。2×内置20分钟条目返回 `NOT TESTED`/77，保留该实际状态：请求的120秒连续稳定性与20分钟耐久是两个范围。4×末采样未报错误，但中止后没有最终验收。自然完整胜负只有在真实终局条件成立时才可声称，局部死亡/保命覆盖还应结合独立接触与资源回归。', '',
        '原始日志、全部帧统计、GPU子步、最终小表、配置、源文件前后SHA和实际退出见 `artifacts/validation-1.5.1/long-sequence-final/sequence_status.json` 及各 `battle-1x`、`battle-2x`、`battle-4x` 目录；结束结果由 `artifacts/validation-1.5.1/release_validation.json` 绑定最终运行源码。旧0.08、旧成本版本及源码变化中断的长局保留为历史，不计当前通过。', '',
    ]
    text = text[:start] + '\n'.join(lines) + '\n' + text[end:]
    if 'LONG_RESULTS_TO_INSERT' in text or '此草稿' in text or '仍在运行' in text or 'PENDING' in text:
        raise RuntimeError('Unmerged current placeholder')
    (ROOT / 'TEST_REPORT.md').write_text(text.rstrip() + '\n\n' + history)
    print('Merged actual current results and retained historical report, no runtime source changed')

if __name__ == '__main__':
    main()
