# Scroll geometry regression tests

Run the small geometry regressions (32 cases):

```sh
python3 Tests/ScrollGeometry/run.py
```

Generate real Inspector responses and expected render positions with a Flutter
SDK, then replay those responses through the production Objective-C enricher
and tree builder (51 runtime cases plus the 32 regressions):

```sh
python3 Tests/ScrollGeometry/run.py --flutter-sdk /path/to/flutter
```

The Flutter stage uses a temporary test package and cached dependencies
(`flutter pub get --offline`). It covers SingleChildScrollView, ListView,
GridView, CustomScrollView, PageView and NestedScrollView; fixed viewport
heights; NeverScrollableScrollPhysics; content that fits without scrolling;
shrinkWrap lists/grids inside another scroll view; horizontal/reverse scrolling;
and NestedScrollView → PageView → CustomScrollView nesting.

A geometry case passes only when the expected widgets exist in the produced
hierarchy and their cumulative positions match Flutter's `tester.getTopLeft`.
Logical/business widgets without RenderObject diagnostics and wrappers sharing
one RenderObject are included. No test changes a connected application's state.

Previously exported runtime data can be replayed without Flutter:

```sh
python3 Tests/ScrollGeometry/run.py --fixtures /path/to/runtime_cases.json
```

The native test's UIKit adapter maps value types to AppKit so the unchanged
production geometry sources can run on macOS; it does not render UI or images.
