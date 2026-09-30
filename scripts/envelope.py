"""Generic ephemeral RSA-OAEP/AES-GCM transport; never stores keys in Git."""
import base64, json, os, subprocess, urllib.request
from pathlib import Path
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
MAGIC=b'NCT1'
def keypair():
    k=rsa.generate_private_key(public_exponent=65537,key_size=3072)
    return k.private_bytes(serialization.Encoding.PEM,serialization.PrivateFormat.PKCS8,serialization.NoEncryption()),k.public_key().public_bytes(serialization.Encoding.PEM,serialization.PublicFormat.SubjectPublicKeyInfo)
def seal(public,data,request_id,kind):
    pub=serialization.load_pem_public_key(public)
    if not isinstance(pub,rsa.RSAPublicKey) or pub.key_size<3072:raise ValueError('WEAK_OR_INVALID_KEY')
    key=os.urandom(32);nonce=os.urandom(12)
    wrapped=pub.encrypt(key,padding.OAEP(mgf=padding.MGF1(hashes.SHA256()),algorithm=hashes.SHA256(),label=None))
    aad=MAGIC+request_id.encode()+kind.encode()
    return MAGIC+len(wrapped).to_bytes(2,'big')+wrapped+nonce+AESGCM(key).encrypt(nonce,data,aad)
def unseal(private,data,request_id,kind):
    if len(data)<420 or data[:4]!=MAGIC:raise ValueError('BAD_ENVELOPE')
    n=int.from_bytes(data[4:6],'big')
    if n!=384:raise ValueError('BAD_KEY_SIZE')
    priv=serialization.load_pem_private_key(private,password=None)
    key=priv.decrypt(data[6:6+n],padding.OAEP(mgf=padding.MGF1(hashes.SHA256()),algorithm=hashes.SHA256(),label=None))
    nonce=data[6+n:18+n];return AESGCM(key).decrypt(nonce,data[18+n:],MAGIC+request_id.encode()+kind.encode())
def api(path,payload=None):
    cmd=['gh','api',path]
    if payload is not None:
        cmd+=['--method','POST','--input','-']
    p=subprocess.run(cmd,input=json.dumps(payload) if payload is not None else None,capture_output=True,text=True)
    if p.returncode:raise RuntimeError('GITHUB_API_FAILED '+p.stderr[:100])
    return json.loads(p.stdout)
def put_file(repo,branch,path,data,message):
    # REST contents create/update method PUT; stdout contains only metadata.
    body={'message':message,'branch':branch,'content':base64.b64encode(data).decode()}
    p=subprocess.run(['gh','api',f'repos/{repo}/contents/{path}','-X','PUT','--input','-'],input=json.dumps(body),capture_output=True,text=True)
    if p.returncode:raise RuntimeError('GITHUB_PUBLISH_FAILED '+p.stderr[:100])
    return json.loads(p.stdout)['commit']['sha']
def get_file(repo,branch,path):
    x=api(f'repos/{repo}/contents/{path}?ref={branch}')
    if x.get('encoding')=='base64' and x.get('content'):return base64.b64decode(x['content'])
    u=x.get('download_url','')
    if not u.startswith('https://raw.githubusercontent.com/'+repo+'/'):raise ValueError('UNTRUSTED_TRANSPORT_URL')
    with urllib.request.urlopen(u,timeout=60) as r:data=r.read(85_000_001)
    if len(data)>85_000_000:raise ValueError('OVERSIZED_TRANSPORT')
    return data
