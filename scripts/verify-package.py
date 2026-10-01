#!/usr/bin/env python3
"""Validate a moved release worker, resource failure, signing and local-only networking."""
import argparse, hashlib, json, os, pathlib, shutil, subprocess, sys, tempfile
p=argparse.ArgumentParser(); p.add_argument('--app',required=True); p.add_argument('--model',required=True); p.add_argument('--output',required=True); p.add_argument('--configuration',choices=['Debug','Release'],default='Release'); a=p.parse_args()
app=pathlib.Path(a.app).resolve(); model=pathlib.Path(a.model).resolve()
def fingerprint():
 return {str(f.relative_to(model)):hashlib.sha256(f.read_bytes()).hexdigest() for f in model.rglob('*') if f.is_file()}
before=fingerprint(); results={}
profile='(version 1)(allow default)(deny network-outbound)(allow network-outbound (remote ip "localhost:*"))'
with tempfile.TemporaryDirectory(prefix='Mox 独立产物 ') as folder:
 root=pathlib.Path(folder); moved=root/'本地聊天.app'
 subprocess.run(['/usr/bin/ditto',str(app),str(moved)],check=True)
 subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(moved)],check=True,capture_output=True)
 results['strictSignature']=True
 main=moved/'Contents/MacOS/Mox'
 symbols=subprocess.run(['/usr/bin/nm',str(main)],check=True,capture_output=True,text=True).stdout
 assert 'mlx_' not in symbols and '$s3MLX' not in symbols
 results['mainHasNoMLXSymbols']=True
 worker=moved/'Contents/Helpers/MoxWorker.app/Contents/MacOS/mox'
 libraries=list(moved.rglob('default.metallib')); assert len(libraries)==1
 assert len(list(moved.rglob('*LICENSE*')))>=20
 probe='import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); c=socket.socket(); c.connect(s.getsockname()); s.accept()[0].close(); c.close(); s.close(); x=socket.socket(); x.settimeout(1)\ntry: x.connect(("1.1.1.1",443))\nexcept PermissionError: print("DENIED_EXTERNAL_ALLOWED_LOOPBACK")\nelse: raise AssertionError("external networking was not denied")'
 result=subprocess.run(['/usr/bin/sandbox-exec','-p',profile,sys.executable,'-c',probe],capture_output=True,text=True,timeout=10)
 assert result.returncode==0 and 'DENIED_EXTERNAL_ALLOWED_LOOPBACK' in result.stdout,result.stderr
 results['networkPolicyVerified']=True
 version=subprocess.run([str(worker),'--version'],capture_output=True,text=True,check=True).stdout.strip()
 assert '('+a.configuration+')' in version,version
 results['configurationReported']=True
 command=[str(worker),'chat','--data-root',str(root/'数据'),'--model-path',str(model),'--prompt','Say hello briefly.','--max-tokens','8','--temperature','0']
 result=subprocess.run(['/usr/bin/sandbox-exec','-p',profile]+command,cwd=root,env={**os.environ,'PATH':'/usr/bin:/bin'},capture_output=True,text=True,timeout=45)
 assert result.returncode==0 and result.stdout.strip(),result.stderr
 assert not (root/'数据/run/discovery.json').exists()
 results['movedWorkerOfflineCleanPATH']=True
 # Use bare argv[0], a PATH lookup and an unrelated working directory.
 path_command=['mox']+command[1:]
 path_command[3]=str(root/'PATH 数据')
 result=subprocess.run(path_command,cwd=root,env={**os.environ,'PATH':str(worker.parent)+':/usr/bin:/bin'},capture_output=True,text=True,timeout=45)
 assert result.returncode==0 and result.stdout.strip(),result.stderr
 assert not (root/'PATH 数据/run/discovery.json').exists()
 results['barePATHStartsOwnedWorker']=True
 libraries[0].unlink()
 command[3]=str(root/'缺失资源数据')
 result=subprocess.run(command,cwd=root,env={**os.environ,'PATH':'/usr/bin:/bin'},capture_output=True,text=True,timeout=25)
 assert result.returncode!=0 and not result.stdout.strip(),result
 results['missingResourceFails']=True
 assert not (root/'缺失资源数据/run/discovery.json').exists()
assert fingerprint()==before
results['modelUnchanged']=True
pathlib.Path(a.output).write_text(json.dumps(results,indent=2)); print(json.dumps(results))
