#!/usr/bin/env python3
"""Generate the dependency-free Xcode project using repository-relative sources."""
from pathlib import Path
import hashlib
import plistlib

root = Path(__file__).resolve().parents[1]
repo = root.parent
objects = {}
def ident(name): return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def obj(name, value):
    key = ident(name)
    objects[key] = value
    return key
def quote(s): return '"' + str(s).replace('\\', '\\\\').replace('"', '\\"') + '"'
def settings(values): return '{ ' + ' '.join(f'{k} = {quote(v)};' for k, v in values.items()) + ' }'
def refs(values): return '(' + ', '.join(values) + ',)'
def file(path, kind):
    return obj(path, f'{{isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(path)}; sourceTree = SOURCE_ROOT;}}')
core = sorted('../' + str(p.relative_to(repo)) for p in (repo / 'Sources/Sebeol390Core').glob('*.swift'))
resources = ['../Resources/' + name for name in ['english-words.txt', 'english-extra.txt', 'korean-words.txt', 'korean-valid.txt', 'korean-valid.LICENSE', '../LICENSE', '../NOTICE']]
# LICENSE and NOTICE live in the repository root.
resources = [p.replace('Resources/../', '') for p in resources]
app_sources = core + ['App/Sebeol390App.swift', 'App/HardwareTextEditor.swift', 'App/MarkVectorView.swift', 'App/MarkVectorLiveSync.swift']
keyboard_sources = core + ['Shared/KeyboardView.swift', 'Keyboard/KeyboardViewController.swift']
all_files = [file(p, 'sourcecode.swift') for p in dict.fromkeys(app_sources + keyboard_sources)]
all_files += [file(p, 'text') for p in resources]
products = []
targets = []
project_configs = []
for config in ['Debug', 'Release']:
    cfg = {'SDKROOT': 'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET': '16.0', 'SWIFT_VERSION': '6.0', 'CLANG_ENABLE_MODULES': 'YES', 'SWIFT_OPTIMIZATION_LEVEL': '-Onone' if config == 'Debug' else '-O'}
    project_configs.append(obj('project' + config, f'{{isa = XCBuildConfiguration; name = {config}; buildSettings = {settings(cfg)};}}'))
