#!/usr/bin/env python3
import os
import hashlib

def generate_uuid(salt=''):
    """Generate a 24-character hex ID similar to Xcode's format"""
    h = hashlib.md5(salt.encode()).hexdigest()
    return h[:24].upper()

# Get all Swift files
swift_files = []
for root, dirs, files in os.walk('.'):
    # Skip build directories and SPM
    dirs[:] = [d for d in dirs if d not in ['Sources', '.build', 'Tonic.xcodeproj', '.swiftpm']]
    for f in files:
        if f.endswith('.swift') and f != 'Package.swift':
            rel_path = os.path.join(root, f).lstrip('./')
            swift_files.append(rel_path)

swift_files.sort()

# Generate unique IDs
project_id = generate_uuid('project')
main_group_id = generate_uuid('mainGroup')
target_id = generate_uuid('target')
products_group_id = generate_uuid('products')
sources_phase_id = generate_uuid('sources')
resources_phase_id = generate_uuid('resources')
frameworks_phase_id = generate_uuid('frameworks')
app_ref_id = generate_uuid('app')
config_list_id = generate_uuid('configlist')
target_config_list_id = generate_uuid('targetconfiglist')

# Generate file reference IDs
file_refs = {}
build_files = {}
for f in swift_files:
    ref_id = generate_uuid(f'file_{f}')
    file_refs[f] = ref_id
    bf_id = generate_uuid(f'build_{f}')
    build_files[f] = bf_id

# Start generating pbxproj
output = []
output.append('// !$*UTF8*$!')
output.append('{')
output.append('\tarchiveVersion = 1;')
output.append('\tclasses = {')
output.append('\t};')
output.append('\tobjectVersion = 56;')
output.append('\tobjects = {')

# PBXBuildFile section
output.append('/* Begin PBXBuildFile section */')
for f in swift_files:
    output.append(f'\t\t{build_files[f]} /* {os.path.basename(f)} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_refs[f]} /* {os.path.basename(f)} */; }};')
output.append('/* End PBXBuildFile section */')

# PBXFileReference section
output.append('/* Begin PBXFileReference section */')
output.append(f'\t\t{app_ref_id} /* Tonic.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Tonic.app; sourceTree = BUILT_PRODUCTS_DIR; }};')
for f in swift_files:
    # For files in subgroups, use just the filename as the path
    # The parent group's path attribute will resolve the full path
    output.append(f'\t\t{file_refs[f]} /* {os.path.basename(f)} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{os.path.basename(f)}"; sourceTree = "<group>"; }};')
output.append('/* End PBXFileReference section */')

