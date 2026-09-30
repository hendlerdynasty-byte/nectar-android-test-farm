#!/usr/bin/env python3
"""Fail-closed runtime evidence. No missing launch/screenshot/log can become PASS."""
import datetime,hashlib,json,os,re,subprocess,sys,time,tempfile,urllib.request,xml.etree.ElementTree as ET
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
        api=call('shell','getprop','ro.build.version.sdk').stdout.strip();result['matrix']=[{'api':int(api),'arch':'x86_64','runtime':'actual_remote_emulator','device_profile':q.get('device_profile','phone'),'display':call('shell','wm','size').stdout.strip(),'density':call('shell','wm','density').stdout.strip(),'font_scale':call('shell','settings','get','system','font_scale').stdout.strip(),'night_mode':call('shell','cmd','uimode','night').stdout.strip()}]
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
        assets=q.get('test_public_assets',[])
        if len(assets)>3:raise RuntimeError('ASSET_COUNT_LIMIT')
        for asset in assets:
            url=asset['url'];name=asset['filename']
            if not url.startswith('https://raw.githubusercontent.com/') or not re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9_.-]{0,79}',name):raise RuntimeError('UNSUPPORTED_PUBLIC_ASSET')
            with urllib.request.urlopen(url,timeout=60) as response:raw=response.read(20_000_001)
            if len(raw)>20_000_000 or hashlib.sha256(raw).hexdigest()!=asset['sha256']:raise RuntimeError('PUBLIC_ASSET_INTEGRITY_FAILURE')
            with tempfile.TemporaryDirectory(prefix='nectar-public-natural-') as temp:
                f=Path(temp)/name;f.write_bytes(raw);push=call('push',str(f),'/sdcard/Download/'+name,timeout=60)
                if push.returncode:raise RuntimeError('PUBLIC_ASSET_PUSH_FAILURE')
            call('shell','am','broadcast','-a','android.intent.action.MEDIA_SCANNER_SCAN_FILE','-d','file:///sdcard/Download/'+name)
            check('public_asset_hash_verified',True)
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
            (work/'current-window.xml').write_text(raw)
            try:root=ET.fromstring(raw)
            except ET.ParseError:raise RuntimeError('INVALID_UI_TREE_INFRA')
            return root,raw
        steps=q.get('ui_steps',[])
        if steps:
            call('shell','settings','put','system','user_rotation','0');time.sleep(2)
        if len(steps)>40:raise RuntimeError('TOO_MANY_UI_STEPS')
        for ordinal,step in enumerate(steps):
            kind=step.get('kind');name='flow_'+str(ordinal)+'_'+str(kind)
            if kind=='input_text':
                value=step.get('text','')
                if not re.fullmatch(r'[A-Za-z0-9 ]{1,120}',value):raise RuntimeError('UNSUPPORTED_TEXT_INJECTION_ALPHABET')
                p=call('shell','input','text',value.replace(' ','%s'));check(name,p.returncode==0);time.sleep(1)
                call('shell','input','keyevent','4');time.sleep(1)
            elif kind in ('tap_text','tap_description'):
                root,raw=ui();needle=step['text'];attribute='content-desc' if kind=='tap_description' else 'text';nodes=[n for n in root.iter('node') if (n.get(attribute,'')==needle if step.get('exact') else needle in n.get(attribute,''))]
                if not check(name+'_selector',bool(nodes)):raise RuntimeError('UI_SELECTOR_UNRESOLVED_CHECK_SCROLL_OR_SCENARIO')
                bounds=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',nodes[0].get('bounds',''))
                if not bounds:raise RuntimeError('INVALID_UI_BOUNDS_INFRA')
                x1,y1,x2,y2=map(int,bounds.groups());p=call('shell','input','tap',str((x1+x2)//2),str((y1+y2)//2));check(name,p.returncode==0);time.sleep(1)
            elif kind in ('scroll_forward','scroll_backward'):
                root,raw=ui();nodes=[n for n in root.iter('node') if n.get('scrollable')=='true']
                if not nodes:raise RuntimeError('NO_SCROLL_CONTAINER_INFRA')
                bounds=re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',nodes[0].get('bounds',''))
                if not bounds:raise RuntimeError('INVALID_SCROLL_BOUNDS_INFRA')
                x1,y1,x2,y2=map(int,bounds.groups());x=(x1+x2)//2;a=y1+(y2-y1)*8//10;b=y1+(y2-y1)*2//10
                if kind=='scroll_backward':a,b=b,a
                p=call('shell','input','swipe',str(x),str(a),str(x),str(b),'400');check(name,p.returncode==0);time.sleep(1)
            elif kind=='expect_text':
                root,raw=ui();check(name,any(step['text'] in n.get('text','') for n in root.iter('node')))
            elif kind=='expect_absent':
                root,raw=ui();check(name,not any(step['text'] in n.get('text','') for n in root.iter('node')))
            elif kind=='process_death_resume':
                call('shell','input','keyevent','3');time.sleep(1)
                before=call('shell','pidof',q['package']).stdout.strip().split()
                if not before or any(not x.isdigit() for x in before):raise RuntimeError('PROCESS_DEATH_TARGET_UNAVAILABLE')
                # am kill may intentionally retain a process on new Android/large-screen configurations.
                # Debuggable APK: inject actual SIGKILL as that app UID, never another app or host process.
                for pid in before:
                    killed=call('shell','run-as',q['package'],'/system/bin/kill','-9',pid)
                    if killed.returncode:raise RuntimeError('OWN_UID_PROCESS_DEATH_INJECTION_UNAVAILABLE')
                time.sleep(2);dead=not call('shell','pidof',q['package']).stdout.strip()
                if not check(name+'_process_dead',dead):raise RuntimeError('PROCESS_DEATH_INJECTION_DID_NOT_TERMINATE')
                result.setdefault('fault_injections',[]).append({'kind':'process_death','method':'SIGKILL_AS_OWN_APP_UID','target_package':q['package'],'prior_pids':before,'absence_verified':True})
                p=call('shell','am','start','-W','-n',activity);time.sleep(2);check(name+'_relaunch',p.returncode==0)
            else:raise RuntimeError('UNSUPPORTED_PRIVATE_FLOW_STEP')
        if steps:capture('flow_complete')
        for asset in assets:
            checksum=call('shell','sha256sum','/sdcard/Download/'+asset['filename'])
            if checksum.returncode:raise RuntimeError('SOURCE_REHASH_TOOL_UNAVAILABLE')
            check('public_asset_source_unchanged',checksum.stdout.split()[0]==asset['sha256'])
        l=call('logcat','-d','-v','threadtime','-t','2500',timeout=60);(work/'logcat.txt').write_text(l.stdout)
        check('logcat_available',l.returncode==0 and bool(l.stdout.strip()))
        blocks=re.split(r'(?=FATAL EXCEPTION)',l.stdout)
        result['crashes']=sum('FATAL EXCEPTION' in x and q['package'] in x[:2200] for x in blocks)
        result['anrs']=len(re.findall(r'ANR in '+re.escape(q['package']),l.stdout))
        check('no_app_crash_anr',result['crashes']==0 and result['anrs']==0)
        result['verdict']='PASS' if all(x['pass'] for x in checks) else 'APP_FAIL'
    except Exception as e:
        result.update(verdict='INFRA_FAIL',infra_failures=1,blockers=[type(e).__name__+':'+str(e)[:180]])
        try:capture('failure')
        except Exception:pass
    finally:
        result['tests_passed']=sum(x['pass'] for x in checks);result['tests_failed']=sum(not x['pass'] for x in checks)
        (work/'commands.json').write_text(json.dumps(logs,indent=2));(work/'result.json').write_text(json.dumps(result,indent=2))
if __name__=='__main__':main(Path(sys.argv[1]))
