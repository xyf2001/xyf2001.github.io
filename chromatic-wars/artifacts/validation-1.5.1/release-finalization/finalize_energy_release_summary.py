#!/usr/bin/env python3
"""Bind completed actual evidence to release bytes; never infer unrun PASS."""
import datetime as dt
import hashlib
import json
import re
from pathlib import Path
import runpy

ROOT=Path('/workspace/xyf2001.github.io/chromatic-wars')
EVIDENCE=ROOT/'artifacts/validation-1.5.1'
SHADER='c8c1007e7d7fd6b84f6a9b87857dd5e305f25075bfdb8cb94b702a9dd1d136b1'
HOST='73988ae98dca436c683a8db7ae3d131c4aa07514a77fae546170a7805f7c9007'
PINBALL='0b806c2a82a3fa09aaeee2e63d1872710e836b08fcc950c3d1e5e9797043ecc6'

def read(path):return json.loads(path.read_text())
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def require(ok,message):
    if not ok:raise RuntimeError(message)

def main():
    for name,expected in [('shaders/battle.glsl',SHADER),('scripts/gpu_world.gd',HOST),('scripts/pinball_physics.gd',PINBALL)]:
        require(digest(ROOT/name)==expected,'Unreviewed runtime source: '+name)
    hashes=runpy.run_path(str(ROOT/'tools/package_delivery.py'))['runtime_source_hashes'](ROOT)
    rules=read(EVIDENCE/'rules-area-guard/SUMMARY.json')
    require(rules.get('status')=='PASS' and rules.get('shader_sha256')==SHADER and rules.get('host_sha256')==HOST,'Current rule evidence failed or differs from runtime')
    wall=read(EVIDENCE/'rules-area-guard/wall-probe-summary.json')
    require(wall.get('status')=='PASS','Actual final wall probes not PASS')
    perf=read(EVIDENCE/'performance-area-guard/SUMMARY.json')
    require(perf.get('shader_sha256')==SHADER and perf.get('actual_cases_passed')==44,'Final performance set incomplete or different source')
    for group in perf['groups']:
        for item in group['runs']:
            require(item.get('status')=='PASS' and item.get('actual_exit')==0 and item.get('source_hashes_unchanged') and item.get('execution_tool_hashes_unchanged') and not item.get('engine_errors'),'Final performance case or provenance failure')
    runtime=read(EVIDENCE/'runtime-final/runtime_results.json')
    require(runtime.get('status')=='PASS' and len(runtime.get('checks',[]))==10 and all(x.get('status')=='PASS' for x in runtime['checks']),'Final main-scene assertions not completed')
    main_meta=read(EVIDENCE/'runtime-final/runtime_metadata.json')
    build=read(EVIDENCE/'export-final/build_metadata.json')
    require(build.get('status')=='PASS','Final import/export/PCK not completed')
    for meta in [main_meta,build['import'],build['export'],build['pck']]:
        require(meta.get('status')=='PASS' and meta.get('actual_exit_code')==0 and meta.get('engine_error_count')==0 and meta.get('sources_unchanged'),'Build/runtime actual process or source failure')
        require(all(meta['source_sha256_after'].get(k)==v for k,v in hashes.items()),'Build/runtime did not validate current complete runtime bytes')
    pck=read(EVIDENCE/'export-final/export_pck.json')
    require(pck.get('status')=='PASS' and pck.get('main_pack_sha256')==digest(ROOT/'export/颜色大战.exe'),'Actual embedded package identity mismatch')
    seq=read(EVIDENCE/'long-sequence-final/sequence_status.json')
    require(seq.get('status')=='INTERRUPTED' and seq.get('interruption_requested')=='SIGINT' and len(seq.get('runs',[]))==3,'Expected user-stopped final sequence')
    battles=[]
    for speed in (1,2):
        folder=EVIDENCE/f'long-sequence-final/battle-{speed}x'
        meta=read(folder/'source_metadata.json')
        require(meta.get('sources_unchanged') and all(digest(ROOT/k)==v for k,v in meta['source_sha256_after'].items()),'Long-battle source or validator differs')
        result=read(folder/'results.json')
        require(result.get('status') in ('PASS','NOT TESTED') and result.get('sources_unchanged_during_run'),'Long-battle result failed or changed source')
        suite=next(x for x in result['suites'] if x['name']=='battle')
        require(suite.get('returncode') in (0,77) and not suite.get('engine_errors') and all(x.get('status')!='FAIL' for x in suite.get('results',[])),'Long-battle actual process/rule failed')
        files=list(folder.glob('battle_*x.json'))
        require(len(files)==1,'Long-battle final result missing or ambiguous')
        data=read(files[0])
        require(data.get('final_validation_ok') and not data.get('runtime_error') and not data.get('pinball_error'),'Long-battle final GPU fence or physics failed')
        battles.append({'requested_speed':speed,'suite_status':result['status'],'actual_godot_exit':suite['returncode'],
            'target_sim_seconds':data['target_duration_sim_seconds'],'completed_sim_seconds':data['sim_seconds'],
            'gpu_sim_seconds':data['gpu_sim_seconds'],'wall_seconds':data['wall_seconds'],
            'final_gpu_validation':data['final_validation_ok'],'natural_end':data['natural_end'],
            'outcome':data['outcome'],'timed_out':data['timed_out'],
            'requested_duration_covered':data['sim_seconds']+1/120>=data['target_duration_sim_seconds'],
            'twenty_minute_endurance_observed':data['sim_seconds']+1/120>=1200,
            'result':str(files[0].relative_to(ROOT))})
    folder=EVIDENCE/'long-sequence-final/battle-4x'
    meta=read(folder/'source_metadata.json');result=read(folder/'results.json')
    suite=next(x for x in result['suites'] if x['name']=='battle')
    require(meta.get('sources_unchanged') and result.get('sources_unchanged_during_run') and all(digest(ROOT/k)==v for k,v in meta['source_sha256_after'].items()),'Interrupted-run source mismatch')
    require(suite['returncode']==-15 and not suite.get('engine_errors') and all(x.get('status')!='FAIL' for x in suite.get('results',[])),'Unexpected error before user-requested interruption')
    lines=(folder/'battle.log').read_text().splitlines()
    progress=[json.loads(line.split('BATTLE_WALL_PROGRESS ',1)[1]) for line in lines if 'BATTLE_WALL_PROGRESS ' in line]
    require(bool(progress),'Missing interrupted-run telemetry')
    last=progress[-1]
    stop={'status':'INTERRUPTED BY USER','reason':'User explicitly requested 停止测试 直接输出; no more game executions were started.',
        'signal_forwarding_note':'Initial orchestrator SIGINT could not enumerate /proc/PID/task/PID/children on this kernel; actual Godot child168777 was identified by PPid and stopped with SIGTERM.',
        'actual_godot_exit':suite['returncode'],'actual_runner_exit':meta['runner_returncode'],
        'last_periodic_progress':last,'final_gpu_fence_completed':False,
        'not_a_gameplay_test_failure_claim':True,'raw_runner_status_preserved':result['status']}
    (folder/'STOP_REASON.json').write_text(json.dumps(stop,ensure_ascii=False,indent=2)+'\n')
    battles.append({'requested_speed':4,'suite_status':result['status'],'scope_status':'INTERRUPTED BY USER','actual_godot_exit':suite['returncode'],
        'target_sim_seconds':120,'completed_sim_seconds':None,'gpu_sim_seconds':None,'wall_seconds':None,
        'last_periodic_progress':last,'final_gpu_validation':False,'natural_end':None,'outcome':None,'timed_out':False,
        'requested_duration_covered':False,'twenty_minute_endurance_observed':False,'result':str((folder/'STOP_REASON.json').relative_to(ROOT))})
    limits=[
        'All GPU executions used Linux llvmpipe LLVM19.1.7 software Vulkan; RTX5060Ti FPS, physical VRAM and driver-internal blocked CPU time were not measured.',
        'The actual Windows PE/embedded PCK was exported and loaded by Linux Godot, not executed on native Windows.',
        'Sniper integer parent/child70/30 is preserved and tested; the requested ratio allocation semantics remain explicitly unconfirmed.',
        'Finite physical-pool backpressure or manual gun_rate0 pause can extend the nominal10-s magazine period; energy is preserved.',
        'Left-side wide balls can form genuine entrance support equilibria and require value-preserving relaunch; arbitrary user peg geometry is not guaranteed passable.',
        'Particle-pair pass precedes serial entity events; this is not a globally time-sorted continuous multi-body solver.',
        'The4x run was stopped at the explicit user request, without a final GPU fence or complete120-s result; periodic telemetry is not a completed test PASS.',
    ]
    if not battles[0]['twenty_minute_endurance_observed']:limits.append('The normal-speed game ended naturally or reached its recorded real-time budget before1200sim seconds;20-min full-system endurance is not marked PASS.')
    if not battles[0]['natural_end']:limits.append('The normal-speed endurance checkpoint did not establish a natural winner; no victory was imposed by elapsed time.')
    # These two files are evidence indexes, not raw individual test output.
    # Replace their original waiting note only after all real results passed the checks above.
    coverage={'sequence_status':seq['status'],'sequence':'artifacts/validation-1.5.1/long-sequence-final/sequence_status.json',
        'actual_independent_battles':battles,'scope':'Each requested-duration checkpoint and the independent1200-s endurance flag remain distinct; no forced winner.'}
    rules['new_rule_full_game_and_endurance']=coverage
    rules['performance']='Current-source44actual cases passed; see../performance-area-guard/SUMMARY.json.'
    rules['actual_main_and_export']={'main_scene_checks':10,'main':'artifacts/validation-1.5.1/runtime-final/runtime_results.json',
        'export_and_linux_embedded_PCK':'artifacts/validation-1.5.1/export-final/build_metadata.json',
        'native_Windows_execution':'NOT TESTED'}
    perf['long_endurance']=coverage
    (EVIDENCE/'rules-area-guard/SUMMARY.json').write_text(json.dumps(rules,ensure_ascii=False,indent=2)+'\n')
    (EVIDENCE/'performance-area-guard/SUMMARY.json').write_text(json.dumps(perf,ensure_ascii=False,indent=2)+'\n')
    summary={'status':'PARTIAL','generated_utc':dt.datetime.now(dt.timezone.utc).isoformat(),
        'rule_version':'1.5.1-energy-magazine','runtime_source_sha256':hashes,
        'actual_final_rules':rules,'wall_probe_evidence':'artifacts/validation-1.5.1/rules-area-guard/wall-probe-summary.json',
        'actual_performance':perf,'main_scene_checks':10,'main_scene_result':'artifacts/validation-1.5.1/runtime-final/runtime_results.json',
        'windows_export_and_pck':'artifacts/validation-1.5.1/export-final/build_metadata.json',
        'windows_exe_sha256':digest(ROOT/'export/颜色大战.exe'),
        'unchanged_pinball_cpu_evidence':{'source_sha256':PINBALL,'sim_seconds':4200,'cpu_assertions':[23,17,27],'result':'artifacts/pinball_validation_summary.json','not_a_substitute_for_gpu_endurance':True},
        'actual_independent_battles':battles,'limitations':limits,
        'partial_reason':'Measured current-source checks succeeded within their recorded scope; hardware, native Windows and explicitly unconfirmed semantics prevent a claim of complete acceptance.'}
    (EVIDENCE/'release_validation.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps({'status':summary['status'],'battles':battles,'windows_exe_sha256':summary['windows_exe_sha256']},ensure_ascii=False,indent=2))

if __name__=='__main__':main()