# PBXFrameworksBuildPhase
output.append('/* Begin PBXFrameworksBuildPhase section */')
output.append(f'\t\t{frameworks_phase_id} /* Frameworks */ = {{')
output.append('\t\t\tisa = PBXFrameworksBuildPhase;')
output.append('\t\t\tbuildActionMask = 2147483647;')
output.append('\t\t\tfiles = (')
output.append('\t\t\t);')
output.append('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
output.append('\t\t};')
output.append('/* End PBXFrameworksBuildPhase section */')

# PBXGroup section
output.append('/* Begin PBXGroup section */')
output.append(f'\t\t{main_group_id} = {{')
output.append('\t\t\tisa = PBXGroup;')
output.append('\t\t\tchildren = (')
output.append(f'\t\t\t\t{generate_uuid("tonicgroup")} /* Tonic */,')
output.append(f'\t\t\t\t{products_group_id} /* Products */,')
output.append('\t\t\t);')
output.append('\t\t\tsourceTree = "<group>";')
output.append('\t\t};')
output.append(f'\t\t{products_group_id} /* Products */ = {{')
output.append('\t\t\tisa = PBXGroup;')
output.append('\t\t\tchildren = (')
output.append(f'\t\t\t\t{app_ref_id} /* Tonic.app */,')
output.append('\t\t\t);')
output.append('\t\t\tname = Products;')
output.append('\t\t\tsourceTree = "<group>";')
output.append('\t\t};')
output.append(f'\t\t{generate_uuid("tonicgroup")} /* Tonic */ = {{')
output.append('\t\t\tisa = PBXGroup;')
output.append('\t\t\tchildren = (')

# Add subgroups
models_group = generate_uuid('models')
views_group = generate_uuid('views')
utils_group = generate_uuid('utils')
services_group = generate_uuid('services')
design_group = generate_uuid('design')
output.append(f'\t\t\t\t{models_group} /* Models */,')
output.append(f'\t\t\t\t{views_group} /* Views */,')
output.append(f'\t\t\t\t{utils_group} /* Utilities */,')
output.append(f'\t\t\t\t{services_group} /* Services */,')
output.append(f'\t\t\t\t{design_group} /* Design */,')

# Add top-level files
for f in swift_files:
    parts = f.split('/')
    if len(parts) == 2 and parts[0] == 'Tonic':
        # Top level file
        fname = parts[1]
        output.append(f'\t\t\t\t{file_refs[f]} /* {fname} */,')
output.append('\t\t\t);')
output.append('\t\t\tpath = Tonic;')
output.append('\t\t\tsourceTree = "<group>";')
output.append('\t\t};')

# Models group
output.append(f'\t\t{models_group} /* Models */ = {{')
output.append('\t\t\tisa = PBXGroup;')
output.append('\t\t\tchildren = (')
for f in swift_files:
    if '/Models/' in f:
        output.append(f'\t\t\t\t{file_refs[f]} /* {os.path.basename(f)} */,')
output.append('\t\t\t);')
output.append('\t\t\tpath = Models;')
output.append('\t\t\tsourceTree = "<group>";')
output.append('\t\t};')

# Views group
output.append(f'\t\t{views_group} /* Views */ = {{')
output.append('\t\t\tisa = PBXGroup;')
output.append('\t\t\tchildren = (')
for f in swift_files:
    if '/Views/' in f:
        output.append(f'\t\t\t\t{file_refs[f]} /* {os.path.basename(f)} */,')
output.append('\t\t\t);')
output.append('\t\t\tpath = Views;')
output.append('\t\t\tsourceTree = "<group>";')
output.append('\t\t};')

# Utilities group
output.append(f'\t\t{utils_group} /* Utilities */ = {{')
output.append('\t\t\tisa = PBXGroup;')
output.append('\t\t\tchildren = (')
for f in swift_files:
    if '/Utilities/' in f:
        output.append(f'\t\t\t\t{file_refs[f]} /* {os.path.basename(f)} */,')
output.append('\t\t\t);')
output.append('\t\t\tpath = Utilities;')
output.append('\t\t\tsourceTree = "<group>";')
output.append('\t\t};')

# Services group
output.append(f'\t\t{services_group} /* Services */ = {{')
output.append('\t\t\tisa = PBXGroup;')
output.append('\t\t\tchildren = (')
for f in swift_files:
    if '/Services/' in f:
        output.append(f'\t\t\t\t{file_refs[f]} /* {os.path.basename(f)} */,')
output.append('\t\t\t);')
output.append('\t\t\tpath = Services;')
output.append('\t\t\tsourceTree = "<group>";')
output.append('\t\t};')

# Design group
output.append(f'\t\t{design_group} /* Design */ = {{')
output.append('\t\t\tisa = PBXGroup;')
output.append('\t\t\tchildren = (')
for f in swift_files:
    if '/Design/' in f:
        output.append(f'\t\t\t\t{file_refs[f]} /* {os.path.basename(f)} */,')
output.append('\t\t\t);')
output.append('\t\t\tpath = Design;')
output.append('\t\t\tsourceTree = "<group>";')
output.append('\t\t};')

output.append('/* End PBXGroup section */')

# PBXNativeTarget
output.append('/* Begin PBXNativeTarget section */')
output.append(f'\t\t{target_id} /* Tonic */ = {{')
output.append('\t\t\tisa = PBXNativeTarget;')
output.append(f'\t\t\tbuildConfigurationList = {target_config_list_id} /* Build configuration list for PBXNativeTarget "Tonic" */;')
output.append('\t\t\tbuildPhases = (')
output.append(f'\t\t\t\t{sources_phase_id} /* Sources */,')
output.append(f'\t\t\t\t{frameworks_phase_id} /* Frameworks */,')
output.append(f'\t\t\t\t{resources_phase_id} /* Resources */,')
output.append('\t\t\t);')
output.append('\t\t\tbuildRules = (')
output.append('\t\t\t);')
output.append('\t\t\tdependencies = (')
output.append('\t\t\t);')
output.append('\t\t\tname = Tonic;')
output.append('\t\t\tproductName = Tonic;')
output.append(f'\t\t\tproductReference = {app_ref_id} /* Tonic.app */;')
output.append('\t\t\tproductType = "com.apple.product-type.application";')
output.append('\t\t};')
output.append('/* End PBXNativeTarget section */')

# PBXProject
output.append('/* Begin PBXProject section */')
output.append(f'\t\t{project_id} /* Project object */ = {{')
output.append('\t\t\tisa = PBXProject;')
output.append('\t\t\tattributes = {')
output.append('\t\t\t\tBuildIndependentTargetsInParallel = 1;')
output.append('\t\t\t\tLastSwiftUpdateCheck = 1500;')
output.append('\t\t\t\tLastUpgradeCheck = 1500;')
output.append('\t\t\t\tTargetAttributes = {')
output.append(f'\t\t\t\t\t{target_id} = {{')
output.append('\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;')
output.append('\t\t\t\t\t\tSystemCapabilities = {')
output.append('\t\t\t\t\t\t\tcom.apple.Sandbox = {')
output.append('\t\t\t\t\t\t\t\tenabled = 0;')
output.append('\t\t\t\t\t\t\t};')
output.append('\t\t\t\t\t\t};')
output.append('\t\t\t\t\t};')
output.append('\t\t\t\t};')
output.append('\t\t\t};')
output.append(f'\t\t\tbuildConfigurationList = {config_list_id} /* Build configuration list for PBXProject "Tonic" */;')
output.append('\t\t\tcompatibilityVersion = "Xcode 14.0";')
output.append('\t\t\tdevelopmentRegion = en;')
output.append('\t\t\thasScannedForEncodings = 0;')
output.append('\t\t\tknownRegions = (')
output.append('\t\t\t\ten,')
output.append('\t\t\t\tBase,')
output.append('\t\t\t);')
output.append(f'\t\t\tmainGroup = {main_group_id};')
output.append(f'\t\t\tproductRefGroup = {products_group_id};')
output.append('\t\t\tprojectDirPath = "";')
output.append('\t\t\tprojectRoot = "";')
output.append('\t\t\ttargets = (')
output.append(f'\t\t\t\t{target_id} /* Tonic */,')
output.append('\t\t\t);')
output.append('\t\t};')
output.append('/* End PBXProject section */')

# PBXResourcesBuildPhase
output.append('/* Begin PBXResourcesBuildPhase section */')
output.append(f'\t\t{resources_phase_id} /* Resources */ = {{')
output.append('\t\t\tisa = PBXResourcesBuildPhase;')
output.append('\t\t\tbuildActionMask = 2147483647;')
output.append('\t\t\tfiles = (')
output.append('\t\t\t);')
output.append('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
output.append('\t\t};')
output.append('/* End PBXResourcesBuildPhase section */')

# PBXSourcesBuildPhase
output.append('/* Begin PBXSourcesBuildPhase section */')
output.append(f'\t\t{sources_phase_id} /* Sources */ = {{')
output.append('\t\t\tisa = PBXSourcesBuildPhase;')
output.append('\t\t\tbuildActionMask = 2147483647;')
output.append('\t\t\tfiles = (')
for f in swift_files:
    output.append(f'\t\t\t\t{build_files[f]} /* {os.path.basename(f)} in Sources */,')
output.append('\t\t\t);')
output.append('\t\t\trunOnlyForDeploymentPostprocessing = 0;')
output.append('\t\t};')
output.append('/* End PBXSourcesBuildPhase section */')

# XCBuildConfiguration
output.append('/* Begin XCBuildConfiguration section */')

# Debug config
output.append(f'\t\t{generate_uuid("debug_proj")} /* Debug */ = {{')
output.append('\t\t\tisa = XCBuildConfiguration;')
output.append('\t\t\tbuildSettings = {')
output.append('\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;')
output.append('\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;')
output.append('\t\t\t\tCLANG_ANALYZER_NONNULL = YES;')
output.append('\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";')
output.append('\t\t\t\tCLANG_ENABLE_MODULES = YES;')
output.append('\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;')
output.append('\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;')
output.append('\t\t\t\tCOPY_PHASE_STRIP = NO;')
output.append('\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;')
output.append('\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;')
output.append('\t\t\t\tENABLE_TESTABILITY = YES;')
output.append('\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;')
output.append('\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;')
output.append('\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;')
output.append('\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;')
output.append('\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;')
output.append('\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;')
output.append('\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;')
output.append('\t\t\t\tONLY_ACTIVE_ARCH = YES;')
output.append('\t\t\t\tSDKROOT = macosx;')
output.append('\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";')
output.append('\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";')
output.append('\t\t\t};')
output.append('\t\t\tname = Debug;')
output.append('\t\t};')

# Release config
output.append(f'\t\t{generate_uuid("release_proj")} /* Release */ = {{')
output.append('\t\t\tisa = XCBuildConfiguration;')
output.append('\t\t\tbuildSettings = {')
output.append('\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;')
output.append('\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;')
output.append('\t\t\t\tCLANG_ANALYZER_NONNULL = YES;')
output.append('\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "gnu++20";')
output.append('\t\t\t\tCLANG_ENABLE_MODULES = YES;')
output.append('\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;')
output.append('\t\t\t\tCLANG_WARN_UNGUARDED_AVAILABILITY = YES_AGGRESSIVE;')
output.append('\t\t\t\tCOPY_PHASE_STRIP = NO;')
output.append('\t\t\t\tDEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";')
output.append('\t\t\t\tENABLE_NS_ASSERTIONS = NO;')
output.append('\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;')
output.append('\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;')
output.append('\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;')
output.append('\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;')
output.append('\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;')
output.append('\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;')
output.append('\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;')
output.append('\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;')
output.append('\t\t\t\tSDKROOT = macosx;')
output.append('\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;')
output.append('\t\t\t};')
output.append('\t\t\tname = Release;')
output.append('\t\t};')

# Target Debug config
output.append(f'\t\t{generate_uuid("debug_target")} /* Debug */ = {{')
output.append('\t\t\tisa = XCBuildConfiguration;')
output.append('\t\t\tbuildSettings = {')
output.append('\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')
output.append('\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;')
output.append('\t\t\t\tCODE_SIGN_ENTITLEMENTS = Tonic/Tonic.entitlements;')
output.append('\t\t\t\tCODE_SIGN_STYLE = Automatic;')
output.append('\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;')
output.append('\t\t\t\tCURRENT_PROJECT_VERSION = 1;')
output.append('\t\t\t\tDEVELOPMENT_TEAM = "";')
output.append('\t\t\t\tENABLE_HARDENED_RUNTIME = NO;')
output.append('\t\t\t\tENABLE_PREVIEWS = YES;')
output.append('\t\t\t\tGENERATE_INFOPLIST_FILE = YES;')
output.append('\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "Tonic for Mac";')
output.append('\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.utilities";')
output.append('\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "";')
output.append('\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (')
output.append('\t\t\t\t\t"$(inherited)",')
output.append('\t\t\t\t\t"@executable_path/../Frameworks",')
output.append('\t\t\t\t);')
output.append('\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;')
output.append('\t\t\t\tMARKETING_VERSION = 0.1.0;')
output.append('\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.tonicformac.app;')
output.append('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
output.append('\t\t\t\tSDKROOT = macosx;')
output.append('\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;')
output.append('\t\t\t\tSWIFT_VERSION = 5.0;')
output.append('\t\t\t};')
output.append('\t\t\tname = Debug;')
output.append('\t\t};')

# Target Release config
output.append(f'\t\t{generate_uuid("release_target")} /* Release */ = {{')
output.append('\t\t\tisa = XCBuildConfiguration;')
output.append('\t\t\tbuildSettings = {')
output.append('\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;')
output.append('\t\t\t\tASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;')
output.append('\t\t\t\tCODE_SIGN_ENTITLEMENTS = Tonic/Tonic.entitlements;')
output.append('\t\t\t\tCODE_SIGN_STYLE = Automatic;')
output.append('\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;')
output.append('\t\t\t\tCURRENT_PROJECT_VERSION = 1;')
output.append('\t\t\t\tDEVELOPMENT_TEAM = "";')
output.append('\t\t\t\tENABLE_HARDENED_RUNTIME = NO;')
output.append('\t\t\t\tENABLE_PREVIEWS = YES;')
output.append('\t\t\t\tGENERATE_INFOPLIST_FILE = YES;')
output.append('\t\t\t\tINFOPLIST_KEY_CFBundleDisplayName = "Tonic for Mac";')
output.append('\t\t\t\tINFOPLIST_KEY_LSApplicationCategoryType = "public.app-category.utilities";')
output.append('\t\t\t\tINFOPLIST_KEY_NSHumanReadableCopyright = "";')
output.append('\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (')
output.append('\t\t\t\t\t"$(inherited)",')
output.append('\t\t\t\t\t"@executable_path/../Frameworks",')
output.append('\t\t\t\t);')
output.append('\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;')
output.append('\t\t\t\tMARKETING_VERSION = 0.1.0;')
output.append('\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.tonicformac.app;')
output.append('\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";')
output.append('\t\t\t\tSDKROOT = macosx;')
output.append('\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;')
output.append('\t\t\t\tSWIFT_VERSION = 5.0;')
output.append('\t\t\t};')
output.append('\t\t\tname = Release;')
output.append('\t\t};')

output.append('/* End XCBuildConfiguration section */')

# XCConfigurationList sections
output.append('/* Begin XCConfigurationList section */')
output.append(f'\t\t{config_list_id} /* Build configuration list for PBXProject "Tonic" */ = {{')
output.append('\t\t\tisa = XCConfigurationList;')
output.append('\t\t\tbuildConfigurations = (')
output.append(f'\t\t\t\t{generate_uuid("debug_proj")} /* Debug */,')
output.append(f'\t\t\t\t{generate_uuid("release_proj")} /* Release */,')
output.append('\t\t\t);')
output.append('\t\t\tdefaultConfigurationIsVisible = 0;')
output.append('\t\t\tdefaultConfigurationName = Release;')
output.append('\t\t};')
output.append(f'\t\t{target_config_list_id} /* Build configuration list for PBXNativeTarget "Tonic" */ = {{')
output.append('\t\t\tisa = XCConfigurationList;')
output.append('\t\t\tbuildConfigurations = (')
output.append(f'\t\t\t\t{generate_uuid("debug_target")} /* Debug */,')
output.append(f'\t\t\t\t{generate_uuid("release_target")} /* Release */,')
output.append('\t\t\t);')
output.append('\t\t\tdefaultConfigurationIsVisible = 0;')
output.append('\t\t\tdefaultConfigurationName = Release;')
output.append('\t\t};')
output.append('/* End XCConfigurationList section */')

output.append('\t};')
output.append('\trootObject = ' + project_id + ' /* Project object */;')
output.append('}')

# Write to file
os.makedirs('Tonic.xcodeproj', exist_ok=True)
with open('Tonic.xcodeproj/project.pbxproj', 'w') as f:
    f.write('\n'.join(output))

print("Created project.pbxproj with " + str(len(swift_files)) + " Swift files")
