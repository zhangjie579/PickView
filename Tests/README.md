# Inspector regression tests

Build the macOS pods and PickViewMac in Debug, then run the native tests against
that build's objects and products:

```sh
python3 Tests/run-native-layout-tests.py \
  --objects-dir <DerivedData>/Build/Intermediates.noindex/PickView.build/Debug/PickViewMac.build/Objects-normal/arm64 \
  --products-dir build/Debug
```

The runner bundles the App's resources so AppKit layout uses the same assets as
the real inspector. The tests cover preview visibility, layout JSON parsing,
enum menus, outgoing modification requests, error recovery, stale responses,
secure wire archives, and selection/visibility preservation during tree refresh.

For the Flutter runtime test, copy `FlutterOfficialLayoutExtensionsTest.dart`
into the `test/` directory of a Flutter project that depends on `flutter_test`
and run `flutter test`. It exercises every main/cross axis enum combination,
both FlexFit values, flex integers/null, and unsupported target handling using
the SDK's actual service extension callbacks and render objects.

`Fixtures/FlutterLayout.json` contains the relevant fields from the runtime test's
actual Flutter 3.38.6 response. Set `PV_LAYOUT_FIXTURE` to an output JSON path when
running the Flutter test to export its complete responses.
