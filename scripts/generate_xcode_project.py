#!/usr/bin/env python3
"""Generate Clicky's dependency-free Xcode project from current App/*.swift files.

Run after adding/removing an app source. The build script always does this first.
ClickyCore is a local Swift package; the generated app has no remote packages.
"""

from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]


def identifier(label):
    return hashlib.sha1(label.encode("utf-8")).hexdigest().upper()[:24]


def quoted(value):
    return json.dumps(str(value))


def main():
    sources = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "App").rglob("*.swift"))
    if not sources:
        raise SystemExit("No App Swift files found")
    objects = []

    def obj(label, body):
        key = identifier(label)
        objects.append(f"\t\t{key} = {{\n{body}\n\t\t}};")
        return key

    def items(ids):
        return "(\n" + "".join(f"\t\t\t\t{item},\n" for item in ids) + "\t\t\t)"

    source_refs, source_builds = [], []
    for path in sources:
        ref = obj("file:" + path, f"\t\t\tisa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quoted(path)}; sourceTree = \"<group>\";")
        build = obj("source:" + path, f"\t\t\tisa = PBXBuildFile; fileRef = {ref};")
        source_refs.append(ref)
        source_builds.append(build)
    plist = obj("file:Info", '\t\t\tisa = PBXFileReference; lastKnownFileType = text.plist.xml; path = App/Info.plist; sourceTree = "<group>";')
    assets = obj("file:Assets", '\t\t\tisa = PBXFileReference; lastKnownFileType = folder; path = Assets; sourceTree = "<group>";')
    icon = obj("file:AppIcon", '\t\t\tisa = PBXFileReference; lastKnownFileType = image.icns; path = Assets/AppIcon.icns; sourceTree = "<group>";')
    product = obj("product", '\t\t\tisa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Clicky.app; sourceTree = BUILT_PRODUCTS_DIR;')
    package = obj("package:ClickyCore", '\t\t\tisa = XCLocalSwiftPackageReference; relativePath = Packages/ClickyCore;')
    dependency = obj("dependency:ClickyCore", f'\t\t\tisa = XCSwiftPackageProductDependency; package = {package}; productName = ClickyCore;')
    package_build = obj("framework:ClickyCore", f"\t\t\tisa = PBXBuildFile; productRef = {dependency};")
    assets_build = obj("resource:Assets", f"\t\t\tisa = PBXBuildFile; fileRef = {assets};")
    icon_build = obj("resource:AppIcon", f"\t\t\tisa = PBXBuildFile; fileRef = {icon};")
    app_group = obj("group:App", f'\t\t\tisa = PBXGroup; children = {items(source_refs + [plist])}; name = App; sourceTree = "<group>";')
    product_group = obj("group:Products", f'\t\t\tisa = PBXGroup; children = {items([product])}; name = Products; sourceTree = "<group>";')
    main_group = obj("group:Main", f'\t\t\tisa = PBXGroup; children = {items([app_group, assets, icon, product_group])}; sourceTree = "<group>";')
    source_phase = obj("phase:Sources", f"\t\t\tisa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {items(source_builds)}; runOnlyForDeploymentPostprocessing = 0;")
    resource_phase = obj("phase:Resources", f"\t\t\tisa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {items([assets_build, icon_build])}; runOnlyForDeploymentPostprocessing = 0;")
    framework_phase = obj("phase:Frameworks", f"\t\t\tisa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {items([package_build])}; runOnlyForDeploymentPostprocessing = 0;")
    sign_command = '/usr/bin/python3 "$SRCROOT/scripts/sign_app.py" "$TARGET_BUILD_DIR/$WRAPPER_NAME"'
    signing_phase = obj("phase:Signing", f'\t\t\tisa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = (); name = "Sign with persistent Clicky identity"; runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = {quoted(sign_command)};')
    project_configs, target_configs = [], []
    for configuration in ("Debug", "Release"):
        debug = configuration == "Debug"
        settings = {
            "CLANG_ENABLE_MODULES": "YES", "CLANG_ENABLE_OBJC_ARC": "YES", "SDKROOT": "macosx",
            "MACOSX_DEPLOYMENT_TARGET": "13.0", "SWIFT_VERSION": "5.0", "ARCHS": "arm64",
            "ONLY_ACTIVE_ARCH": "YES", "SWIFT_OPTIMIZATION_LEVEL": "-Onone" if debug else "-O",
            "GCC_OPTIMIZATION_LEVEL": "0" if debug else "s", "DEBUG_INFORMATION_FORMAT": "dwarf" if debug else "dwarf-with-dsym",
            "ENABLE_TESTABILITY": "YES" if debug else "NO", "SWIFT_COMPILATION_MODE": "singlefile" if debug else "wholemodule",
        }
        if debug:
            settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "DEBUG"
        body = "\n".join(f"\t\t\t\t{key} = {quoted(value)};" for key, value in settings.items())
        project_configs.append(obj("config:Project:" + configuration, f"\t\t\tisa = XCBuildConfiguration; name = {configuration}; buildSettings = {{\n{body}\n\t\t\t}};"))
        target_settings = {
            "PRODUCT_NAME": "Clicky", "PRODUCT_BUNDLE_IDENTIFIER": "dev.clicky.app",
            "INFOPLIST_FILE": "App/Info.plist", "GENERATE_INFOPLIST_FILE": "NO",
            "MARKETING_VERSION": "0.1.4", "CURRENT_PROJECT_VERSION": "5",
            "CODE_SIGNING_ALLOWED": "NO", "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
            "ENABLE_APP_SANDBOX": "NO", "ENABLE_HARDENED_RUNTIME": "YES",
            "COMBINE_HIDPI_IMAGES": "YES", "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
            "SWIFT_EMIT_LOC_STRINGS": "NO", "SUPPORTED_PLATFORMS": "macosx",
        }
        body = "\n".join(f"\t\t\t\t{key} = {quoted(value)};" for key, value in target_settings.items())
        target_configs.append(obj("config:Target:" + configuration, f"\t\t\tisa = XCBuildConfiguration; name = {configuration}; buildSettings = {{\n{body}\n\t\t\t}};"))
    project_config_list = obj("configs:Project", f"\t\t\tisa = XCConfigurationList; buildConfigurations = {items(project_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
    target_config_list = obj("configs:Target", f"\t\t\tisa = XCConfigurationList; buildConfigurations = {items(target_configs)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
    target = obj("target:Clicky", f"\t\t\tisa = PBXNativeTarget; buildConfigurationList = {target_config_list}; buildPhases = {items([source_phase, framework_phase, resource_phase, signing_phase])}; buildRules = (); dependencies = (); name = Clicky; packageProductDependencies = {items([dependency])}; productName = Clicky; productReference = {product}; productType = \"com.apple.product-type.application\";")
    project = obj("project", f"\t\t\tisa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600; }}; buildConfigurationList = {project_config_list}; compatibilityVersion = \"Xcode 14.0\"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = {main_group}; packageReferences = {items([package])}; productRefGroup = {product_group}; projectDirPath = \"\"; projectRoot = \"\"; targets = {items([target])};")
    content = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n" + "\n".join(objects) + f"\n\t}};\n\trootObject = {project};\n}}\n"
    directory = ROOT / "Clicky.xcodeproj"
    directory.mkdir(exist_ok=True)
    (directory / "project.pbxproj").write_text(content)
    schemes = directory / "xcshareddata" / "xcschemes"
    schemes.mkdir(parents=True, exist_ok=True)
    reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Clicky.app" BlueprintName="Clicky" ReferencedContainer="container:Clicky.xcodeproj"/>'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables/></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    (schemes / "Clicky.xcscheme").write_text(scheme)
    print(f"Generated Clicky.xcodeproj with {len(sources)} app Swift sources and local ClickyCore package.")


if __name__ == "__main__":
    main()
