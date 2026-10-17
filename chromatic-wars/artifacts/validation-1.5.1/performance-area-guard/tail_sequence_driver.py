#!/usr/bin/env python3
"""Continue the authorized, sequential final3+13+3 GPU matrices; stop on failure."""
import datetime,hashlib,importlib.util,json,os,subprocess,sys
from pathlib import Path
project=Path('/workspace/xyf2001.github.io/chromatic-wars')
base=project/'artifacts/validation-1.5.1/performance-area-guard'
state_path=base/'tail_sequence.json'
assert not state_path.exists(),'Refusing previous sequence evidence'
spec=importlib.util.spec_from_file_location('rules_runner',project/'tools/run_tests.py');runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
def hashes():
 d=runner.source_hashes(project,['gpu','weapon_validation','contact_energy','pool_integrity','settings','battle'])
 for n in ['tools/run_validation_matrix.py','tools/validation_matrix.gd','tools/peak_load_validation.gd']:d[n]=hashlib.sha256((project/n).read_bytes()).hexdigest()
 return d
initial=hashes()
assert initial['shaders/battle.glsl']=='c8c1007e7d7fd6b84f6a9b87857dd5e305f25075bfdb8cb94b702a9dd1d136b1'
assert initial['scripts/gpu_world.gd']=='73988ae98dca436c683a8db7ae3d131c4aa07514a77fae546170a7805f7c9007'
state={'status':'RUNNING','started_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'source_sha256_start':initial,'runs':[]}
def save():state_path.write_text(json.dumps(state,indent=2)+'\n')
def uncaught(kind,value,trace):
 state.update(status='FAIL',reason=str(value));save();sys.__excepthook__(kind,value,trace)
sys.excepthook=uncaught
save();(base/'tail_sequence_driver.py').write_bytes(Path(__file__).read_bytes())
env=os.environ.copy();env.update({'DISPLAY':':99','VK_ICD_FILENAMES':'/workspace/chromatic-tools/root/usr/share/vulkan/icd.d/lvp_icd.json','LD_LIBRARY_PATH':'/workspace/chromatic-tools/root/usr/lib/x86_64-linux-gnu','XDG_RUNTIME_DIR':'/tmp/cw-runtime','XDG_CACHE_HOME':'/tmp/cw-cache','XDG_CONFIG_HOME':'/tmp/cw-config','XDG_DATA_HOME':'/tmp/cw-data'})
peak=['--fixture','tools/peak_load_validation.gd','--cases','dense_pulse:1000:10000,dense_pulse:5000:10000,sniper_wall_pulse:1000:10000','--case-timeout','600']
for name,samples,warmup,cases,extra in [('peak-current',20,3,3,peak),('profile-current',12,3,13,['--profiling','--case-timeout','180']),('peak-profile-current',12,3,3,peak+['--profiling'])]:
 assert hashes()==initial,'Frozen code changed before '+name
 folder=base/name;assert not folder.exists(),'Refusing existing group evidence: '+str(folder)
 cmd=[sys.executable,str(project/'tools/run_validation_matrix.py'),'--godot','/opt/godot/4.6.3/Godot_v4.6.3-stable_linux.x86_64','--project',str(project),'--output',str(folder),'--samples',str(samples),'--warmup',str(warmup),'--timeout','900','--affinity','0-3','--threads','4']+extra
 state.update(current=name,current_command=cmd);save();print('TAIL_START '+name,flush=True)
 code=subprocess.call(cmd,cwd=project,env=env)
 assert code==0,f'{name} actual wrapper exit{code}'
 report=json.loads((folder/'comparison.json').read_text());data=json.loads((folder/'current_matrix.json').read_text())
 assert len(report['runs'])==1 and len(data['results'])==cases and not data['failed'],name+' incomplete cases'
 assert all(r['status']=='PASS' and len(r['samples'])==samples for r in data['results']),name+' incomplete or failed samples'
 r=report['runs'][0];assert r['returncode']==0 and r['status']=='PASS' and r['sources_unchanged_during_run'] and r['execution_tools_unchanged_during_run'] and not r['engine_errors'],name+' source/exit/error failure'
 assert hashes()==initial,'Frozen code changed during '+name
 state['runs'].append({'name':name,'actual_wrapper_exit':code,'actual_godot_exit':r['returncode'],'cases':cases,'samples':samples,'status':'PASS'});save();print('TAIL_COMPLETE '+name,flush=True)
state.update(status='PASS',completed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat());save();print('TAIL_ALL_PASS',flush=True)
