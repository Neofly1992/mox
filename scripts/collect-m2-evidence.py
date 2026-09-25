#!/usr/bin/env python3
"""Collect already executed M2 results; never infer PASS from implementation presence."""
import hashlib, json, pathlib, re, subprocess
root=pathlib.Path(__file__).resolve().parent.parent
build=root/'.build'
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def read(name): return json.loads((build/name).read_text())
unit=(build/'m2-isolated-tests.log').read_text()
ui=(build/'m2-ui-final2.log').read_text()
ruleCounts = re.findall(r'Test run with (\d+) tests in \d+ suites passed', unit)
assert sum(map(int, ruleCounts)) == 53
assert '** TEST SUCCEEDED **' in ui
cases=re.findall(r"Test Case '-\[MoxUITests.MoxUITests (\w+)\]' passed \(([\d.]+) seconds\)",ui)
expectedGUI = {
 'testHistoryPagesAndRetryPreserveDraft', 'testModelWorkspaceEntry', 'testLaunchAndChat', 'testFixtureLongReplyStopRetryAndHistory',
 'testLongReplyResponsiveness', 'testCloseReopenAndQuitChoices',
 'testMovedAppWithCleanPath', 'testServiceLossReconnectDoesNotReplay',
}
assert {name for name, _ in cases} == expectedGUI
history=read('m2-history.json')
assert len(history)==2 and all(len(case['samples'])==3 for case in history)
assert all(sample['summaryDecodedBytes']==0 and sample['visibleAttempts']==8 for case in history for sample in case['samples'])
real=read('m2-real-final.json'); package=read('m2-package-final.json')
assert len(real['samples'])==9 and len(real['coldSamples'])==9 and len(real['cancellation'])==9
assert all(package.values())
debugPackage=read('m2-package-debug.json')
assert all(debugPackage.values())
for verified in [package,debugPackage]:
 assert verified['barePATHStartsOwnedWorker'] and verified['configurationReported']
assert 'PASS real HTTP' in (build/'m2-real-final.log').read_text()
for name in ['m2-build.log','m2-build-debug.log']:
 assert (build/name).read_text().count('** BUILD SUCCEEDED **')==2
debugUI=(build/'m2-ui-debug.log').read_text()
assert '** TEST SUCCEEDED **' in debugUI and 'testLaunchAndChat' in debugUI
for sample in real['samples']+real['coldSamples']:
 assert sample['usage']['outputTokens']==sample['maxTokens']
for phase in ['loading','prefill','decode']:
 samples=[s for s in real['cancellation'] if s['cancelPhase']==phase]
 assert len(samples)==3 and all(s['reason']=='cancelled' and s['cancelWait']<30 for s in samples)
 if phase!='decode': assert all(s['bytes']==0 for s in samples)
assert all(real['process'].values())
performance=json.loads(next(line.split('M2 PERFORMANCE ',1)[1] for line in ui.splitlines() if 'M2 PERFORMANCE {' in line))
for value in performance.values():
 accumulated=0
 for i,count in enumerate(value['histogram']):
  accumulated+=count
  if accumulated>=value['count']*.95: value['p95UpperBoundMilliseconds']=i; break
assert performance['stopPresentation']['count']==20
assert performance['stopPresentation']['p95UpperBoundMilliseconds']<=100
assert performance['mainRunLoop']['maximumMilliseconds']<=250
app=build/'m2/Release/Mox.app'
manifest={str(p.relative_to(app)):sha(p) for p in sorted(app.rglob('*')) if p.is_file()}
identity=re.search(r'"(mox-m2-[a-f0-9]+)"',(root/'Sources/MoxProtocol/BuildIdentity.swift').read_text())[1]
assert identity in real['version'] and '(Release)' in real['version']
def artifactUUID(path):
 output=subprocess.check_output(['/usr/bin/dwarfdump','--uuid',str(path)],text=True)
 matches=re.findall(r'UUID: ([A-F0-9-]+) \(arm64\)',output)
 assert len(matches)==1,output
 return matches[0]
