#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Register feature sources and the two native extensions in the hand-maintained Xcode project."""
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "Dayside.xcodeproj/project.pbxproj"
text = PROJECT.read_text()

def uid(value):
    return hashlib.sha256(("meantime-features:" + value).encode()).hexdigest()[:24].upper()

def node(section, identifier, body):
    global text
    if re.search(r"\b" + identifier + r" (?:/\*.*?\*/ )?=", text):
        return
    marker = "/* End " + section + " section */"
    if marker not in text:
        text = text.replace("/* Begin PBXBuildFile section */", "/* Begin " + section + " section */\n" + marker + "\n\n/* Begin PBXBuildFile section */")
    text = text.replace(marker, "\t\t" + identifier + " = {" + body + "};\n" + marker)

def append(identifier, field, value):
    global text
    pattern = r"(\b" + identifier + r"(?: /\*[^\n]*?\*/)? = \{[\s\S]*?\b" + field + r" = \()([\s\S]*?)(\);)"
    match = re.search(pattern, text)
    if not match:
        raise ValueError((identifier, field))
    if value in match[2]:
        return
    text = text[:match.start(2)] + match[2] + "\n\t\t\t\t" + value + ",\n\t\t\t" + text[match.end(2):]

APP = "AA0000000000000000000005"
PROJECT_ID = "AA0000000000000000000001"
GROUP = uid("Feature files")
node("PBXGroup", GROUP, 'isa = PBXGroup; name = "Feature files"; children = (); sourceTree = "<group>";')
append("AA0000000000000000000002", "children", GROUP)

def file(path):
    identifier = uid("file:" + path)
    types = {".swift":"sourcecode.swift", ".xcstrings":"text.json.xcstrings", ".xcprivacy":"text.xml", ".plist":"text.plist.xml", ".entitlements":"text.plist.entitlements"}
    node("PBXFileReference", identifier, f'isa = PBXFileReference; path = "{path}"; sourceTree = SOURCE_ROOT; lastKnownFileType = {types.get(Path(path).suffix,"text")};')
    append(GROUP, "children", identifier)
    return identifier

def build_file(path, target, phase):
    identifier = uid("build:" + target + ":" + path)
    node("PBXBuildFile", identifier, f"isa = PBXBuildFile; fileRef = {file(path)};")
    append(phase, "files", identifier)

app_sources = "AA000000000000000000000C"
test_sources = "CC0000000000000000000023"
build_file("Dayside/Resources/ServicesMenu.xcstrings", APP, "AA000000000000000000000E")
for folder, target, phase in [("Dayside", APP, app_sources), ("Shared", APP, app_sources), ("DaysideTests", "tests", test_sources)]:
    for path in sorted((ROOT / folder).rglob("*.swift")):
        rel = str(path.relative_to(ROOT))
        # Existing sources are referenced relative to their group; added ones use SOURCE_ROOT.
        if re.search(r'path = (?:"' + re.escape(path.name) + r'"|' + re.escape(path.name) + r');', text):
            continue
        build_file(rel, target, phase)

