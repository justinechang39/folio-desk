#!/usr/bin/env python3
"""Build and test only against an isolated copy of a legacy-format session."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parent.parent
APP = ROOT / 'dist-release/Folio Desk.app/Contents/MacOS/folio-desk'
parser = argparse.ArgumentParser()
parser.add_argument('--skip-build', action='store_true')
parser.add_argument('--quick', action='store_true', help='Skip the one-minute stress workload')
parser.add_argument('--pdf', action='append', default=[])
args = parser.parse_args()
if len(args.pdf) not in (0, 2): parser.error('Provide two --pdf paths or none.')
if not args.skip_build: subprocess.run([str(ROOT / 'scripts/package.sh')], cwd=ROOT, check=True)
output = ROOT / 'work/native-production-test'
output.mkdir(parents=True, exist_ok=True)
fixtures = ROOT / 'tests/fixtures'

def run(name, mode, paths=(), expect_success=True, restore=False):
    report = output / (name + '.json')
    report.unlink(missing_ok=True)
    directory = output / (('migration-and-workspaces' if restore else name) + '-session')
    directory.mkdir(exist_ok=True)
    if mode == '--self-test' and not restore:
        docs = [dict(id=f'd{i}',path=str(fixtures / f),name=f,page=1,zoom=1,fit='page',rotation=0,offset=0) for i,f in enumerate(['questions.pdf','answers.pdf','reference.pdf'])]
        seed=dict(version=1, active='legacy', sidebar=True, appearance=dict(theme='orange',mode='dark'), views=[dict(id='legacy',name='Legacy workspace',layout='columns',documents=docs,slots=['d0','d1'],focused=0,linked=False),dict(id='other',name='Other workspace',layout='grid',documents=[],slots=[None]*4,focused=0,linked=False)])
        (directory / 'session.json').write_text(json.dumps(seed))
    env = dict(os.environ, FOLIO_TEST_SESSION_DIR=str(directory))
    samples=[]; started=time.monotonic()
    with (output / (name + '.log')).open('w') as log:
        process=subprocess.Popen([str(APP),mode,'--report',str(report),*(['--restore'] if restore else []),*map(str,paths)],env=env,stdout=log,stderr=log)
        try:
            while process.poll() is None:
                if time.monotonic()-started>180: raise TimeoutError(name)
                stat=subprocess.run(['ps','-o','rss=','-p',str(process.pid)],capture_output=True,text=True)
                if stat.stdout.strip(): samples.append(dict(seconds=round(time.monotonic()-started,2),rssMiB=round(int(stat.stdout.strip())/1024,2)))
                time.sleep(.5)
        finally:
            if process.poll() is None: process.kill();process.wait()
    assert (process.returncode==0)==expect_success,(name,process.returncode,(output/(name+'.log')).read_text())
    result=json.loads(report.read_text())
    if expect_success:
        assert result['checks'] and all(result['checks'].values()),result
        if mode=='--benchmark': assert result['steps']==1800,result
        if mode=='--self-test' and not restore:
            original=json.loads((directory/'session.before-native.json').read_text())
            assert original==seed,'Migration backup changed'
            saved=json.loads((directory/'session.json').read_text())
            assert len(saved['views'][0]['documents'])==3,'Original PDFs lost'
            assert saved['views'][0]['documents'][0].get('pointY') is not None,'Missing native viewport persistence'
    else: assert result.get('error'),result
    result['memorySamples']=samples
    result['processRSSPeakMiB']=max((s['rssMiB'] for s in samples),default=0)
    result['elapsedSeconds']=round(time.monotonic()-started,2)
    report.write_text(json.dumps(result,indent=2)+'\n')
    print(name,json.dumps({k:v for k,v in result.items() if k!='memorySamples'}),flush=True)

run('migration-and-workspaces','--self-test')
run('relaunch','--self-test',restore=True)
for file in ('invalid.pdf','notes.txt','locked.pdf'):
    run('reject-'+file,'--benchmark',[fixtures/file,fixtures/'answers.pdf'],False)
paths=[Path(p).expanduser().resolve() for p in args.pdf] or [fixtures/'long.pdf',fixtures/'questions.pdf']
if not args.quick: run('stress','--benchmark',paths)
print('Reports:',output)
