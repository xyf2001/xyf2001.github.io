#!/usr/bin/env python3
"""Capture real final main-scene, import, export and embedded-PCK checks."""
from __future__ import annotations
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import time

ROOT = Path('/workspace/xyf2001.github.io/chromatic-wars')
OUT = ROOT / 'artifacts/validation-1.5.1'
LAUNCH = '/tmp/cw-root-gpu.sh'
EXPECTED_SHADER = 'c8c1007e7d7fd6b84f6a9b87857dd5e305f25075bfdb8cb94b702a9dd1d136b1'

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def now(): return dt.datetime.now(dt.timezone.utc).isoformat()
def save(p, obj): p.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n')
def source_hashes():
    files = [ROOT/'project.godot', ROOT/'export_presets.cfg']
    for folder in ('scenes','scripts','shaders','assets'):
        files.extend(p for p in (ROOT/folder).rglob('*') if p.is_file() and p.suffix not in ('.uid','.import'))
    files.extend(ROOT/'tools'/name for name in ('runtime_validation.gd','export_pck_smoke.gd'))
    return {str(p.relative_to(ROOT)):digest(p) for p in sorted(files)}

def run(label, args, folder, cwd=ROOT, env=None, timeout=900):
    before = source_hashes()
    meta = {'stage':label,'started_utc':now(),'command':[LAUNCH]+args,'cwd':str(cwd),
            'source_sha256_before':before,'device':'llvmpipe LLVM19.1.7 software Vulkan, not RTX5060Ti',
            'timeout_seconds':timeout,'cpu_affinity':'0-3','LP_NUM_THREADS':4}
    save(folder/(label+'_metadata.json'),meta)
    print('RELEASE_CHECK_START '+label,flush=True)
    began=time.monotonic()
    with (folder/(label+'.log')).open('w') as log:
        proc=subprocess.Popen([LAUNCH]+args,cwd=cwd,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
        try:
            code=proc.wait(timeout=timeout)
            timed_out=False
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid,signal.SIGTERM)
            try: code=proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid,signal.SIGKILL);code=proc.wait()
            timed_out=True
    text=(folder/(label+'.log')).read_text(errors='replace')
    errors=re.findall(r'(?m)^(?:SCRIPT ERROR:|ERROR:|.*Parse Error:|.*Shader compilation failed).*$',text)
    after=source_hashes()
    meta.update(completed_utc=now(),wall_seconds=time.monotonic()-began,actual_exit_code=code,
                timed_out=timed_out,engine_errors=errors,engine_error_count=len(errors),
                source_sha256_after=after,sources_unchanged=before==after)
    meta['status']='PASS' if code==0 and not timed_out and not errors and before==after else 'FAIL'
    save(folder/(label+'_metadata.json'),meta)
    print('RELEASE_CHECK_RESULT '+json.dumps({k:meta[k] for k in ('stage','status','actual_exit_code','engine_error_count','wall_seconds','sources_unchanged')}),flush=True)
    if meta['status']!='PASS': raise RuntimeError(label+' failed; see preserved actual log')
    return meta

def main():
    if digest(ROOT/'shaders/battle.glsl')!=EXPECTED_SHADER: raise RuntimeError('Unexpected runtime Shader; update reviewed candidate before starting checks')
    runtime=OUT/'runtime-final'
    build=OUT/'export-final'
    if runtime.exists() or build.exists(): raise RuntimeError('Refusing to overwrite release evidence')
    runtime.mkdir(parents=True);build.mkdir(parents=True)
    shutil.copy2(__file__,build/'release_check_runner.py')
    frozen=build/'frozen_runtime_source';frozen.mkdir();(frozen/'.gdignore').touch()
    for name in source_hashes():
        if name.startswith('assets/'): continue
        target=frozen/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copy2(ROOT/name,target)
    env=os.environ.copy();env['CW_TEST_USER_DATA']='/tmp/cw-release-main-1-5-1-c8c1'
    rt=run('runtime',['--audio-driver','Dummy','--path',str(ROOT),'--script','res://tools/runtime_validation.gd','--','--artifact-dir',str(runtime),'--sim-seconds-per-speed','3'],runtime,env=env)
    data=json.loads((runtime/'runtime_results.json').read_text())
    if data.get('status')!='PASS': raise RuntimeError('Actual main-scene assertions did not pass')
    save(runtime/'SUMMARY.json',{'status':'PASS','actual_run':rt,'actual_results':'runtime_results.json'})
    imported=run('import',['--audio-driver','Dummy','--path',str(ROOT),'--editor','--import','--quit'],build)
    exe=ROOT/'export/颜色大战.exe'
    exported=run('export',['--headless','--audio-driver','Dummy','--path',str(ROOT),'--export-release','Windows 桌面',str(exe)],build)
    smoke=Path('/tmp/export_pck_smoke_1_5_1-final.gd');shutil.copy2(ROOT/'tools/export_pck_smoke.gd',smoke)
    env=os.environ.copy();env['CW_TEST_USER_DATA']='/tmp/cw-release-pck-1-5-1-c8c1'
    if Path(env['CW_TEST_USER_DATA']).exists():raise RuntimeError('PCK must use fresh user-data directory')
    pckrun=run('pck',['--audio-driver','Dummy','--rendering-method','forward_plus','--rendering-driver','vulkan','--main-pack',str(exe),'--script',str(smoke),'--','--artifact-dir',str(build)],build,cwd=Path('/tmp'),env=env)
    pck=json.loads((build/'export_pck.json').read_text())
    if pck.get('status')!='PASS' or pck.get('main_pack_sha256')!=digest(exe):raise RuntimeError('Actual embedded-PCK result or EXE identity failed')
    save(build/'build_metadata.json',{'status':'PASS','import':imported,'export':exported,'pck':pckrun,
        'windows_exe_sha256':digest(exe),'windows_exe_bytes':exe.stat().st_size,
        'file_identification':subprocess.check_output(['file',str(exe)],text=True).strip(),
        'pck_tool_sha256':digest(smoke),'native_windows_execution':'NOT TESTED','physical_gpu_execution':'NOT TESTED'})
    print('RELEASE_CHECKS_COMPLETE PASS',flush=True)

if __name__=='__main__':main()
