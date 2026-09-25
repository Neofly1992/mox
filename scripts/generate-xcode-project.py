#!/usr/bin/env python3
"""Generate the small native application/UI-test project; SwiftPM owns all libraries."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parent.parent
objects = []
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def obj(name, body):
    objects.append(f'{uid(name)} = {{ {body} }};'); return uid(name)
appfiles = [obj('source:'+str(path), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {path}; sourceTree = SOURCE_ROOT;') for path in sorted(Path('App').glob('*.swift'))]
testfile=obj('testfile','isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = AppUITests/MoxUITests.swift; sourceTree = SOURCE_ROOT;')
appprod=obj('appprod','isa = PBXFileReference; explicitFileType = wrapper.application; path = Mox.app; sourceTree = BUILT_PRODUCTS_DIR;')
testprod=obj('testprod','isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = MoxUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
package=obj('package','isa = XCLocalSwiftPackageReference; relativePath = .;')
products=[]
for name in ['MoxChat','MoxBootstrap','MoxPersistence','MoxClient','MoxDomain']:
    products.append(obj(name,f'isa = XCSwiftPackageProductDependency; productName = {name};'))
appbuilds = [obj('build:'+ref, f'isa = PBXBuildFile; fileRef = {ref};') for ref in appfiles]
testbuild=obj('testbuild',f'isa = PBXBuildFile; fileRef = {testfile};')
libs=[obj('lib'+name,f'isa = PBXBuildFile; productRef = {uid(name)};') for name in ['MoxChat','MoxBootstrap','MoxPersistence','MoxClient','MoxDomain']]
appsources=obj('appsources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(appbuilds)},); runOnlyForDeploymentPostprocessing = 0;')
testsources=obj('testsources',f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({testbuild},); runOnlyForDeploymentPostprocessing = 0;')
frameworks=obj('frameworks',f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({",".join(libs)},); runOnlyForDeploymentPostprocessing = 0;')
resources=obj('resources','isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
group=obj('group',f'isa = PBXGroup; children = ({",".join(appfiles)},{testfile},{appprod},{testprod},); sourceTree = "<group>";')
def configlist(name, extra):
    ids=[]
    for c in ['Debug','Release']:
        flags = 'SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG; DEBUG_INFORMATION_FORMAT = dwarf;' if c == 'Debug' else 'DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
        optimization = '"-Onone"' if c == 'Debug' else '"-O"'
        ids.append(obj(name+c, f'isa = XCBuildConfiguration; name = {c}; buildSettings = {{ SWIFT_VERSION = 6.0; MACOSX_DEPLOYMENT_TARGET = 15.0; ARCHS = arm64; CODE_SIGN_STYLE = Automatic; CODE_SIGN_IDENTITY = "-"; ENABLE_APP_SANDBOX = NO; SWIFT_OPTIMIZATION_LEVEL = {optimization}; {flags} {extra} }};'))
    return obj(name+'configs',f'isa = XCConfigurationList; buildConfigurations = ({",".join(ids)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
appcfg=configlist('app','PRODUCT_NAME = Mox; PRODUCT_BUNDLE_IDENTIFIER = dev.mox.app; GENERATE_INFOPLIST_FILE = YES; INFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.developer-tools"; INFOPLIST_KEY_NSPrincipalClass = NSApplication; INFOPLIST_KEY_CFBundleDisplayName = Mox;')
testcfg=configlist('test','PRODUCT_NAME = MoxUITests; PRODUCT_BUNDLE_IDENTIFIER = dev.mox.app.uitests; GENERATE_INFOPLIST_FILE = YES; TEST_TARGET_NAME = Mox; CODE_SIGN_ENTITLEMENTS = AppUITests/MoxUITests.entitlements;')
projcfg=configlist('project','ALWAYS_SEARCH_USER_PATHS = NO; ENABLE_USER_SCRIPT_SANDBOXING = NO;')
embed=obj('embed', 'isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); runOnlyForDeploymentPostprocessing = 0; alwaysOutOfDate = 1; shellPath = /bin/bash; shellScript = \"\\\"$SRCROOT/scripts/embed-worker.sh\\\"\";')
app=obj('app',f'isa = PBXNativeTarget; name = Mox; productName = Mox; productReference = {appprod}; productType = "com.apple.product-type.application"; buildConfigurationList = {appcfg}; buildPhases = ({appsources},{frameworks},{resources},{embed},); buildRules = (); dependencies = (); packageProductDependencies = ({",".join(products)},);')
proxy=obj('proxy',f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {app}; remoteInfo = Mox;')
dep=obj('dependency',f'isa = PBXTargetDependency; target = {app}; targetProxy = {proxy};')
test=obj('test',f'isa = PBXNativeTarget; name = MoxUITests; productName = MoxUITests; productReference = {testprod}; productType = "com.apple.product-type.bundle.ui-testing"; buildConfigurationList = {testcfg}; buildPhases = ({testsources},); buildRules = (); dependencies = ({dep},);')
project=obj('project',f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2660; TargetAttributes = {{ {test} = {{ TestTargetID = {app}; }}; }}; }}; buildConfigurationList = {projcfg}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base, "zh-Hans"); mainGroup = {group}; projectDirPath = ""; projectRoot = ""; packageReferences = ({package},); targets = ({app},{test},);')
(root/'Mox.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project}; }}\n')
(root/'Mox.xcodeproj/xcshareddata/xcschemes/Mox.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="Mox.app" BlueprintName="Mox" ReferencedContainer="container:Mox.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test}" BuildableName="MoxUITests.xctest" BlueprintName="MoxUITests" ReferencedContainer="container:Mox.xcodeproj"/></TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{app}" BuildableName="Mox.app" BlueprintName="Mox" ReferencedContainer="container:Mox.xcodeproj"/></BuildableProductRunnable></LaunchAction></Scheme>''')