project_config_list = obj('project-configs', '{isa = XCConfigurationList; buildConfigurations = ' + refs(project_configs) + '; defaultConfigurationName = Release;}')
for name, sources, ext in [('Sebeol390Keyboard', keyboard_sources, True), ('Sebeol390', app_sources, False)]:
    product = obj(name + '-product', f'{{isa = PBXFileReference; explicitFileType = {"wrapper.app-extension" if ext else "wrapper.application"}; path = {name}{".appex" if ext else ".app"}; sourceTree = BUILT_PRODUCTS_DIR;}}')
    products.append(product)
    builds = [obj(name + p, f'{{isa = PBXBuildFile; fileRef = {ident(p)};}}') for p in sources]
    source_phase = obj(name + '-sources', '{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ' + refs(builds) + '; runOnlyForDeploymentPostprocessing = 0;}')
    resource_builds = [obj(name + p, f'{{isa = PBXBuildFile; fileRef = {ident(p)};}}') for p in resources]
    resource_phase = obj(name + '-resources', '{isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ' + refs(resource_builds) + '; runOnlyForDeploymentPostprocessing = 0;}')
    phases = [source_phase, resource_phase]
    dependencies = []
    if not ext:
        embed = obj('embed-build', '{isa = PBXBuildFile; fileRef = ' + ident('Sebeol390Keyboard-product') + '; settings = {ATTRIBUTES = (RemoveHeadersOnCopy,);};}')
        phases.append(obj('embed', '{isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = ""; dstSubfolderSpec = 13; files = (' + embed + ',); runOnlyForDeploymentPostprocessing = 0;}'))
        proxy = obj('proxy', '{isa = PBXContainerItemProxy; containerPortal = ' + ident('project') + '; proxyType = 1; remoteGlobalIDString = ' + ident('Sebeol390Keyboard-target') + '; remoteInfo = Sebeol390Keyboard;}')
        dependencies.append(obj('dependency', '{isa = PBXTargetDependency; target = ' + ident('Sebeol390Keyboard-target') + '; targetProxy = ' + proxy + ';}'))
    configs = []
    for config in ['Debug', 'Release']:
        cfg = {'PRODUCT_NAME': name, 'PRODUCT_BUNDLE_IDENTIFIER': 'com.sebeol390.ios' + ('.keyboard' if ext else ''), 'INFOPLIST_FILE': 'Keyboard/Info.plist' if ext else 'App/Info.plist', 'GENERATE_INFOPLIST_FILE': 'NO', 'CODE_SIGN_STYLE': 'Automatic', 'TARGETED_DEVICE_FAMILY': '1,2', 'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'MARKETING_VERSION': '1.0', 'CURRENT_PROJECT_VERSION': '1', 'APPLICATION_EXTENSION_API_ONLY': 'YES' if ext else 'NO', 'SKIP_INSTALL': 'YES' if ext else 'NO', 'SWIFT_STRICT_CONCURRENCY': 'complete', 'ENABLE_TESTABILITY': 'YES' if config == 'Debug' else 'NO'}
        configs.append(obj(name + config, f'{{isa = XCBuildConfiguration; name = {config}; buildSettings = {settings(cfg)};}}'))
    config_list = obj(name + '-configs', '{isa = XCConfigurationList; buildConfigurations = ' + refs(configs) + '; defaultConfigurationName = Release;}')
    targets.append(obj(name + '-target', '{isa = PBXNativeTarget; buildConfigurationList = ' + config_list + '; buildPhases = ' + refs(phases) + '; buildRules = (); dependencies = ' + refs(dependencies) + f'; name = {name}; productName = {name}; productReference = {product}; productType = "com.apple.product-type.{"app-extension" if ext else "application"}";}}'))
# Host-based UIKit tests exercise real UITextView replacement and selection.
test_source = 'Tests/HardwareTextEditorTests.swift'
all_files.append(file(test_source, 'sourcecode.swift'))
test_product = obj('test-product', '{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = Sebeol390Tests.xctest; sourceTree = BUILT_PRODUCTS_DIR;}')
products.append(test_product)
test_build = obj('test-build', '{isa = PBXBuildFile; fileRef = ' + ident(test_source) + ';}')
test_phase = obj('test-phase', '{isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (' + test_build + ',); runOnlyForDeploymentPostprocessing = 0;}')
test_configs = []
for config in ['Debug', 'Release']:
    cfg = {'PRODUCT_NAME': 'Sebeol390Tests', 'PRODUCT_BUNDLE_IDENTIFIER': 'com.sebeol390.ios.tests', 'GENERATE_INFOPLIST_FILE': 'YES', 'CODE_SIGN_STYLE': 'Automatic', 'TARGETED_DEVICE_FAMILY': '1,2', 'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/Sebeol390.app/Sebeol390', 'BUNDLE_LOADER': '$(TEST_HOST)'}
    test_configs.append(obj('test-' + config, ''))
    objects[test_configs[-1]] = '{isa = XCBuildConfiguration; name = ' + config + '; buildSettings = ' + settings(cfg) + ';}'
test_config_list = obj('test-configs', '{isa = XCConfigurationList; buildConfigurations = ' + refs(test_configs) + '; defaultConfigurationName = Release;}')
test_proxy = obj('test-proxy', '{isa = PBXContainerItemProxy; containerPortal = ' + ident('project') + '; proxyType = 1; remoteGlobalIDString = ' + ident('Sebeol390-target') + '; remoteInfo = Sebeol390;}')
test_dependency = obj('test-dependency', '{isa = PBXTargetDependency; target = ' + ident('Sebeol390-target') + '; targetProxy = ' + test_proxy + ';}')
targets.append(obj('test-target', '{isa = PBXNativeTarget; buildConfigurationList = ' + test_config_list + '; buildPhases = (' + test_phase + ',); buildRules = (); dependencies = (' + test_dependency + ',); name = Sebeol390Tests; productName = Sebeol390Tests; productReference = ' + test_product + '; productType = "com.apple.product-type.bundle.unit-test";}'))
product_group = obj('products', '{isa = PBXGroup; children = ' + refs(products) + '; name = Products; sourceTree = "<group>";}')
group = obj('main-group', '{isa = PBXGroup; children = ' + refs(all_files + [product_group]) + '; sourceTree = "<group>";}')
obj('project', '{isa = PBXProject; attributes = {LastUpgradeCheck = 1600;}; buildConfigurationList = ' + project_config_list + '; compatibilityVersion = "Xcode 14.0"; developmentRegion = ko; knownRegions = (ko, en, Base); mainGroup = ' + group + '; productRefGroup = ' + product_group + '; projectDirPath = ""; projectRoot = ""; targets = ' + refs(targets) + ';}')
# Empty arrays must use (), not (,).
content = '// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(f'{k} = {v};' for k,v in objects.items()) + '\n}; rootObject = ' + ident('project') + ';}\n'
(root / 'Sebeol390.xcodeproj/project.pbxproj').write_text(content.replace('(,)', '()'))
common = {'CFBundleDevelopmentRegion': 'ko', 'CFBundleExecutable': '$(EXECUTABLE_NAME)', 'CFBundleIdentifier': '$(PRODUCT_BUNDLE_IDENTIFIER)', 'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleName': '$(PRODUCT_NAME)', 'CFBundleDisplayName': '세토', 'CFBundleShortVersionString': '$(MARKETING_VERSION)', 'CFBundleVersion': '$(CURRENT_PROJECT_VERSION)'}
for ext in [False, True]:
    data = dict(common, CFBundlePackageType='XPC!' if ext else 'APPL')
    if ext:
        data['NSExtension'] = {'NSExtensionPointIdentifier': 'com.apple.keyboard-service', 'NSExtensionPrincipalClass': '$(PRODUCT_MODULE_NAME).KeyboardViewController', 'NSExtensionAttributes': {'IsASCIICapable': True, 'PrimaryLanguage': 'ko-KR', 'RequestsOpenAccess': False, 'PrefersRightToLeft': False}}
    else:
        data.update(LSRequiresIPhoneOS=True, UILaunchScreen={}, UIApplicationSceneManifest={'UIApplicationSupportsMultipleScenes': False}, UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait', 'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight'])
    with (root / ('Keyboard' if ext else 'App') / 'Info.plist').open('wb') as f: plistlib.dump(data, f)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('Sebeol390-target')}" BuildableName="Sebeol390.app" BlueprintName="Sebeol390" ReferencedContainer="container:Sebeol390.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident('Sebeol390-target')}" BuildableName="Sebeol390.app" BlueprintName="Sebeol390" ReferencedContainer="container:Sebeol390.xcodeproj"/></BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>'''
test_action = '<TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="' + ident('test-target') + '" BuildableName="Sebeol390Tests.xctest" BlueprintName="Sebeol390Tests" ReferencedContainer="container:Sebeol390.xcodeproj"/></TestableReference></Testables></TestAction>'
scheme = scheme.replace('</BuildAction>', '</BuildAction>' + test_action)
(root / 'Sebeol390.xcodeproj/xcshareddata/xcschemes/Sebeol390.xcscheme').write_text(scheme)
print('Generated iOS/Sebeol390.xcodeproj')
