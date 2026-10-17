#!/usr/bin/env python3
"""Run real native WebKit + Rust IPC against synthetic PDFs in an isolated app."""
import json, os, pathlib, shutil, subprocess, uuid
root=pathlib.Path(__file__).resolve().parent.parent
work=root/'work';work.mkdir(exist_ok=True)
identifier='io.github.justinechang39.foliodesk.'+uuid.uuid4().hex+'.smoketest'
config=work/'smoke-config.json'
config.write_text(json.dumps({'identifier':identifier,'app':{'windows':[{'label':'main','title':'Folio Desk test','width':1380,'height':920,'visible':True,'focus':False}]}}))
subprocess.run(['npm','run','tauri','--','build','--debug','--no-bundle','--features','native-smoke','--config',str(config)],cwd=root,check=True)
env=os.environ.copy()
try:
    for phase in ('initial','restore'):
        report=work/f'native-{phase}.json'
        report.unlink(missing_ok=True)
        env['FOLIO_SMOKE_REPORT']=str(report)
        env['FOLIO_SMOKE_FILES']=json.dumps([str(root/'tests/fixtures/questions.pdf'),str(root/'tests/fixtures/answers.pdf')] if phase=='initial' else [])
        with (work/f'native-{phase}.log').open('wb') as log:
            result=subprocess.run([str(root/'src-tauri/target/debug/folio-desk')],env=env,cwd=root,stdout=log,stderr=subprocess.STDOUT,timeout=60)
        data=json.loads(report.read_text())
        assert data['passed'],data
        assert data['initialPage']==(1 if phase=='initial' else 2),data
        print(f'PASS native {phase}: {data}')
finally:
    # This unique test identifier is never the production app's data folder.
    shutil.rmtree(pathlib.Path.home()/'Library/Application Support'/identifier,ignore_errors=True)
