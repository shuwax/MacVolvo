#!/usr/bin/env python3
"""Build Phase 3's native app using CLI tools; no Xcode project/GUI required.

Private preview embeds the exact qualified Phase 2 archive. No account, game,
cache, or installed prefix is copied. Uses the tracked owner artwork by default; --icon accepts an ICNS override.
The bundle is named Recall; its identifier and data folder keep their original values.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
from build_portable_setup import MINIMUM_MACOS, build as build_setup
from derive_runtime import archive_minimum, check_archive, format_macos, parse_macos

ROOT=Path(__file__).resolve().parents[1]
# The bundle and executable name players see; Brand.swift holds the in-app
# copy. Its own identifier and data folder keep it apart from Recall, which it is built on.
APP_NAME='MacVolvo'
APP_BUILD='9'
# The games' voice chat runs under this app's microphone permission (Microphone.swift); the
# hardened runtime gives an app signed without the entitlement silence, with no prompt.
ENTITLEMENTS={'com.apple.security.device.audio-input':True}
MICROPHONE_USAGE='Voice chat in Counter-Strike 2 and Deadlock uses your microphone.'
RESOURCES=('Wordmark.png','WordmarkDark.png')
# llvm-mingw (docs/HANDOFF.md) builds the Windows stand-in for Steam's steamwebhelper.exe.
MINGW_CLANG=ROOT/'runtime/toolchains/llvm-mingw-20261006-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang'
def run(*args):subprocess.run([str(a) for a in args],check=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

# Files to extract from the DXMT patch (all are new-file additions, so the full
# content is present as '+' lines between their hunk header and the next diff).
_PIPELINE_PATCH_FILES = {
    'src/winemetal/unix/pipeline_cache.c',
    'src/winemetal/unix/pipeline_cache.h',
    'src/winemetal/unix/pipeline_recipe.c',
    'src/winemetal/unix/pipeline_recipe.h',
}

def _extract_pipeline_sources(workspace: Path) -> Path:
    """Parse dxmt-v1-private.patch and write the four pipeline source files."""
    source_dir = workspace / 'pipeline-source'
    source_dir.mkdir(parents=True, exist_ok=True)
    patch_text = (ROOT / 'patches/dxmt-v1-private.patch').read_text(encoding='utf-8', errors='replace')
    collected: dict[str, list[str]] = {}
    current: str | None = None
    in_hunk = False
    for line in patch_text.splitlines():
        if line.startswith('diff --git '):
            current = None; in_hunk = False
        elif line.startswith('+++ b/'):
            path = line[6:]
            current = path if path in _PIPELINE_PATCH_FILES else None
            if current: collected[current] = []; in_hunk = False
        elif line.startswith('@@ ') and current:
            in_hunk = True
        elif in_hunk and current:
            if line.startswith('+') and not line.startswith('+++'):
                collected[current].append(line[1:])
    for path in _PIPELINE_PATCH_FILES:
        if path not in collected:
            raise ValueError(f'Could not extract {path} from patch')
        (source_dir / Path(path).name).write_text('\n'.join(collected[path]) + '\n')
    return source_dir

def build_pipeline_helpers(helpers: Path, workspace: Path) -> None:
    """Build pipeline-prepare (x86_64) and pipeline-setup (arm64) into helpers."""
    source_dir = _extract_pipeline_sources(workspace)
    build_dir = workspace / 'pipeline-prepare-build'
    build_dir.mkdir(parents=True, exist_ok=True)
    # winemetal.h stub: WMTRenderPipelineInfo is defined in the unpatched winemetal.h
    # which is not in this repo. dxmt_recipe_capture is never called in offline-tool
    # mode so field types and layout only need to satisfy the compiler, not match ABI.
    winemetal_stub = (
        '#pragma once\n#define WINEMETAL_API\n'
        'struct _bal_t { void *ptr; };\n'
        'struct WMTRenderPipelineInfo {\n'
        '    void *vertex_function; void *fragment_function;\n'
        '    unsigned int logic_operation_enabled; unsigned int logic_operation;\n'
        '    void *binary_archive_for_serialization;\n'
        '    struct _bal_t binary_archives_for_lookup;\n'
        '    unsigned int num_binary_archives_for_lookup;\n'
        '    unsigned int fail_on_binary_archive_miss;\n'
        '};\n'
    )
    # pipeline_recipe.c includes "../winemetal.h" (one level above source_dir).
    (build_dir / 'winemetal.h').write_text(winemetal_stub)
    (source_dir.parent / 'winemetal.h').write_text(winemetal_stub)
    library = build_dir / 'libpipeline_prepare.dylib'
    # Compile the DXMT pipeline cache as a standalone dylib (x86_64, offline-tool mode).
    run('/usr/bin/clang', '-arch', 'x86_64', '-x', 'objective-c', '-fblocks', '-fno-objc-arc',
        '-DDXMT_PIPELINE_CACHE_OFFLINE_TOOL', '-O2', '-I', build_dir, '-dynamiclib',
        source_dir / 'pipeline_recipe.c', source_dir / 'pipeline_cache.c',
        '-framework', 'Foundation', '-framework', 'Metal', '-framework', 'QuartzCore',
        '-install_name', '@loader_path/libpipeline_prepare.dylib', '-o', library)
    run('/usr/bin/clang', '-arch', 'x86_64', '-x', 'objective-c', '-fblocks', '-fobjc-arc',
        '-DDXMT_PIPELINE_CACHE_OFFLINE_TOOL', '-O2', '-I', source_dir,
        '-c', ROOT / 'scripts/pipeline_prepare.m', '-o', build_dir / 'main.o')
    run('/usr/bin/clang', '-arch', 'x86_64', build_dir / 'main.o', library,
        '-framework', 'Foundation', '-framework', 'Metal', '-o', helpers / 'pipeline-prepare')
    shutil.copy2(library, helpers / 'libpipeline_prepare.dylib')
    # Compile the Swift orchestrator (arm64 native; calls pipeline-prepare as subprocess).
    run('/usr/bin/swiftc', '-O', '-target', 'arm64-apple-macos' + MINIMUM_MACOS,
        ROOT / 'scripts/portable_pipeline.swift', '-o', helpers / 'pipeline-setup')

def build(output,workspace,runtime_archive,icon=None,identity=None,variant='dxmt'):
    if variant not in ('dxmt','gptk4'):raise ValueError('Unknown app variant')
    evaluation=variant=='gptk4'
    app_name='MacVolvo GPTK4' if evaluation else APP_NAME
    bundle_id='app.macvolvo.gptk4' if evaluation else 'app.macvolvo.launcher'
    release=json.loads((ROOT/'app/Resources/release.json').read_text())
    if evaluation:
        runtime_manifest=check_archive(runtime_archive)
        proof=json.loads(Path(str(runtime_archive).removesuffix('.tar.gz')+'.proof.json').read_text())
        if runtime_manifest.get('graphics_backend')!='d3dmetal' or not runtime_manifest.get('gptk_version','').startswith('4.'):
            raise ValueError('GPTK4 app requires a D3DMetal 4 runtime')
        if proof['archive_sha256']!=sha(runtime_archive):raise ValueError('GPTK4 import proof mismatch')
        release.update(runtimeVersion=runtime_manifest['version'],runtimeSHA256=proof['archive_sha256'],distribution='gptk4-evaluation')
    if sha(runtime_archive)!=release['runtimeSHA256']:raise ValueError('Unqualified runtime archive')
    # The worker rejects any file its manifest does not list, so check before shipping.
    if check_archive(runtime_archive)['version']!=release['runtimeVersion']:raise ValueError('Runtime archive names a different version')
    # Every engine binary must open on the app's minimum macOS (derive_runtime.py --minimum-macos re-stamps them).
    # An engine stamped older (1.1's 15.0) is fine: the app is what refuses older macOS.
    newest,declared=archive_minimum(runtime_archive)
    if newest>parse_macos(MINIMUM_MACOS) or parse_macos(declared)>parse_macos(MINIMUM_MACOS):
        raise ValueError(f'The runtime needs macOS {format_macos(newest)} (manifest: {declared}); the app supports {MINIMUM_MACOS}')
    if output.exists():raise ValueError('Choose a new output bundle; previous candidates are retained')
    helpers=output/'Contents/Helpers';resources=output/'Contents/Resources';macos=output/'Contents/MacOS'
    for directory in (helpers,resources,macos):directory.mkdir(parents=True)
    build_setup(helpers/'ow2-setup',ROOT/'runtime/toolchains/libarchive-3.7.7',defines=('MACVOLVO_GPTK4',) if evaluation else ())
    shutil.move(helpers/'ow2-setup.build.json',output.parent/'worker-build.json')
    if not evaluation:build_pipeline_helpers(helpers,workspace)
    run('/usr/bin/swiftc','-file-prefix-map',str(ROOT)+'=/ow2-source','-O','-target','arm64-apple-macos'+MINIMUM_MACOS,'-parse-as-library',*(['-D','MACVOLVO_GPTK4'] if evaluation else []),*sorted((ROOT/'app/Sources').glob('*.swift')),'-o',macos/app_name)
    run('/usr/bin/swiftc','-file-prefix-map',str(ROOT)+'=/ow2-source','-O','-target','arm64-apple-macos'+MINIMUM_MACOS,ROOT/'scripts/portable_pipeline.swift','-o',helpers/'pipeline-setup')
    # Steam's window on Wine 11 (portable_steam.h): the worker puts this in steamwebhelper.exe's place.
    run(MINGW_CLANG,'-O2','-municode','-mwindows','-ffile-prefix-map='+str(ROOT)+'=/ow2-source',ROOT/'scripts/webhelper_wrapper.c','-o',resources/'steamwebhelper.exe')
    rosetta=helpers/'Rosetta Check.app/Contents';(rosetta/'MacOS').mkdir(parents=True)
    source=output.parent/'rosetta-check.c';source.write_text('int main(void) { return 0; }\n')
    run('/usr/bin/clang','-ffile-prefix-map='+str(ROOT)+'=/ow2-source','-arch','x86_64','-mmacosx-version-min='+MINIMUM_MACOS,source,'-o',rosetta/'MacOS/RosettaCheck')
    (rosetta/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle_id+'.rosetta-check' if evaluation else 'app.macvolvo.rosetta-check','CFBundleExecutable':'RosettaCheck','CFBundleName':'Rosetta Check','CFBundlePackageType':'APPL','LSUIElement':True,'LSMinimumSystemVersion':MINIMUM_MACOS}))
    run('/bin/cp','-c',runtime_archive,resources/release['runtimeArchive'])
    (resources/'release.json').write_text(json.dumps(release,separators=(',',':'))+'\n')
    shutil.copy2(ROOT/'docs/candidate-parity-contract.json',resources/'candidate-parity-contract.json')
    # Notices from the actual reviewed runtime; kept readable without extraction.
    with tempfile.TemporaryDirectory() as folder:
        run('/usr/bin/tar','-xzf',runtime_archive,'-C',folder,'licenses')
        shutil.copytree(Path(folder)/'licenses',resources/'Licenses')
    shutil.copy2(ROOT/'licenses/PROJECT-APACHE-2.0',resources/'PROJECT-LICENSE.txt')
    shutil.copy2(ROOT/'licenses/PROJECT-NOTICE',resources/'NOTICE.txt')
    shutil.copy2(ROOT/'licenses/GITHUB-MARK-NOTICE.txt',resources/'GITHUB-MARK-NOTICE.txt')
    shutil.copy2(ROOT/'licenses/PROJECT-LINKS-NOTICE.txt',resources/'PROJECT-LINKS-NOTICE.txt')
    for name in RESOURCES:
        shutil.copy2(ROOT/'app/Resources'/name,resources/name)
    # Chakra Petch (SIL OFL 1.1) with its license, registered by LauncherStyle at run time.
    shutil.copytree(ROOT/'app/Resources/Fonts',resources/'Fonts')
    if icon:shutil.copy2(icon,resources/'AppIcon.icns')
    else:
        iconset=output.parent/'AppIcon.iconset'
        run('/usr/bin/swift',ROOT/'scripts/app_icon.swift',ROOT/'app/Resources/AppIcon.png',iconset)
        run('/usr/bin/iconutil','-c','icns',iconset,'-o',resources/'AppIcon.icns')
    (output/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':bundle_id,'CFBundleExecutable':app_name,'CFBundleName':app_name,'CFBundleDisplayName':app_name,'CFBundlePackageType':'APPL','CFBundleShortVersionString':release['appVersion'],'CFBundleVersion':APP_BUILD,'CFBundleIconFile':'AppIcon','LSMinimumSystemVersion':MINIMUM_MACOS,'NSHighResolutionCapable':True,'LSMultipleInstancesProhibited':True,'NSPrincipalClass':'NSApplication','NSMicrophoneUsageDescription':MICROPHONE_USAGE,'NSHumanReadableCopyright':'Independent community project based on Recall. Not affiliated with or endorsed by Valve, Volvo or Apple.'}))
    if identity:
        timestamp=['--timestamp'] if identity!='-' else []
        pipeline_binaries=[helpers/'libpipeline_prepare.dylib',helpers/'pipeline-prepare',helpers/'pipeline-setup'] if not evaluation else []
        for binary in ([helpers/'ow2-setup']+[b for b in pipeline_binaries if b.exists()]+[rosetta.parent]):
            run('/usr/bin/codesign','--force','--options','runtime',*timestamp,'--sign',identity,binary)
        with tempfile.TemporaryDirectory() as folder:
            entitlements=Path(folder)/'app.entitlements';entitlements.write_bytes(plistlib.dumps(ENTITLEMENTS))
            run('/usr/bin/codesign','--force','--options','runtime',*timestamp,'--entitlements',entitlements,'--sign',identity,output)
        run('/usr/bin/codesign','--verify','--deep','--strict',output)
    proof={'app_version':release['appVersion'],'app_build':APP_BUILD,'variant':variant,'bundle_identifier':bundle_id,'candidate_contract_sha256':sha(resources/'candidate-parity-contract.json'),'runtime_sha256':sha(resources/release['runtimeArchive']),'source_files':{str(p.relative_to(ROOT)):sha(p) for p in sorted((ROOT/'app').rglob('*')) if p.is_file()},'signed':bool(identity and identity!='-'),'signature_type':'ad-hoc' if identity=='-' else ('Developer ID' if identity else 'none'),'files':{str(p.relative_to(output)):sha(p) for p in output.rglob('*') if p.is_file()}}
    output.with_suffix('.build.json').write_text(json.dumps(proof,indent=2)+'\n')
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);p.add_argument('--workspace',type=Path,default=ROOT/'runtime');p.add_argument('--runtime-archive',type=Path,default=ROOT/'runtime/downloads/runtime.tar.gz');p.add_argument('--icon',type=Path);p.add_argument('--identity')
    p.add_argument('--variant',choices=('dxmt','gptk4'),default='dxmt')
    a=p.parse_args();build(a.output.resolve(),a.workspace.resolve(),a.runtime_archive.resolve(),a.icon,a.identity,a.variant)
