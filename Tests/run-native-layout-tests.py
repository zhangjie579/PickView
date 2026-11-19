#!/usr/bin/env python3
"""Run native inspector tests against a completed macOS Debug build.

Example:
  python3 Tests/run-native-layout-tests.py \
    --objects-dir /tmp/pickview-widget-visibility-build/Build/Intermediates.noindex/PickView.build/Debug/PickViewMac.build/Objects-normal/arm64 \
    --products-dir build/Debug
"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import shutil
import plistlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--objects-dir', required=True, type=Path)
parser.add_argument('--products-dir', required=True, type=Path)
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
objects = [str(p.resolve()) for p in args.objects_dir.glob('*.o') if p.name != 'main.o']
libraries = [str(p.resolve()) for p in args.products_dir.rglob('*.a')]
if not objects or not libraries:
    parser.error('Build PickViewMac and its macOS pods before running these tests.')
include_roots = [root / 'Source', root / 'Pods/Headers/Public']
includes = [p for base in include_roots for p in [base, *base.rglob('*')] if p.is_dir()]
with tempfile.TemporaryDirectory(prefix='pv-native-layout-tests-') as temporary:
    flags = ['-fobjc-arc', '-fmodules', f'-fmodules-cache-path={temporary}/modules', '-ObjC', '-Wno-nullability-completeness']
    for path in includes:
        flags.extend(['-I', str(path)])
    frameworks = [arg for name in ['Foundation', 'AppKit', 'QuartzCore', 'SceneKit', 'WebKit', 'Network'] for arg in ['-framework', name]]
    for source in sorted((root / 'Tests').glob('*.m')):
        bundle = Path(temporary) / (source.stem + '.app') / 'Contents'
        (bundle / 'MacOS').mkdir(parents=True)
        resources = args.products_dir / 'PickViewMac.app/Contents/Resources'
        if resources.exists():
            shutil.copytree(resources, bundle / 'Resources')
        (bundle / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': source.stem,
            'CFBundleIdentifier': 'com.pickview.tests.' + source.stem,
            'CFBundlePackageType': 'APPL',
        }))
        binary = str(bundle / 'MacOS' / source.stem)
        extra_sources = []
        if source.stem == 'FlutterLayoutWireTests':
            extra_sources.append(str(root / 'Source/PickViewServerKit/Internal/RequestHandling/PVHierarchyDetailsHandler.m'))
        subprocess.run(['clang', *flags, str(source), *extra_sources, *objects, *libraries, *frameworks, '-o', binary], cwd=root, check=True)
        subprocess.run([binary], cwd=root, check=True)
        print(f'PASS {source.name}', flush=True)
