#!/usr/bin/env python3
"""Actual worker/HTTP acceptance and phase benchmarks; no generated text assertions."""
import argparse, json, pathlib, subprocess, tempfile, time, urllib.request, urllib.error, uuid, socket, os, shutil, ctypes, struct, threading
p=argparse.ArgumentParser(); p.add_argument('--binary',required=True); p.add_argument('--model',required=True); p.add_argument('--output',required=True); a=p.parse_args()
binary=str(pathlib.Path(a.binary).resolve()); model=str(pathlib.Path(a.model).resolve())
results={'version':subprocess.check_output([binary,'--version'],text=True).strip(),'samples':[], 'coldSamples':[], 'cancellation':[], 'process':{}}
# Darwin proc_taskinfo layout is defined in the installed SDK's sys/proc_info.h.
libproc=ctypes.CDLL('/usr/lib/libproc.dylib')
libproc.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
libproc.proc_pidinfo.restype=ctypes.c_int
class RSSSampler:
 def __init__(self,proc):
  self.proc=proc; self.peak=None
  self.thread=threading.Thread(target=self.run,daemon=True); self.thread.start()
 def run(self):
  while self.proc.poll() is None:
   info=ctypes.create_string_buffer(96)
   if libproc.proc_pidinfo(self.proc.pid,4,0,info,96)==96:
    self.peak=max(self.peak or 0,struct.unpack_from('=Q',info.raw,8)[0])
   time.sleep(.05)

def save(): pathlib.Path(a.output).write_text(json.dumps(results,indent=2))
def start(root, owner='foreground', parent=False):
 began=time.monotonic()
 log=open(pathlib.Path(root)/'worker.log','w')
 proc=subprocess.Popen([binary,'serve','--data-root',root,'--ownership',owner]+(['--parent-control'] if parent else []),stdin=subprocess.PIPE,stdout=log,stderr=log)
 proc.rss_sampler=RSSSampler(proc)
 deadline=time.monotonic()+20
 while time.monotonic()<deadline:
  try:
   d=json.loads((pathlib.Path(root)/'run/discovery.json').read_text())
   if d['identity']['pid']==proc.pid:
    assert d['identity']['buildID'] in results['version']
    d['_readySeconds']=time.monotonic()-began; d['_process']=proc
    return proc,d,log
  except (FileNotFoundError,json.JSONDecodeError): pass
  if proc.poll() is not None: raise AssertionError(pathlib.Path(log.name).read_text())
  time.sleep(.02)
 raise AssertionError('ready timeout')
def req(d,path,body=None,method=None):
 return urllib.request.Request(d['privateEndpoint']+'/mox/v1'+path,method=method,data=None if body is None else json.dumps(body).encode(),headers={'Authorization':'Bearer '+d['token'],'Content-Type':'application/json'})
def state(d): return json.load(urllib.request.urlopen(req(d,'/state'),timeout=5))
def generate(d,max_tokens=128,prompt=None,cancel_phase=None,delay=0):
 rid=str(uuid.uuid4()).upper(); began=time.monotonic(); first=None; phases={}; cancel_at=None; contents=0; terminal=None; usage=None
 body={'requestID':rid,'model':{'kind':'localDirectory','path':model},'messages':[{'role':'user','content':[{'type':'text','text':prompt or 'Write a detailed 4000-word history of mathematics, beginning with ancient civilizations. Continue with as much detail as possible.'}]}],'sampling':{'maxTokens':max_tokens,'temperature':0,'topP':1}}
 with urllib.request.urlopen(req(d,'/generations',body),timeout=40) as stream:
  expected=0
  for raw in stream:
   if not raw.startswith(b'data: '): continue
   e=json.loads(raw[6:]); assert e['sequence']==expected and e['requestID']==rid; expected+=1
   assert terminal is None
   if e['type']=='phase': phases[e['phase']]=time.monotonic()-began
   if e['type']=='contentDelta':
    if first is None: first=time.monotonic()-began
    contents+=len(e['text'].encode())
   if e['type']=='usage': usage=e['usage']
   trigger=(e['type']=='phase' and e.get('phase')==cancel_phase) or (cancel_phase=='decode' and e['type']=='contentDelta')
   if trigger and cancel_at is None:
    time.sleep(delay); cancel_at=time.monotonic()
    response=json.load(urllib.request.urlopen(req(d,'/generations/'+rid+'/cancel',method='POST'),timeout=5))
    assert response['requestID']==rid
   if e['type'] in ['finished','failed']: terminal=e
 assert terminal, 'no terminal'
 if cancel_phase:
  assert terminal.get('reason')=='cancelled',terminal
  assert cancel_at is not None
  if cancel_phase!='decode': assert contents==0,'cancel missed target phase'
 else: assert terminal.get('reason') in ['length','stop'],terminal
 snap=state(d); assert snap['activeLeases']==0
 return {'maxTokens':max_tokens,'requestID':rid,'ttft':first,'elapsed':time.monotonic()-began,'phases':phases,'usage':usage,'terminal':terminal['type'],'reason':terminal.get('reason'),'cancelWait':None if cancel_at is None else time.monotonic()-cancel_at,'cancelPhase':cancel_phase,'bytes':contents,'peakRSSBytes':d['_process'].rss_sampler.peak}