configurations={}
for flavor in ['Debug','Release']:
 appPath=build/'m2'/flavor/'Mox.app'
 cliPath=build/'m2-worker'/flavor/'mox'
 version=subprocess.check_output([str(cliPath),'--version'],text=True).strip()
 assert version==identity+' ('+flavor+')',version
 record={'version':version,'app':str(appPath.relative_to(root)),
         'cli':str(cliPath.relative_to(root)),
         'appUUID':artifactUUID(appPath/'Contents/MacOS/Mox'),'cliUUID':artifactUUID(cliPath)}
 assert record['appUUID']==artifactUUID(build/'m2-app/Build/Products'/flavor/'Mox.app/Contents/MacOS/Mox')
 record['guiTestBinaryMatches']=True
 if flavor=='Release':
  assert record['appUUID']==artifactUUID(appPath.parent/'Mox.app.dSYM')
  assert record['cliUUID']==artifactUUID(cliPath.parent/'mox.dSYM')
  record['debugSymbolsMatch']=True
 configurations[flavor]=record
(build/'m2-configurations.json').write_text(json.dumps(configurations,indent=2)+'\n')
prefill=(build/'m2-prefill-token-count.log').read_text()
assert 'inputTokens=5005' in prefill and 'Test run with 1 test in 0 suites passed' in prefill
logs=['m2-build-debug.log','m2-ui-debug.log','m2-package-debug.log','m2-prefill-token-count.log','m2-build.log','m2-isolated-tests.log','m2-ui-final2.log','m2-real-final.log','m2-package-final.log','m2-m1-baseline.log','m2-history.log','m2-storage-diagnostics-check.log']
result={
 'schemaVersion':1,'milestone':'M2','status':'readyForUserAcceptance','independentReview':'findingsAddressedPendingIndependentVerification','userAcceptance':'pending',
 'buildID':identity,'baselineCommit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),'uncommitted':True,
 'environment':{'system':subprocess.check_output(['sw_vers'],text=True).strip(),'xcode':subprocess.check_output(['xcodebuild','-version'],text=True).strip(),'hardware':'Apple M4 / 16 GiB','minimumOSNotTested':'macOS 15'},
 'dependencies':json.loads((root/'Package.resolved').read_text()),
 'model':{'repository':'mlx-community/Qwen2.5-0.5B-Instruct-4bit','revision':'a5339a4131f135d0fdc6a5c8b5bbed2753bbe0f3','weightsSHA256':'ddffab9cbc7bf6dde941c6724841eeca8981fcfa81ca20ff8efff1396326d153','weightsBytes':278064920},
 'artifact':{'path':'.build/m2/Release/Mox.app','treeSHA256':hashlib.sha256(json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()).hexdigest(),'files':manifest},
 'configurations':configurations,
 'tests':{'debugGUI':'testLaunchAndChat passed','debugPackage':debugPackage,'rulesIntegrationUnicode':53,'prefillFixtureInputTokens':5005,'prefillFixtureVerification':'passed','gui':[{'name':name,'seconds':float(seconds)} for name,seconds in cases],'package':package},
 'performance':{'history':history,'realHTTP':real,'ui':performance,'originalM1':read('m2-m1-baseline.json'),'originalDecoder':read('m2-decoder-release.json'),'batchedDecoder':read('m2-decoder-batched.json')},
 'performanceProvenance':{
  'originalM1':'Original M1 executable rerun on the current host; built with the M1 toolchain, not rebuilt with M2.',
  'originalM1ExecutableSHA256':sha(build/'m1/mox'),
  'decoder':'Historical same-toolchain comparison from M2 decoder implementation; not rerun after the Xcode 27 upgrade.',
 },
 'logs':{'.build/'+name:{'sha256':sha(build/name)} for name in logs},
 'sourceFiles':{str(p.relative_to(root)):sha(p) for folder in ['Sources','App','AppUITests','Tests','scripts'] for p in sorted((root/folder).rglob('*')) if p.is_file() and p.suffix in ['.swift','.py','.sh','.entitlements']},
}
(root/'docs/acceptance/M2-evidence.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print(identity, result['artifact']['treeSHA256'])
print(json.dumps({key:{k:v for k,v in value.items() if k!='histogram'} for key,value in performance.items()},indent=2))
