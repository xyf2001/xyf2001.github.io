#!/usr/bin/env python3
"""Run fresh, frozen final-rule1x/2x/4x battles sequentially; never reuse evidence."""
from __future__ import annotations
import argparse, datetime, hashlib, importlib.util, json, os, signal, subprocess, sys, time
from pathlib import Path

PROJECT = Path('/workspace/xyf2001.github.io/chromatic-wars')
GODOT = '/opt/godot/4.6.3/Godot_v4.6.3-stable_linux.x86_64'
RUNNER_PATH=PROJECT/'tools/run_tests.py'
_spec=importlib.util.spec_from_file_location('frozen_battle_runner',RUNNER_PATH)
_runner=importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_runner)
EXPECTED = {
 'shaders/battle.glsl':'c8c1007e7d7fd6b84f6a9b87857dd5e305f25075bfdb8cb94b702a9dd1d136b1',
 'scripts/gpu_world.gd':'73988ae98dca436c683a8db7ae3d131c4aa07514a77fae546170a7805f7c9007',
 'scripts/game_settings.gd':'9e59670bf4014fc0145f2cb7cf9d893c9f2170c46d68ee381cd54d8669d97979',
 'tools/run_tests.py':'90eafab182c27c09f0643304a4bedd0889dfde0ce556331d966bd4a1ac9cd76c',
}

