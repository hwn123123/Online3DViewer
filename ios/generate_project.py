#!/usr/bin/env python3
"""Generate the dependency-free Xcode project with deterministic object IDs."""
import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def uid(name):
    return hashlib.sha1(name.encode()).hexdigest()[:24].upper()


def main():
    source_names = ['ModelViewerApp.swift', 'ContentView.swift', 'ViewerModel.swift', 'ModelLibrary.swift', 'ModelLibraryView.swift', 'WebViewer.swift', 'LocalAssetServer.swift', 'TextureVariant.swift', 'StreamState.swift', 'RhinoStreamReader.mm', 'RhinoCacheBatcher.mm', 'MeshStreamReader.mm', 'StlStreamReader.mm', 'GltfStreamReader.mm', 'SkpStreamReader.mm', 'CadStreamReader.mm', 'CadTextRenderer.mm', 'NativeMemoryControl.mm', 'ThirdParty/ufbx/ufbx.c']
    objects = []

    def add(name, value):
        objects.append(f'{uid(name)} = {{ {value} }};')

    for name in source_names:
        file_type = 'sourcecode.cpp.objcpp' if name.endswith('.mm') else ('sourcecode.c.c' if name.endswith('.c') else 'sourcecode.swift')
        add('file:' + name, f'isa = PBXFileReference; lastKnownFileType = {file_type}; path = {name}; sourceTree = "<group>";')
        settings = 'settings = { COMPILER_FLAGS = "-O2"; };' if name.endswith(('ufbx.c', 'RhinoCacheBatcher.mm', 'MeshStreamReader.mm', 'StlStreamReader.mm', 'GltfStreamReader.mm', 'SkpStreamReader.mm', 'CadStreamReader.mm', 'CadTextRenderer.mm')) else ''
        add('build:' + name, f'isa = PBXBuildFile; fileRef = {uid("file:" + name)}; {settings}')
    add('info', 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
    add('assets', 'isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>";')
    add('assets-build', f'isa = PBXBuildFile; fileRef = {uid("assets")};')
    add('web', 'isa = PBXFileReference; lastKnownFileType = folder; name = WebAssets; path = ../build/ios/WebAssets; sourceTree = SOURCE_ROOT;')
    add('web-build', f'isa = PBXBuildFile; fileRef = {uid("web")};')
    add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Online3DViewer.app; sourceTree = BUILT_PRODUCTS_DIR;')
    source_children = ','.join(uid('file:' + name) for name in source_names) + ',' + uid('info') + ',' + uid('assets')
    add('sources-group', f'isa = PBXGroup; children = ({source_children}); path = Online3DViewer; sourceTree = "<group>";')
    add('products-group', f'isa = PBXGroup; children = ({uid("product")}); name = Products; sourceTree = "<group>";')
    add('ui-file', 'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ModelLibraryUITests.swift; sourceTree = "<group>";')
    add('ui-build', f'isa = PBXBuildFile; fileRef = {uid("ui-file")};')
    add('ui-group', f'isa = PBXGroup; children = ({uid("ui-file")}); path = Online3DViewerUITests; sourceTree = "<group>";')
    add('ui-product', 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = Online3DViewerUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    add('main-group', f'isa = PBXGroup; children = ({uid("sources-group")},{uid("ui-group")},{uid("web")},{uid("products-group")}); sourceTree = "<group>";')
    source_builds = ','.join(uid('build:' + name) for name in source_names)
    add('sources-phase', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({source_builds}); runOnlyForDeploymentPostprocessing = 0;')
    add('resources-phase', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({uid("web-build")},{uid("assets-build")}); runOnlyForDeploymentPostprocessing = 0;')
    add('frameworks-phase', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    common = 'SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; CLANG_ENABLE_MODULES = YES; SWIFT_VERSION = 5.0;'
    target = '''PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = com.hwn.Online3DViewer;
        INFOPLIST_FILE = Online3DViewer/Info.plist; GENERATE_INFOPLIST_FILE = NO;
        TARGETED_DEVICE_FAMILY = "1,2"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
        SUPPORTS_MACCATALYST = NO; SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD = NO;
        CODE_SIGN_STYLE = Automatic; ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
        LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks";'''
    target += ''' SWIFT_OBJC_BRIDGING_HEADER = "Online3DViewer/Online3DViewer-Bridging-Header.h";
        HEADER_SEARCH_PATHS = ("$(SRCROOT)/Online3DViewer", "$(SRCROOT)/../build/ios/opennurbs-src", "$(SRCROOT)/../build/ios/draco-bounded-src/src", "$(SRCROOT)/../build/ios/draco-iphoneos", "$(SRCROOT)/../build/ios/openskp-bounded-src/include", "$(SRCROOT)/../build/ios/openskp-bounded-src/src", "$(SRCROOT)/../build/ios/openskp-reader-project/include");
        LIBRARY_SEARCH_PATHS = ("$(SRCROOT)/../build/ios/opennurbs-iphoneos", "$(SRCROOT)/../build/ios/opennurbs-iphoneos/zlib", "$(SRCROOT)/../build/ios/draco-iphoneos", "$(SRCROOT)/../build/ios/openskp-iphoneos", "$(SRCROOT)/../build/ios/cad-target/aarch64-apple-ios/release");
        OTHER_LDFLAGS = ("$(inherited)", "-lopennurbsStatic", "-lzlib", "-ldraco", "-lopenskp", "-lo3dv_cad", "-liconv", "-lc++", "-framework", CoreText, "-framework", CoreGraphics);
        CLANG_CXX_LANGUAGE_STANDARD = "c++17"; CLANG_ENABLE_OBJC_ARC = YES;'''
    for configuration in ['Debug', 'Release']:
        optimization = 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; DEBUG_INFORMATION_FORMAT = dwarf; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;' if configuration == 'Debug' else 'SWIFT_OPTIMIZATION_LEVEL = "-O"; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";'
        add('project-' + configuration, f'isa = XCBuildConfiguration; buildSettings = {{ {common} {optimization} }}; name = {configuration};')
        add('target-' + configuration, f'isa = XCBuildConfiguration; buildSettings = {{ {target} }}; name = {configuration};')
        ui_settings = '''PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = com.hwn.Online3DViewer.UITests;
            GENERATE_INFOPLIST_FILE = YES; CODE_SIGN_STYLE = Automatic; TEST_TARGET_NAME = Online3DViewer;
            TARGETED_DEVICE_FAMILY = "1,2"; SUPPORTED_PLATFORMS = "iphoneos";'''
        add('ui-' + configuration, f'isa = XCBuildConfiguration; buildSettings = {{ {ui_settings} }}; name = {configuration};')
    for scope in ['project', 'target', 'ui']:
        add(scope + '-configs', f'isa = XCConfigurationList; buildConfigurations = ({uid(scope + "-Debug")},{uid(scope + "-Release")}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    add('target', f'''isa = PBXNativeTarget; buildConfigurationList = {uid('target-configs')};
        buildPhases = ({uid('sources-phase')},{uid('frameworks-phase')},{uid('resources-phase')});
        buildRules = (); dependencies = (); name = Online3DViewer; productName = Online3DViewer;
        productReference = {uid('product')}; productType = "com.apple.product-type.application";''')
    add('ui-sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({uid("ui-build")}); runOnlyForDeploymentPostprocessing = 0;')
    add('ui-frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    add('ui-resources', 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    add('ui-proxy', f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {uid("target")}; remoteInfo = Online3DViewer;')
    add('ui-dependency', f'isa = PBXTargetDependency; target = {uid("target")}; targetProxy = {uid("ui-proxy")};')
    add('ui-target', f'''isa = PBXNativeTarget; buildConfigurationList = {uid('ui-configs')};
        buildPhases = ({uid('ui-sources')},{uid('ui-frameworks')},{uid('ui-resources')});
        buildRules = (); dependencies = ({uid('ui-dependency')}); name = Online3DViewerUITests;
        productName = Online3DViewerUITests; productReference = {uid('ui-product')};
        productType = "com.apple.product-type.bundle.ui-testing";''')
    add('project', f'''isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2720; }};
        buildConfigurationList = {uid('project-configs')}; compatibilityVersion = "Xcode 14.0";
        developmentRegion = zh_CN; hasScannedForEncodings = 0; knownRegions = (en, "zh-Hans", Base);
        mainGroup = {uid('main-group')}; productRefGroup = {uid('products-group')};
        projectDirPath = ""; projectRoot = ""; targets = ({uid('target')},{uid('ui-target')});''')
    project = ROOT / 'Online3DViewer.xcodeproj'
    project.mkdir(exist_ok=True)
    content = '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'
    content += '\n'.join(objects) + f'\n}}; rootObject = {uid("project")}; }}\n'
    (project / 'project.pbxproj').write_text(content)
    schemes = project / 'xcshareddata' / 'xcschemes'
    schemes.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("target")}" BuildableName="Online3DViewer.app" BlueprintName="Online3DViewer" ReferencedContainer="container:Online3DViewer.xcodeproj"/>'
    ui_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid("ui-target")}" BuildableName="Online3DViewerUITests.xctest" BlueprintName="Online3DViewerUITests" ReferencedContainer="container:Online3DViewer.xcodeproj"/>'
    (schemes / 'Online3DViewer.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2720" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{ui_reference}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
    print(project)


if __name__ == '__main__':
    main()
