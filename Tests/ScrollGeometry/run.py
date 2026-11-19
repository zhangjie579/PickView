#!/usr/bin/env python3
"""Compile InspectorKit's geometry sources on macOS and run regression cases.

A test-only UIKit adapter maps CGPoint/CGSize NSValue accessors and UIEdgeInsets
onto AppKit equivalents; production geometry code is compiled without changes.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import os
import shutil

root = Path(__file__).resolve().parents[2]
internal = root / 'KKFlutterInspectorKit/KKFlutterInspectorKit/Classes/Internal'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--enricher-source', type=Path, default=internal / 'Hierarchy/KKFIHierarchyEnricher.m')
parser.add_argument('--fixtures', type=Path, help='Replay runtime fixtures previously exported by scroll_matrix_test.dart')
parser.add_argument('--flutter-sdk', type=Path, help='Generate runtime fixtures with this Flutter SDK before replaying them')
args = parser.parse_args()
if args.fixtures and args.flutter_sdk:
    parser.error('Choose either --fixtures or --flutter-sdk.')
with tempfile.TemporaryDirectory(prefix='pv-scroll-geometry-') as temporary:
    temp = Path(temporary)
    (temp / 'UIKit').mkdir()
    (temp / 'UIKit/UIKit.h').write_text('''#import <AppKit/AppKit.h>
#define UIImage NSImage
#define UIEdgeInsets NSEdgeInsets
#define UIEdgeInsetsZero NSEdgeInsetsZero
#define UIEdgeInsetsMake NSEdgeInsetsMake
@interface NSImage (PVGeometryTest)
@property(nonatomic, readonly) CGImageRef CGImage;
@end
@interface NSValue (PVGeometryTest)
+ (NSValue *)valueWithCGPoint:(CGPoint)value;
+ (NSValue *)valueWithCGSize:(CGSize)value;
@property(nonatomic, readonly) CGPoint CGPointValue;
@property(nonatomic, readonly) CGSize CGSizeValue;
@end
''')
    flags = ['-fobjc-arc', '-fmodules', f'-fmodules-cache-path={temp}/modules', '-I', str(temp)]
    for path in [internal, *internal.rglob('*')]:
        if path.is_dir():
            flags += ['-I', str(path)]
    sources = [Path(__file__).with_name('ScrollGeometryTests.m'), args.enricher_source,
               internal / 'Inspector/KKFIInspectorTreeBuilder.m', internal / 'Inspector/KKFIInspectorJSON.m',
               internal / 'Model/KKFIInspectorModels.m']
    binary = str(temp / 'scroll-geometry-tests')
    subprocess.run(['clang', *flags, *map(str, sources), '-framework', 'Foundation', '-framework', 'AppKit', '-o', binary], check=True)
    fixtures = args.fixtures.resolve() if args.fixtures else None
    if args.flutter_sdk:
        flutter = str(args.flutter_sdk.resolve() / 'bin/flutter')
        package = temp / 'flutter_package'
        (package / 'test').mkdir(parents=True)
        (package / 'pubspec.yaml').write_text("name: pickview_scroll_geometry_tests\nenvironment:\n  sdk: '>=3.0.0 <4.0.0'\ndependencies:\n  flutter:\n    sdk: flutter\ndev_dependencies:\n  flutter_test:\n    sdk: flutter\n")
        shutil.copyfile(Path(__file__).with_name('scroll_matrix_test.dart'), package / 'test/scroll_matrix_test.dart')
        fixtures = temp / 'runtime_cases.json'
        environment = dict(os.environ, PV_SCROLL_MATRIX_FIXTURE=str(fixtures))
        subprocess.run([flutter, '--suppress-analytics', 'pub', 'get', '--offline'], cwd=package, env=environment, check=True)
        subprocess.run([flutter, '--suppress-analytics', 'test', '--no-pub', '--reporter', 'expanded'], cwd=package, env=environment, check=True)
    subprocess.run([binary, *([str(fixtures)] if fixtures else [])], check=True)
