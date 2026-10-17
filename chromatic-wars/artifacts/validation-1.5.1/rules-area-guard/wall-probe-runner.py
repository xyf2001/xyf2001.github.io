#!/usr/bin/env python3
"""Prepare unchanged wall probes, then run them serially on the frozen area guard.
Preparation and Python syntax checks never launch Godot or a GPU process.
"""
from __future__ import annotations
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time

PROJECT = Path('/workspace/xyf2001.github.io/chromatic-wars')
RUNNER = Path(__file__).resolve()
EXPECTED = {
    'shaders/battle.glsl': 'c8c1007e7d7fd6b84f6a9b87857dd5e305f25075bfdb8cb94b702a9dd1d136b1',
    'scripts/gpu_world.gd': '73988ae98dca436c683a8db7ae3d131c4aa07514a77fae546170a7805f7c9007',
}
CASES = [
    ('wall-pair-probe-third', 'wall-pair-probe', 'c4dc7dcdb9b87d26486d9d2ed747b847411e759603b4f3c4d1a3902ce35efa1d', 4, 1),
    ('wall-pair-mechanical-second', 'wall-pair-mechanical', '7e23ad6b62f60673af821237dfee0f466062ea7c74f64fd847988ee735e9c433', 4, 1),
    ('wall-pair-mechanical-control-second', 'wall-pair-mechanical-control', '278d6ca06b1c848512e271dbf073c966203ab0cff78006b44f73fb867231500b', 4, 1),
    ('wall-pair-extended-second', 'wall-pair-extended', '5dbec83b24adb08ec4ae5766e1e29484233781f502b670230fe139ac7bbea197', 8, 5),
]
ENV = {
    'DISPLAY': ':99',
    'VK_ICD_FILENAMES': '/workspace/chromatic-tools/root/usr/share/vulkan/icd.d/lvp_icd.json',
    'LD_LIBRARY_PATH': '/workspace/chromatic-tools/root/usr/lib/x86_64-linux-gnu',
    'XDG_RUNTIME_DIR': '/tmp/cw-runtime', 'XDG_CACHE_HOME': '/tmp/cw-cache',
    'XDG_CONFIG_HOME': '/tmp/cw-config', 'XDG_DATA_HOME': '/tmp/cw-data',
    'LP_NUM_THREADS': '4',
}
BASE = ['taskset', '-c', '0-3', '/opt/godot/4.6.3/Godot_v4.6.3-stable_linux.x86_64',
        '--path', str(PROJECT), '--rendering-method', 'forward_plus',
        '--rendering-driver', 'vulkan', '--audio-driver', 'Dummy']
ANSI = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')


def utc():
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, data, exclusive=False):
    with Path(path).open('x' if exclusive else 'w') as out:
        json.dump(data, out, ensure_ascii=False, indent=2)
        out.write('\n')


def check_expected():
    actual = {key: sha(PROJECT / key) for key in EXPECTED}
    if actual != EXPECTED:
        raise RuntimeError('Frozen Shader/host mismatch; no Godot launched: ' + json.dumps(actual))
    return actual


def no_other_godot():
    raw = subprocess.check_output(['ps', '-eo', 'pid,comm'], text=True)
    found = [line for line in raw.splitlines() if len(line.split()) >= 2 and line.split()[1].startswith('Godot')]
    if found:
        raise RuntimeError('GPU is not exclusively available; no next process launched: ' + '; '.join(found))


def source_hashes():
    paths = [PROJECT / 'project.godot', PROJECT / 'export_presets.cfg',
             PROJECT / 'tests/gpu_suite.gd', PROJECT / 'tests/test_harness.gd',
             PROJECT / 'tools/run_tests.py']
    for folder, suffix in [('scripts', '*.gd'), ('shaders', '*.glsl'), ('scenes', '*.tscn')]:
        paths.extend(sorted((PROJECT / folder).glob(suffix)))
    return {str(path.relative_to(PROJECT)): sha(path) for path in paths}


def command(out):
    relative = (out / 'probe.gd').relative_to(PROJECT).as_posix()
    return BASE + ['--script', 'res://' + relative, '--', '--artifact-dir', str(out)]


def prepare(root):
    check_expected()
    root.mkdir(parents=True, exist_ok=True)
    plan_path = root / 'wall-probe-plan.json'
    if plan_path.exists() or any((root / item[1]).exists() for item in CASES):
        raise RuntimeError('Prepared/run output already exists; refusing to overwrite evidence: ' + str(root))
    prepared = []
    for old_name, new_name, expected_sha, checks, scenarios in CASES:
        old = PROJECT / 'artifacts/validation-1.5.1/rules' / old_name / 'probe.gd'
        if sha(old) != expected_sha:
            raise RuntimeError('Original probe changed; no copying: ' + str(old))
        out = root / new_name
        out.mkdir()
        shutil.copyfile(old, out / 'probe.gd')
        assert sha(out / 'probe.gd') == expected_sha
        prepared.append({'source': str(old), 'destination': str(out), 'probe_sha256': expected_sha,
                         'expected_checks': checks, 'physical_scenarios': scenarios, 'command': command(out)})
    plan = {'prepared_utc': utc(), 'expected_sources': EXPECTED, 'runner': str(RUNNER),
            'prepared_by_runner_sha256': sha(RUNNER), 'environment_overrides': ENV,
            'backend': 'llvmpipe software Vulkan, not RTX 5060 Ti',
            'expected_checks': 20, 'physical_scenarios': 8, 'probes': prepared,
            'status': 'PREPARED_NOT_RUN', 'gpu_started': False}
    write_json(plan_path, plan, exclusive=True)
    print(json.dumps({'status': plan['status'], 'plan': str(plan_path),
                      'execute_command': [sys.executable, str(RUNNER), '--execute', '--output', str(root)]}, ensure_ascii=False))


