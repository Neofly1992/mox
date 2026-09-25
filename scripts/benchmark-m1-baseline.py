#!/usr/bin/env python3
import json, subprocess, time, re, pathlib
root=pathlib.Path(__file__).resolve().parent.parent
samples=[]
for tokens in [128,512,2048]:
 for sample in range(3):
  command=[str(root/'.build/m1/mox'),'chat','--model-path',str(root/'.build/test-models/qwen2.5-0.5b-4bit'),'--prompt','Write a detailed 4000-word history of mathematics, beginning with ancient civilizations. Continue with as much detail as possible.','--max-tokens',str(tokens),'--temperature','0']
  started=time.monotonic()
  proc=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  first=proc.stdout.read(1); ttft=time.monotonic()-started
  out,err=proc.communicate(timeout=180)
  match=re.search(rb'prompt_tokens=(\d+) output_tokens=(\d+) prefill_s=([\d.eE+-]+) decode_s=([\d.eE+-]+)',err)
  assert proc.returncode==0 and match, err.decode()
  prompt,output,prefill,decode=map(float,match.groups())
  samples.append(dict(maxTokens=tokens,sample=sample,ttft=ttft,elapsed=time.monotonic()-started,promptTokens=int(prompt),outputTokens=int(output),prefill=prefill,decode=decode,decodeTokensPerSecond=output/decode))
  (root/'.build/m2-m1-baseline.json').write_text(json.dumps(samples,indent=2))
