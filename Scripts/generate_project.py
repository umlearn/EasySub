#!/usr/bin/env python3
"""Generate the dependency-free Xcode project from Sources/ and Tests/."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(identity, isa, **kwargs):
    key = ident(identity)
    objects[key] = dict(isa=isa, **kwargs)
    return key

def file(path, kind):
    return add('file:' + path, 'PBXFileReference', lastKnownFileType=kind, path=path, sourceTree='<group>')

def phase(name, isa, refs):
    builds = [add(name + ':' + ref, 'PBXBuildFile', fileRef=ref) for ref in refs]
    return add(name, isa, buildActionMask=2147483647, files=builds, runOnlyForDeploymentPostprocessing=0)

core = [file(str(p.relative_to(ROOT)), 'sourcecode.swift') for p in sorted((ROOT/'Sources/EasySubCore').rglob('*.swift'))]
ui = [file(str(p.relative_to(ROOT)), 'sourcecode.swift') for p in sorted((ROOT/'Sources/EasySubApp').rglob('*.swift'))]
tests = [file(str(p.relative_to(ROOT)), 'sourcecode.swift') for p in sorted((ROOT/'Tests/EasySubCoreTests').rglob('*.swift'))]
resources = [file('EasySub/Images.xcassets', 'folder.assetcatalog'), file('Sources/EasySubApp/Localizable.xcstrings', 'text.json.xcstrings'), file('LICENSE.md', 'text'), file('EasySub/credits.md', 'text')]
info_plist = file('EasySub/Info.plist', 'text.plist.xml')
app_product = add('app-product', 'PBXFileReference', explicitFileType='wrapper.application', path='EasySub.app', sourceTree='BUILT_PRODUCTS_DIR')
test_product = add('test-product', 'PBXFileReference', explicitFileType='wrapper.cfbundle', path='EasySubTests.xctest', sourceTree='BUILT_PRODUCTS_DIR')
products = add('products', 'PBXGroup', children=[app_product, test_product], name='Products', sourceTree='<group>')
groups = [add(name, 'PBXGroup', children=refs, name=name, sourceTree='<group>') for name, refs in [('Core', core), ('App', ui + resources + [info_plist]), ('Tests', tests)]]
main = add('main', 'PBXGroup', children=groups + [products], sourceTree='<group>')

def configs(name, settings):
    refs=[]
    for mode in ['Debug', 'Release']:
        values = dict(settings)
        if name == 'project':
            values.update(SWIFT_OPTIMIZATION_LEVEL='-Onone' if mode == 'Debug' else '-O',
                          DEBUG_INFORMATION_FORMAT='dwarf' if mode == 'Debug' else 'dwarf-with-dsym',
                          ENABLE_TESTABILITY='YES' if mode == 'Debug' else 'NO',
                          SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG' if mode == 'Debug' else '')
        refs.append(add(name + mode, 'XCBuildConfiguration', name=mode, buildSettings=values))
    return add(name + 'configs', 'XCConfigurationList', buildConfigurations=refs, defaultConfigurationIsVisible=0, defaultConfigurationName='Release')

common = dict(MACOSX_DEPLOYMENT_TARGET='14.0', SDKROOT='macosx', SWIFT_VERSION='6.0', SWIFT_STRICT_CONCURRENCY='complete', CLANG_ENABLE_MODULES='YES', CODE_SIGN_STYLE='Automatic', ENABLE_USER_SCRIPT_SANDBOXING='YES')
project_configs = configs('project', common)
app_configs = configs('app', dict(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='com.umlearn.EasySub', GENERATE_INFOPLIST_FILE='NO', INFOPLIST_FILE='EasySub/Info.plist', MARKETING_VERSION='1.0.4', CURRENT_PROJECT_VERSION='6', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', ENABLE_HARDENED_RUNTIME='YES', ENABLE_APP_SANDBOX='NO', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/../Frameworks'], SWIFT_EMIT_LOC_STRINGS='YES'))
test_configs = configs('tests', dict(PRODUCT_NAME='$(TARGET_NAME)', PRODUCT_BUNDLE_IDENTIFIER='com.umlearn.EasySubTests', GENERATE_INFOPLIST_FILE='YES', LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@loader_path/../Frameworks']))
app = add('app-target', 'PBXNativeTarget', name='EasySub', productName='EasySub', productType='com.apple.product-type.application', productReference=app_product, buildConfigurationList=app_configs, buildPhases=[phase('app-sources','PBXSourcesBuildPhase',core+ui),phase('app-resources','PBXResourcesBuildPhase',resources),phase('app-frameworks','PBXFrameworksBuildPhase',[])], buildRules=[], dependencies=[])
test = add('test-target','PBXNativeTarget', name='EasySubTests', productName='EasySubTests', productType='com.apple.product-type.bundle.unit-test', productReference=test_product, buildConfigurationList=test_configs, buildPhases=[phase('test-sources','PBXSourcesBuildPhase',core+tests),phase('test-frameworks','PBXFrameworksBuildPhase',[])], buildRules=[], dependencies=[])
project = add('project','PBXProject', attributes={'LastUpgradeCheck':'1600','BuildIndependentTargetsInParallel':'YES'}, buildConfigurationList=project_configs, compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en','zh-Hans'], mainGroup=main, productRefGroup=products, projectDirPath='', projectRoot='', targets=[app,test])
def serialize(value, level=0):
    if isinstance(value, dict):
        return '{\n' + ''.join('\t'*(level+1)+json.dumps(str(k))+ ' = '+serialize(v, level+1)+';\n' for k,v in value.items()) + '\t'*level+'}'
    if isinstance(value, list): return '(' + ', '.join(serialize(v,level) for v in value) + (',' if value else '') + ')'
    return json.dumps(value,ensure_ascii=False)
pbx={'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':project}
(ROOT/'EasySub.xcodeproj/project.pbxproj').write_text('// !$*UTF8*$!\n'+serialize(pbx)+'\n')
scheme_dir=ROOT/'EasySub.xcodeproj/xcshareddata/xcschemes'
scheme_dir.mkdir(parents=True,exist_ok=True)
def reference(key, name, product): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{key}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:EasySub.xcodeproj"/>'
app_ref=reference(app,'EasySub','EasySub.app')
test_ref=reference(test,'EasySubTests','EasySubTests.xctest')
(scheme_dir/'EasySub.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{app_ref}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_ref}</TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{app_ref}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
(ROOT/'EasySub.xcworkspace/contents.xcworkspacedata').write_text('<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="group:EasySub.xcodeproj"/></Workspace>\n')