def run_process(cmd, log_path, timeout):
    env = os.environ.copy()
    env.update(ENV)
    began = time.monotonic()
    with log_path.open('x') as log:
        process = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
        timed_out = False
        try:
            actual_exit = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            timed_out = True
            process.kill()
            actual_exit = process.wait()
    return {'actual_exit': actual_exit, 'timed_out': timed_out,
            'elapsed_wall_seconds': time.monotonic() - began}


def execute(root, timeout):
    check_expected()
    no_other_godot()
    plan = json.loads((root / 'wall-probe-plan.json').read_text())
    if plan['expected_sources'] != EXPECTED or plan['prepared_by_runner_sha256'] != sha(RUNNER):
        raise RuntimeError('Prepared plan/runner identity mismatch')
    if (root / 'wall-probe-summary.json').exists():
        raise RuntimeError('Summary already exists; refusing to rerun over old evidence')
    for (_, name, expected_sha, _, _), entry in zip(CASES, plan['probes']):
        out = root / name
        if sha(out / 'probe.gd') != expected_sha or entry['probe_sha256'] != expected_sha:
            raise RuntimeError('Prepared probe changed: ' + str(out))
        if (out / 'probe.log').exists() or (out / 'source_metadata.json').exists():
            raise RuntimeError('Run evidence already exists: ' + str(out))
    results = []
    for _, name, expected_sha, checks, scenarios in CASES:
        check_expected()
        no_other_godot()
        out = root / name
        before = source_hashes()
        frozen = out / 'frozen_runtime_source'
        frozen.mkdir()
        (frozen / '.gdignore').write_text('')
        for relative in before:
            target = frozen / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / relative, target)
        shutil.copyfile(out / 'probe.gd', frozen / 'probe.gd')
        if any(sha(frozen / relative) != digest for relative, digest in before.items()):
            raise RuntimeError('Source changed while freezing snapshot; no next process launched')
        metadata = {'started_utc': utc(), 'command': command(out), 'expected_sources': EXPECTED,
                    'source_sha256_before': before, 'probe_sha256': expected_sha,
                    'runner_sha256': sha(RUNNER), 'expected_checks': checks,
                    'physical_scenarios': scenarios, 'environment_overrides': ENV,
                    'backend': 'llvmpipe software Vulkan, not RTX 5060 Ti',
                    'source_snapshot': 'frozen_runtime_source'}
        write_json(out / 'source_metadata.json', metadata, exclusive=True)
        metadata.update(run_process(command(out), out / 'probe.log', timeout))
        raw = ANSI.sub('', (out / 'probe.log').read_text(errors='replace'))
        rows, parse_errors = [], []
        for line in raw.splitlines():
            if line.startswith('CHROMATIC_TEST '):
                try:
                    rows.append(json.loads(line[len('CHROMATIC_TEST '):]))
                except json.JSONDecodeError:
                    parse_errors.append(line)
        errors = [line for line in raw.splitlines()
                  if line.startswith('ERROR:') or 'SCRIPT ERROR:' in line or 'SHADER ERROR:' in line or 'Parse Error:' in line]
        after = source_hashes()
        count = {status: sum(item.get('status') == status for item in rows)
                 for status in ['PASS', 'FAIL', 'NOT TESTED']}
        metadata.update({'finished_utc': utc(), 'source_sha256_after': after,
                         'sources_unchanged': before == after,
                         'counts': count, 'engine_error_lines': len(errors),
                         'engine_errors': errors, 'parse_errors': parse_errors})
        passed = (metadata['actual_exit'] == 0 and not metadata['timed_out'] and before == after
                  and not errors and not parse_errors and count == {'PASS': checks, 'FAIL': 0, 'NOT TESTED': 0})
        metadata['status'] = 'PASS' if passed else 'FAIL'
        write_json(out / 'source_metadata.json', metadata)
        write_json(out / 'results.json', {'status': metadata['status'], 'metadata': metadata, 'results': rows}, exclusive=True)
        results.append({'name': name, **metadata})
        write_json(root / 'wall-probe-summary.in-progress.json', {'status': 'RUNNING', 'completed': results})
        print(json.dumps({'name': name, 'status': metadata['status'], **metadata['counts'],
                          'actual_exit': metadata['actual_exit'], 'engine_errors': len(errors),
                          'sources_unchanged': before == after}, ensure_ascii=False), flush=True)
    total = {status: sum(item['counts'][status] for item in results) for status in ['PASS', 'FAIL', 'NOT TESTED']}
    overall = 'PASS' if all(item['status'] == 'PASS' for item in results) else 'FAIL'
    write_json(root / 'wall-probe-summary.json', {'status': overall, 'expected_sources': EXPECTED,
               'counts': total, 'physical_scenarios': 8, 'probes': results}, exclusive=True)
    no_other_godot()
    return 0 if overall == 'PASS' else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--prepare-only', action='store_true')
    mode.add_argument('--execute', action='store_true')
    parser.add_argument('--output', type=Path, default=PROJECT / 'artifacts/validation-1.5.1/rules-area-guard')
    parser.add_argument('--timeout', type=float, default=300.0)
    args = parser.parse_args()
    root = args.output.resolve()
    root.relative_to(PROJECT)
    if args.prepare_only:
        prepare(root)
        return 0
    return execute(root, args.timeout)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, OSError, KeyError) as error:
        print('RUNNER ERROR: ' + str(error), file=sys.stderr)
        raise SystemExit(2)
