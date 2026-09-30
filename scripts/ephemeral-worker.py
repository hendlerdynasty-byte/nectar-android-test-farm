#!/usr/bin/env python3
"""Private APKs only inside authenticated ephemeral envelopes, then runner temp."""
import base64, datetime, hashlib, io, json, os, re, shutil, subprocess, sys, tempfile, time, uuid, zipfile
from pathlib import Path
from envelope import api,keypair,seal,unseal,put_file,get_file
def main():
    rid=os.environ['REQUEST_ID'];uuid.UUID(rid)
    repo=os.environ['GITHUB_REPOSITORY'];ref='transport-'+rid;work=Path(os.environ['RUNNER_TEMP'])/'nectar-private';work.mkdir(mode=0o700)
    private,public=keypair();workflow_sha=os.environ['GITHUB_SHA']
    api(f'repos/{repo}/git/refs',{'ref':'refs/heads/'+ref,'sha':workflow_sha})
    manifest={'request_id':rid,'workflow_commit':workflow_sha,'public_key':public.decode(),'expires_seconds':1800}
    put_file(repo,ref,'transport-public.json',json.dumps(manifest).encode(),'Publish ephemeral public transport key')
    print('EPHEMERAL_KEY_READY '+rid,flush=True)
    request=None;receiver=None;result=None;response=None
    try:
        deadline=time.monotonic()+600
        while time.monotonic()<deadline:
            try:payload=get_file(repo,ref,'payload.enc');break
            except RuntimeError:time.sleep(8)
        else:raise RuntimeError('PAYLOAD_NOT_RECEIVED')
        plain=unseal(private,payload,rid,'input')
        with zipfile.ZipFile(io.BytesIO(plain)) as z:
            if set(z.namelist())!={'request.json','app.apk'} or len(z.namelist())!=2:raise ValueError('BAD_PACKAGE_MEMBERS')
            if sum(x.file_size for x in z.infolist())>80_000_000:raise ValueError('BUNDLE_TOO_LARGE')
            request=json.loads(z.read('request.json'));apk=z.read('app.apk')
        if request['request_id']!=rid:raise ValueError('REQUEST_ID_MISMATCH')
        if hashlib.sha256(apk).hexdigest()!=request['artifact_sha256']:raise ValueError('ARTIFACT_INTEGRITY_FAIL')
        if not re.fullmatch(r'[a-zA-Z][\w]*(?:\.[a-zA-Z][\w]*)+',request['package']):raise ValueError('BAD_PACKAGE')
        if not re.fullmatch(r'[0-9a-f]{40}',request['commit_sha']):raise ValueError('BAD_SOURCE_COMMIT')
        receiver=request['return_public_key'].encode();(work/'app.apk').write_bytes(apk);(work/'request.json').write_text(json.dumps(request))
        del apk,plain,payload
        profile=request.get('device_profile','phone');scale=float(request.get('font_scale',1));dark=request.get('dark_mode',False)
        if profile not in ('phone','tablet') or not 1<=scale<=2 or not isinstance(dark,bool):raise ValueError('UNSUPPORTED_DEVICE_MATRIX')
        env=os.environ.copy();env.update({'TARGET_API':str(request['target_api']),'GITHUB_ENV':str(work/'runtime.env'),'TEST_DEVICE_PROFILE':profile,'TEST_FONT_SCALE':str(scale),'TEST_DARK_MODE':'yes' if dark else 'no'})
        p=subprocess.run(['bash','scripts/boot-proof.sh'],env=env,timeout=1400,capture_output=True,text=True)
        (work/'boot.log').write_text(p.stdout+p.stderr)
        if p.returncode:raise RuntimeError('EMULATOR_BOOT_FAILED')
        result=subprocess.run([sys.executable,'scripts/proof-qa.py',str(work)],env=env,timeout=420,capture_output=True,text=True)
        (work/'test-driver.log').write_text(result.stdout+result.stderr)
        response=json.loads((work/'result.json').read_text())
    except Exception as e:
        response={'schema_version':1,'request_id':rid,'verdict':'INFRA_FAIL','infra_failures':1,'tests_passed':0,'tests_failed':0,'blockers':[type(e).__name__+':'+str(e)[:180]],'timestamp_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()}
        if request:response.update({k:request[k] for k in ['app','package','commit_sha','artifact_sha256','version_name','version_code']})
        (work/'result.json').write_text(json.dumps(response,indent=2))
    finally:
        # Never export the app APK, input request public key or process secret files.
        out=io.BytesIO()
        with zipfile.ZipFile(out,'w',zipfile.ZIP_DEFLATED) as z:
            for p in sorted(work.rglob('*')):
                if p.is_file() and p.name not in ['app.apk','request.json','runtime.env']:z.write(p,p.relative_to(work).as_posix())
        if receiver:
            put_file(repo,ref,'result.enc',seal(receiver,out.getvalue(),rid,'output'),'Return encrypted runtime evidence')
        print('NECTAR_RESULT='+json.dumps(response,sort_keys=True),flush=True)
        shutil.rmtree(work,ignore_errors=True);private=b''
    return 0 if response and response['verdict']=='PASS' else 1
if __name__=='__main__':sys.exit(main())