def now(): return datetime.datetime.now(datetime.timezone.utc).isoformat()
def hashes(): return _runner.source_hashes(PROJECT,['battle'])
def save(path,obj): path.write_text(json.dumps(obj,ensure_ascii=False,indent=2)+'\n')

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--output',type=Path,required=True)
 args=parser.parse_args()
 output=args.output.resolve()
 if output.exists(): raise RuntimeError('Refusing existing evidence directory: '+str(output))
 start_hashes=hashes()
 if any(start_hashes[k]!=v for k,v in EXPECTED.items()): raise RuntimeError('Final runtime SHA does not match approved frozen code')
 if not (PROJECT/'artifacts/.gdignore').exists():raise RuntimeError('Historical source archives must be excluded from Godot class scanning')
 output.mkdir(parents=True)
 source=output/'frozen_runtime_source'
 source.mkdir();(source/'.gdignore').touch()
 driver_bytes=Path(__file__).read_bytes();(output/'long_sequence_driver.py').write_bytes(driver_bytes)
 for name in start_hashes:
  target=source/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((PROJECT/name).read_bytes())
 status_path=output/'sequence_status.json'
 state={'status':'RUNNING','started_utc':now(),'backend':'llvmpipe software Vulkan, not RTX5060Ti','independent_fresh_games':True,'not_a_continuation_of_old_cost_rule_runs':True,'gpu_exclusive':True,'rule_version':'1.5.1-energy-magazine','emission_cost':False,'territory_energy_per_cell':1,'machine_gun_window_sim_seconds':10,'source_sha256_start':start_hashes,'orchestrator_sha256':hashlib.sha256(driver_bytes).hexdigest(),'runs':[]}
 def update():save(status_path,state)
 def uncaught(kind,value,trace):
  state.update(status='FAIL',reason='orchestrator: '+str(value),completed_utc=now());update();sys.__excepthook__(kind,value,trace)
 sys.excepthook=uncaught
 active=None; interrupted=None
 def handle_signal(number,frame):
  nonlocal interrupted
  interrupted=signal.Signals(number).name
  state['interruption_requested']=interrupted;update()
  if active is not None:
   # run_tests gives the actual Godot child its own process group. Let runner reap it and preserve JSON.
   try:
    children=Path(f'/proc/{active.pid}/task/{active.pid}/children').read_text().split()
    for child in children:
     try:os.killpg(int(child),signal.SIGINT)
     except ProcessLookupError:pass
   except OSError:pass
 signal.signal(signal.SIGINT,handle_signal);signal.signal(signal.SIGTERM,handle_signal)
 env=os.environ.copy();env.update({'DISPLAY':':99','VK_ICD_FILENAMES':'/workspace/chromatic-tools/root/usr/share/vulkan/icd.d/lvp_icd.json','LD_LIBRARY_PATH':'/workspace/chromatic-tools/root/usr/lib/x86_64-linux-gnu','XDG_RUNTIME_DIR':'/tmp/cw-runtime','XDG_CACHE_HOME':'/tmp/cw-cache','XDG_CONFIG_HOME':'/tmp/cw-config','XDG_DATA_HOME':'/tmp/cw-data','LP_NUM_THREADS':'4'})
 update()
 for speed,duration,wall,deadline in [(1,1200,14400,14700),(2,120,2400,2700),(4,120,2400,2700)]:
  if interrupted or (output/'stop_after_current.flag').exists():
   state.update(status='PAUSED_AFTER_CURRENT',completed_utc=now());update();return 77
  if hashes()!=start_hashes:raise RuntimeError('Frozen code changed before next independent game; not starting it')
  folder=output/f'battle-{speed}x';folder.mkdir()
  started=now();started_epoch=time.time()
  meta={'started_utc':started,'git_commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=PROJECT,text=True).strip(),'source_sha256_before':hashes(),'backend':state['backend'],'cpu_affinity':'0-3','LP_NUM_THREADS':4,'cgroup_cpu_max':Path('/sys/fs/cgroup/cpu.max').read_text().strip(),'seed':20261017,'duration_sim_seconds':duration,'requested_speed':speed,'wall_budget_seconds':wall,'process_timeout_seconds':deadline,'independent_fresh_game':True,'not_a_continuation':True}
  save(folder/'source_metadata.json',meta)
  command=[sys.executable,str(PROJECT/'tools/run_tests.py'),'--godot',GODOT,'--suite','battle','--duration',str(duration),'--speed',str(speed),'--wall-seconds',str(wall),'--timeout',str(deadline),'--seed','20261017','--capacity','10000','--wrapper','taskset -c 0-3','--output',str(folder)]
  state['current']=f'{speed}x';state['current_directory']=str(folder);state['current_command']=command;update()
  print('LONG_SEQUENCE_START '+json.dumps({'speed':speed,'directory':str(folder),'utc':started,'command':command}),flush=True)
  with (folder/'sequence_runner.log').open('w') as log:
   active=subprocess.Popen(command,cwd=PROJECT,env=env,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
   state['current_runner_pid']=active.pid;update()
   returncode=active.wait()
  active=None
  meta.update(source_sha256_after=hashes(),completed_utc=now(),runner_returncode=returncode)
  meta['sources_unchanged']=meta['source_sha256_before']==meta['source_sha256_after'];save(folder/'source_metadata.json',meta)
  report_path=folder/'results.json'
  if not report_path.exists():raise RuntimeError('Runner exited without fresh results: '+str(folder))
  report=json.loads(report_path.read_text());report_started=datetime.datetime.strptime(report['started_utc'],'%Y%m%dT%H%M%S%fZ').replace(tzinfo=datetime.timezone.utc).timestamp()
  if report_path.stat().st_mtime<started_epoch or report_started<started_epoch:raise RuntimeError('Stale result or UTC startup mismatch: '+str(folder))
  suite=next(x for x in report['suites'] if x['name']=='battle')
  battles=list(folder.glob('battle_*x.json'))
  if len(battles)!=1 and not interrupted:raise RuntimeError('Missing or ambiguous final battle evidence: '+str(folder))
  battle=json.loads(battles[0].read_text()) if len(battles)==1 else {}
  result={'name':folder.name,'suite_status':report['status'],'actual_runner_exit':returncode,'actual_godot_exit':suite['returncode'],'sources_unchanged':meta['sources_unchanged'] and report.get('sources_unchanged_during_run',False),'final_validation_ok':battle.get('final_validation_ok',False),'sim_seconds':battle.get('sim_seconds'),'gpu_sim_seconds':battle.get('gpu_sim_seconds'),'target':duration,'natural_end':battle.get('natural_end'),'outcome':battle.get('outcome'),'timed_out':battle.get('timed_out'),'requested_speed':speed,'completed_sim_seconds_per_wall_second':battle.get('achieved_completed_sim_seconds_per_wall_second'),'wall_seconds':battle.get('wall_seconds'),'completion_fence_seconds':battle.get('completion_fence_wall_seconds'),'path':str(folder)}
  state['runs'].append(result);update();print('LONG_SEQUENCE_RESULT '+json.dumps(result),flush=True)
  if interrupted:
   state.update(status='INTERRUPTED',reason=interrupted+'; not a physics PASS or completed endurance result',completed_utc=now());update();return 130
  if report['status']=='FAIL' or returncode not in (0,77) or suite['returncode'] not in (0,77) or not result['sources_unchanged'] or not result['final_validation_ok']:
   state.update(status='FAIL',reason=f'{speed}x failed; later games not started',completed_utc=now());update();return 1
 state.update(status='NOT TESTED' if any(r['suite_status']=='NOT TESTED' for r in state['runs']) else 'PASS',current='complete',completed_utc=now())
 update();print('LONG_SEQUENCE_COMPLETE '+json.dumps(state),flush=True)
 return 77 if state['status']=='NOT TESTED' else 0

if __name__=='__main__':raise SystemExit(main())