def configurations(name, extras=""):
    ids=[]
    for config in ["Debug", "Release"]:
        identifier=uid(name+config);ids.append(identifier)
        settings='MACOSX_DEPLOYMENT_TARGET = 26.0; SDKROOT = macosx; SWIFT_VERSION = 6.0; ENABLE_USER_SCRIPT_SANDBOXING = NO; CODE_SIGNING_ALLOWED = NO; '
        settings += 'SWIFT_OPTIMIZATION_LEVEL = "' + ('-Onone' if config=='Debug' else '-Osize') + '"; '
        node("XCBuildConfiguration",identifier,f'isa = XCBuildConfiguration; name = {config}; buildSettings = {{{settings}{extras}}};')
    identifier=uid(name+"configs")
    node("XCConfigurationList",identifier,'isa = XCConfigurationList; buildConfigurations = ('+','.join(ids)+',); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
    return identifier

def dependency(owner, target):
    proxy=uid(owner+target+"proxy");dep=uid(owner+target+"dep")
    node("PBXContainerItemProxy",proxy,f'isa = PBXContainerItemProxy; containerPortal = {PROJECT_ID}; proxyType = 1; remoteGlobalIDString = {target}; remoteInfo = Dayside;')
    node("PBXTargetDependency",dep,f'isa = PBXTargetDependency; target = {target}; targetProxy = {proxy};')
    append(owner,"dependencies",dep)

# One producer for the static library, avoiding parallel writes from app and Intents builds.
rust=uid("Rust Core target")
node("PBXAggregateTarget",rust,f'isa = PBXAggregateTarget; name = DaysideCore; productName = DaysideCore; buildConfigurationList = {configurations("Rust")}; buildPhases = (EE0000000000000000000003,); dependencies = ();')
append(PROJECT_ID,"targets",rust)
text=text.replace('\t\t\t\tEE0000000000000000000003 /* Build Rust Core */,\n','')
dependency(APP,rust)

for name, intents in [("DaysideIntents",True),("DaysideWidgets",False)]:
    target=uid(name);sources=uid(name+"sources");resources=uid(name+"resources");frameworks=uid(name+"frameworks")
    for section,identifier in [("PBXSourcesBuildPhase",sources),("PBXResourcesBuildPhase",resources),("PBXFrameworksBuildPhase",frameworks)]:
        node(section,identifier,f'isa = {section}; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
    product=uid(name+"product")
    node("PBXFileReference",product,f'isa = PBXFileReference; explicitFileType = wrapper.app-extension; path = {name}.appex; sourceTree = BUILT_PRODUCTS_DIR; includeInIndex = 0;')
    append("AA0000000000000000000003","children",product)
    extra=f'APPLICATION_EXTENSION_API_ONLY = YES; GENERATE_INFOPLIST_FILE = NO; INFOPLIST_FILE = {name}/Info.plist; PRODUCT_BUNDLE_IDENTIFIER = com.dayside.Dayside.{"intents" if intents else "widgets"}; PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_MODULE_NAME = {name}; SKIP_INSTALL = YES; CURRENT_PROJECT_VERSION = 17; MARKETING_VERSION = 1.1.0; SWIFT_EMIT_LOC_STRINGS = YES; LD_RUNPATH_SEARCH_PATHS = ("$(inherited)","@executable_path/../Frameworks","@executable_path/../../../../Frameworks"); '
    if intents:
        extra+='SWIFT_OBJC_BRIDGING_HEADER = "$(SRCROOT)/RustCore/include/dayside_core.h"; LIBRARY_SEARCH_PATHS = ("$(inherited)","$(BUILT_PRODUCTS_DIR)"); OTHER_LDFLAGS = ("$(inherited)","-ldayside_intents"); '
    signing=uid(name+"sign")
    script='set -eu\n/usr/bin/codesign --force --sign - --timestamp=none --entitlements "$SRCROOT/'+name+'/Extension.entitlements" "$CODESIGNING_FOLDER_PATH"\n'
    node("PBXShellScriptBuildPhase",signing,'isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; alwaysOutOfDate = 1; files = (); inputPaths = ("$(TARGET_BUILD_DIR)/$(EXECUTABLE_PATH)",); outputPaths = (); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; name = "Sign extension"; shellScript = '+json.dumps(script)+';')
    product_type='com.apple.product-type.extensionkit-extension' if intents else 'com.apple.product-type.app-extension'
    node("PBXNativeTarget",target,f'isa = PBXNativeTarget; name = {name}; productName = {name}; productReference = {product}; productType = "{product_type}"; buildConfigurationList = {configurations(name,extra)}; buildPhases = ({sources},{frameworks},{resources},{signing},); dependencies = (); buildRules = ();')
    append(PROJECT_ID,"targets",target)
    dependency(APP,target)
    if intents: dependency(target,rust)
    source_files=[f'{name}/Dayside{"Intents" if intents else "Widgets"}.swift','Shared/SharedTimeData.swift']
    if not intents: source_files.append('Shared/DaysideControlIntents.swift')
    if intents: source_files += ['Shared/CivilCalendar.swift','Dayside/Models/RustCore.swift','Dayside/Models/TimeInput.swift','Dayside/Models/Planner/Availability.swift','Dayside/Models/Planner/OverlapPlanner.swift']
    for path in source_files: build_file(path,target,sources)
    # Each extension carries only the keys extracted from its own compiled sources.
    obsolete = uid('build:' + target + ':Dayside/Generated/Localizable.xcstrings')
    text = re.sub(r'^[^\n]*' + obsolete + r' = \{[^\n]*\n', '', text, flags=re.M)
    text = re.sub(r'^[ \t]*' + obsolete + r',\n', '', text, flags=re.M)
    for path in [f'{name}/PrivacyInfo.xcprivacy', f'{name}/Resources/Localizable.xcstrings']: build_file(path,target,resources)
    if intents: build_file('Dayside/Resources/AppShortcuts.xcstrings',target,resources)
    for path in [f'{name}/Info.plist',f'{name}/Extension.entitlements']: file(path)
    copy=uid(name+"copy");copyfile=uid(name+"embed")
    node("PBXBuildFile",copyfile,f'isa = PBXBuildFile; fileRef = {product}; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy,);}};')
    node("PBXCopyFilesBuildPhase",copy,f'isa = PBXCopyFilesBuildPhase; buildActionMask = 2147483647; dstPath = "{"$(CONTENTS_FOLDER_PATH)/Extensions" if intents else ""}"; dstSubfolderSpec = {16 if intents else 13}; files = ({copyfile},); name = "Embed {name}"; runOnlyForDeploymentPostprocessing = 0;')
    # Embed before signing the host.
    if copy not in re.search(r'\b'+APP+r' /\* Dayside \*/ = \{[\s\S]*?buildPhases = \(([\s\S]*?)\);',text)[1]:
        text=text.replace('\t\t\t\tAA00000000000000000000D0 /* Sign (ad-hoc, full entitlements) */,',f'\t\t\t\t{copy},\n\t\t\t\tAA00000000000000000000D0 /* Sign (ad-hoc, full entitlements) */,')

PROJECT.write_text("\n".join(line.rstrip() for line in text.splitlines()) + "\n")

# Scheme builds finish with an aggregate that depends on the complete app target.
# A source build phase runs before ExtractAppIntentsMetadata and cannot seal its output.
sign_target = uid("Final bundle sign")
sign_phase = uid("Final bundle sign phase")
node("PBXShellScriptBuildPhase", sign_phase,
     'isa = PBXShellScriptBuildPhase; buildActionMask = 2147483647; alwaysOutOfDate = 1; '
     'files = (); inputPaths = (); outputPaths = (); runOnlyForDeploymentPostprocessing = 0; '
     'shellPath = /bin/bash; name = "Seal complete bundle"; shellScript = '
     + json.dumps('bash "$SRCROOT/Tools/sign_bundle.sh" "$BUILT_PRODUCTS_DIR/Dayside.app"\n') + ';')
node("PBXAggregateTarget", sign_target,
     f'isa = PBXAggregateTarget; name = DaysideSign; productName = DaysideSign; '
     f'buildConfigurationList = {configurations("Final sign")}; buildPhases = ({sign_phase},); dependencies = ();')
append(PROJECT_ID, "targets", sign_target)
dependency(sign_target, APP)
PROJECT.write_text(text)

import xml.etree.ElementTree as ET
scheme = ROOT / "Dayside.xcodeproj/xcshareddata/xcschemes/Dayside.xcscheme"
tree = ET.parse(scheme)
entries = tree.getroot().find("BuildAction/BuildActionEntries")
if not any(ref.get("BlueprintIdentifier") == sign_target for ref in entries.iter("BuildableReference")):
    entry = ET.SubElement(entries, "BuildActionEntry", {
        "buildForTesting": "NO", "buildForRunning": "YES", "buildForProfiling": "YES",
        "buildForArchiving": "YES", "buildForAnalyzing": "YES"})
    ET.SubElement(entry, "BuildableReference", {"BuildableIdentifier": "primary", "BlueprintIdentifier": sign_target,
        "BuildableName": "DaysideSign", "BlueprintName": "DaysideSign", "ReferencedContainer": "container:Dayside.xcodeproj"})
    ET.indent(tree, space="   ")
    tree.write(scheme, encoding="UTF-8", xml_declaration=True)