with tempfile.TemporaryDirectory(prefix='mox-m2-real-') as root:
 proc,d,log=start(root)
 try:
  conflict=subprocess.run([binary,'serve','--data-root',root],capture_output=True,timeout=10)
  assert conflict.returncode!=0; results['process']['secondOwnerRejected']=True
  generate(d,8,prompt="Say OK.")
  for n in [128,512,2048]:
   for i in range(3):
    result=generate(d,n); result['sample']=i; results['samples'].append(result);save()
  for phase in ['prefill','decode']:
   for i in range(3):
    result=generate(d,2048,prompt=('word '*5000+'Explain this at length.') if phase=='prefill' else None,cancel_phase=phase,delay=.05 if phase=='prefill' else 0)
    results['cancellation'].append(result); generate(d,8,prompt='Say OK.');save()
  # An incomplete, over-limit chunked body must receive 413 without being drained.
  u=urllib.parse.urlparse(d['privateEndpoint']); sock=socket.create_connection((u.hostname,u.port),timeout=5)
  sock.sendall(('POST /mox/v1/generations HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer '+d['token']+'\r\nTransfer-Encoding: chunked\r\n\r\n').encode())
  for _ in range(17):
   try: sock.sendall(b'100000\r\n'+b' '*1048576+b'\r\n')
   except (BrokenPipeError,ConnectionResetError): break
  response=sock.recv(8192); assert b'413' in response,response[:200]; sock.close()
  results['process']['chunkedLimitWithoutTerminator']=True; save()
 finally:
  proc.terminate(); proc.wait(timeout=35); log.close(); assert proc.returncode == 0, proc.returncode
  assert not (pathlib.Path(root)/'run/discovery.json').exists()
  results['process']['normalShutdownRemovedDiscovery']=True
for i in range(3):
 with tempfile.TemporaryDirectory(prefix='mox-m2-load-cancel-') as root:
  proc,d,log=start(root,'appOwned',True)
  try:
   results['cancellation'].append(generate(d,2048,cancel_phase='loading'))
   generate(d,8,prompt='Say OK.'); save()
  finally:
   proc.stdin.close(); proc.wait(timeout=35); log.close(); assert proc.returncode == 0, proc.returncode
   assert not (pathlib.Path(root)/'run/discovery.json').exists()
   results['process']['parentEOFDrains']=True
for n in [128,512,2048]:
 for i in range(3):
  with tempfile.TemporaryDirectory(prefix='mox-m2-cold-') as root:
   proc,d,log=start(root)
   try:
    sample=generate(d,n); sample['sample']=i
    sample['readySeconds']=d['_readySeconds']
    sample['processToFirstContentSeconds']=d['_readySeconds']+sample['ttft']
    results['coldSamples'].append(sample); save()
   finally:
    proc.terminate(); proc.wait(timeout=35); log.close(); assert proc.returncode == 0, proc.returncode
    assert not (pathlib.Path(root)/'run/discovery.json').exists()
save(); print('PASS real HTTP, 9 warm + 9 cold performance samples, RSS, 9 phase cancellations, process ownership')
