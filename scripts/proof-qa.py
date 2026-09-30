#!/usr/bin/env python3
"""Fail-closed runtime evidence. No missing launch/screenshot/log can become PASS."""
import datetime,hashlib,json,os,re,subprocess,sys,time,xml.etree.ElementTree as ET
from pathlib import Path
def main(work):
    q=json.loads((work/'request.json').read_text());sdk=os.environ.get('ANDROID_HOME','/usr/local/lib/android/sdk');adb=str(Path(sdk)/'platform-tools/adb');checks=[];logs=[]
    result={k:q[k] for k in ['request_id','app','package','commit_sha','artifact_sha256','version_name','version_code']};result.update(schema_version=1,mode='smoke',matrix=[],tests_passed=0,tests_failed=0,crashes=0,anrs=0,infra_failures=0,verdict='INFRA_FAIL',evidence=[],checks=checks,timestamp_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
    def call(*args,timeout=40):
        p=subprocess.run([adb,*args],capture_output=True,text=True,timeout=timeout);logs.append({'args':list(args),'rc':p.returncode,'out':p.stdout[-12000:],'err':p.stderr[-1200:]});return p
    def check(name,ok):checks.append({'name':name,'pass':bool(ok)});return bool(ok)
    def capture(name):
        p=subprocess.run([adb,'exec-out','screencap','-p'],capture_output=True,timeout=45)
        ok=p.returncode==0 and p.stdout.startswith(b'\x89PNG\r\n\x1a\n') and len(p.stdout)>1000
        if ok:
            f=work/(name+'.png');f.write_bytes(p.stdout);result['evidence'].append({'type':'screenshot','path':f.name,'sha256':hashlib.sha256(p.stdout).hexdigest()})
        return check(name,ok)
    try:
        api=call('shell','getprop','ro.build.version.sdk').stdout.strip();result['matrix']=[{'api':int(api),'arch':'x86_64','runtime':'actual_remote_emulator'}]
        if not check('requested_api',int(api)==q['target_api']):raise RuntimeError('DEVICE_API_MISMATCH')
        aapt=next(iter(sorted(Path(sdk).glob('build-tools/*/aapt'))),None)
        if not aapt:raise RuntimeError('AAPT_UNAVAILABLE')
        b=subprocess.run([str(aapt),'dump','badging',str(work/'app.apk')],capture_output=True,text=True,timeout=20)
        package=re.search(r"package: name='([^']+)' versionCode='([^']+)' versionName='([^']+)'",b.stdout)
        if not package or tuple(package.groups())!=(q['package'],str(q['version_code']),q['version_name']):raise RuntimeError('APK_IDENTITY_MISMATCH')
        check('artifact_metadata',True)
        ins=call('install','-r','-g',str(work/'app.apk'),timeout=120)
        if not check('install',ins.returncode==0 and 'Success' in ins.stdout):
            if any(x in ins.stdout+ins.stderr for x in ['INSTALL_FAILED','Failure [']):result['verdict']='APP_FAIL';return
            raise RuntimeError('ADB_INSTALL_INFRA')
        act=call('shell','cmd','package','resolve-activity','--brief',q['package']).stdout.strip().splitlines()
        activity=next((x for x in reversed(act) if '/' in x and q['package'] in x),None)
        if not check('launcher_resolved',activity is not None):result['verdict']='APP_FAIL';return
        call('logcat','-c');call('shell','am','force-stop',q['package'])
        p=call('shell','am','start','-W','-n',activity)
        if not check('cold_start',p.returncode==0 and 'Status: ok' in p.stdout and 'Error:' not in p.stdout):result['verdict']='APP_FAIL';return
        time.sleep(5)
        check('process_alive',bool(call('shell','pidof',q['package']).stdout.strip()));capture('cold_start')
        tree=call('shell','uiautomator','dump','/sdcard/window.xml',timeout=60)
        xml=call('shell','cat','/sdcard/window.xml').stdout;(work/'window.xml').write_text(xml)
        check('app_ui_visible',q['package'] in xml)
        call('shell','input','keyevent','3');time.sleep(1);p=call('shell','am','start','-W','-n',activity);time.sleep(2)
        check('resume',p.returncode==0 and bool(call('shell','pidof',q['package']).stdout.strip()));capture('resume')
        call('shell','settings','put','system','accelerometer_rotation','0');call('shell','settings','put','system','user_rotation','1');time.sleep(2);capture('landscape')
        call('shell','am','force-stop',q['package']);p=call('shell','am','start','-W','-n',activity);time.sleep(2)
        check('restart',p.returncode==0 and bool(call('shell','pidof',q['package']).stdout.strip()))
        # Optional generic private request steps; app-specific selectors travel encrypted.
        def ui():
            p=call('shell','uiautomator','dump','/sdcard/window.xml',timeout=60)
            if p.returncode:raise RuntimeError('UI_DUMP_INFRA')
            raw=call('shell','cat','/sdcard/window.xml').stdout
            try:root=ET.fromstring(raw)
            except ET.ParseError:raise RuntimeError('INVALID_UI_TREE_INFRA')
            return root,raw
        steps=q.get('ui_steps',[])
        if steps:
            call('shell','settings','put','system','user_rotation','0');time.sleep(2)
        if len(steps)>40:raise RuntimeError('TOO_MANY_UI_STEPS')
        for ordinal,step in enumerate(steps):
            kind=step.get('kind');name='flow_'+str(ordinal)+'_'+str(kind)
            if kind=='tap_text':
                root,raw=ui();needle=step['text'];nodes=[n for n in root.iter('node') if needle in n.get('text','')]
                if not check(name+'_selector',bool(nodes)):raise RuntimeError('UI_SELECTOR_UNRESOLVED_CHECK_SCROLL_OR_SCENARIO')
                bounds=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',nodes[0].get('bounds',''))
                if not bounds:raise RuntimeError('INVALID_UI_BOUNDS_INFRA')
                x1,y1,x2,y2=map(int,bounds.groups());p=call('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2));check(name,p.returncode==0);time.sleep(1)
            elif kind=='expect_text':
                root,raw=ui();check(name,any(step['text'] in n.get('text','') for n in root.iter('node')))
            elif kind=='expect_absent':
                root,raw=ui();check(name,not any(step['text'] in n.get('text','') for n in root.iter('node')))
            elif kind=='process_death_resume':
                call('shell','input','keyevent','3');time.sleep(1);call('shell','am','kill',q['package']);time.sleep(2)
                check(name+'_process_dead',not call('shell','pidof',q['package']).stdout.strip())
                p=call('shell','am','start','-W','-n',activity);time.sleep(2);check(name+'_relaunch',p.returncode==0)
            else:raise RuntimeError('UNSUPPORTED_PRIVATE_FLOW_STEP')
        if steps:capture('flow_complete')
        l=call('logcat','-d','-v','threadtime','-t','2500',timeout=60);(work/'logcat.txt').write_text(l.stdout)
        check('logcat_available',l.returncode==0 and bool(l.stdout.strip()))
        blocks=re.split(r'(?=FATAL EXCEPTION)',l.stdout)
        result['crashes']=sum('FATAL EXCEPTION' in x and q['package'] in x[:2200] for x in blocks)
        result['anrs']=len(re.findall(r'ANR in '+re.escape(q['package']),l.stdout))
        check('no_app_crash_anr',result['crashes']==0 and result['anrs']==0)
        result['verdict']='PASS' if all(x['pass'] for x in checks) else 'APP_FAIL'
    except Exception as e:
        result.update(verdict='INFRA_FAIL',infra_failures=1,blockers=[type(e).__name__+':'+str(e)[:180]])
    finally:
        result['tests_passed']=sum(x['pass'] for x in checks);result['tests_failed']=sum(not x['pass'] for x in checks)
        (work/'commands.json').write_text(json.dumps(logs,indent=2));(work/'result.json').write_text(json.dumps(result,indent=2))
if __name__=='__main__':main(Path(sys.argv[1]))
