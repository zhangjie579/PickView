import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';

class LayoutInspector extends Object with WidgetInspectorService {
  final callbacks = <String, ServiceExtensionCallback>{};
  @override
  void registerServiceExtension({
    required String name,
    required ServiceExtensionCallback callback,
    required RegisterServiceExtensionCallback registerExtension,
  }) {
    callbacks[name] = callback;
  }

  String elementId(Element element) => toId(element, 'pickview-scroll-matrix')!;
  Future<Object?> call(String name, Map<String, String> parameters) async =>
      (await callbacks[name]!(parameters))['result'];
}

class BusinessCard extends StatelessWidget {
  const BusinessCard({super.key, this.height = 1200});
  final double height;
  @override
  Widget build(BuildContext context) =>
      SizedBox(key: const ValueKey('marker'), height: height, width: 300);
}

void main() {
  final service = LayoutInspector();
  WidgetInspectorService.instance = service;
  testWidgets('scroll widget geometry matrix', (tester) async {
    final records = <Map<String, Object?>>[];
    Future<void> capture(
      String name,
      Widget scroll,
      List<String> keys,
      VoidCallback action,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              key: const ValueKey('page'),
              children: [
                const SizedBox(height: 94),
                Expanded(child: scroll),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      action();
      await tester.pump();
      final root = service.elementId(
        tester.element(find.byKey(const ValueKey('page'))),
      );
      final layout =
          (await service.call('getLayoutExplorerNode', {
                'id': root,
                'groupName': 'pickview-scroll-matrix',
                'subtreeDepth': '100',
              }))!
              as Map<String, Object?>;
      final details = <String, Object?>{};
      final properties = <String, Object?>{};
      Future<void> visit(Map<String, Object?> n) async {
        final id = n['valueId'] as String?;
        if (id != null) {
          details[id] = await service.call('getDetailsSubtree', {
            'arg': id,
            'objectGroup': 'pickview-scroll-matrix',
            'subtreeDepth': '32',
          });
          properties[id] = await service.call('getProperties', {
            'arg': id,
            'objectGroup': 'pickview-scroll-matrix',
          });
        }
        for (final c in n['children'] as List? ?? []) {
          await visit((c as Map).cast<String, Object?>());
        }
      }

      await visit(layout);
      final expected = <String, Object?>{};
      for (final k in keys) {
        final f = find.byKey(ValueKey(k), skipOffstage: false);
        final p = tester.getTopLeft(f);
        expected[service.elementId(tester.element(f))] = {
          'x': p.dx,
          'y': p.dy,
          'name': k,
        };
      }
      records.add({
        'name': name,
        'rootId': root,
        'layout': layout,
        'details': details,
        'properties': properties,
        'expected': expected,
      });
    }

    for (final fixed in [false, true])
      for (final disabled in [false, true])
        for (final offset in [0.0, 80.0]) {
          final c = ScrollController();
          final single = SingleChildScrollView(
            controller: c,
            physics: disabled ? const NeverScrollableScrollPhysics() : null,
            child: Column(
              key: const ValueKey('content'),
              children: const [BusinessCard()],
            ),
          );
          await capture(
            'single fixed=$fixed disabled=$disabled offset=$offset',
            fixed
                ? Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(height: 180, child: single),
                  )
                : single,
            ['content', 'marker'],
            () => c.jumpTo(offset),
          );
        }
    for (final outer in [0.0, 80.0])
      for (final inner in [0.0, 40.0]) {
        final o = ScrollController(), i = ScrollController();
        await capture(
          'single nested outer=$outer inner=$inner',
          SingleChildScrollView(
            controller: o,
            child: Column(
              children: [
                const SizedBox(height: 100),
                SizedBox(
                  height: 180,
                  child: SingleChildScrollView(
                    controller: i,
                    child: Column(
                      key: const ValueKey('content'),
                      children: const [BusinessCard()],
                    ),
                  ),
                ),
                const SizedBox(height: 1000),
              ],
            ),
          ),
          ['content', 'marker'],
          () {
            o.jumpTo(outer);
            i.jumpTo(inner);
          },
        );
      }
    for (final type in [
      'list',
      'grid',
      'custom',
      'horizontal',
      'reverse',
      'page',
    ])
      for (final offset in [0.0, 80.0])
        for (final disabled in [false, true]) {
          final c = ScrollController();
          final pc = PageController();
          final physics = disabled
              ? const NeverScrollableScrollPhysics()
              : null;
          Widget scroll;
          if (type == 'list' || type == 'horizontal' || type == 'reverse')
            scroll = ListView(
              controller: c,
              physics: physics,
              reverse: type == 'reverse',
              scrollDirection: type == 'horizontal'
                  ? Axis.horizontal
                  : Axis.vertical,
              children: const [
                BusinessCard(height: 1200),
                SizedBox(width: 1200, height: 1200),
              ],
            );
          else if (type == 'grid')
            scroll = GridView.count(
              controller: c,
              physics: physics,
              crossAxisCount: 2,
              childAspectRatio: 2,
              children: List.generate(
                30,
                (i) => SizedBox(key: i == 0 ? const ValueKey('marker') : null),
              ),
            );
          else if (type == 'page')
            scroll = PageView(
              controller: pc,
              physics: physics,
              children: const [BusinessCard(), SizedBox()],
            );
          else
            scroll = CustomScrollView(
              controller: c,
              physics: physics,
              slivers: const [
                SliverPadding(
                  padding: EdgeInsets.all(16),
                  sliver: SliverToBoxAdapter(child: BusinessCard()),
                ),
                SliverToBoxAdapter(child: SizedBox(height: 1200)),
              ],
            );
          await capture(
            '$type offset=$offset disabled=$disabled',
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(height: 180, child: scroll),
            ),
            ['marker'],
            () {
              if (type == 'page')
                pc.jumpTo(offset);
              else
                c.jumpTo(offset);
            },
          );
        }
    for (final outer in [0.0, 125.0])
      for (final inner in [0.0, 40.0]) {
        final o = ScrollController();
        final k = GlobalKey<NestedScrollViewState>();
        final header = KeyedSubtree(
          key: const ValueKey('header'),
          child: const BusinessCard(height: 93),
        );
        await capture(
          'nested outer=$outer inner=$inner',
          NestedScrollView(
            key: k,
            controller: o,
            headerSliverBuilder: (c, b) => [
              SliverPadding(
                padding: const EdgeInsets.all(16),
                sliver: SliverToBoxAdapter(child: header),
              ),
            ],
            body: Column(
              key: const ValueKey('body'),
              children: [
                const SizedBox(height: 100),
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: SizedBox(
                          key: const ValueKey('inner-marker'),
                          height: 1200,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          ['header', 'body', 'inner-marker'],
          () {
            k.currentState!.innerController.jumpTo(inner);
            o.jumpTo(outer);
          },
        );
      }
    for (final outer in [0.0, 125.0])
      for (final page in [0, 1])
        for (final inner in [0.0, 40.0]) {
          final o = ScrollController();
          final pages = PageController(initialPage: page, keepPage: false);
          final k = GlobalKey<NestedScrollViewState>();
          await capture(
            'nested + page + custom outer=$outer page=$page inner=$inner',
            NestedScrollView(
              key: k,
              controller: o,
              headerSliverBuilder: (context, scrolled) => [
                const SliverToBoxAdapter(
                  child: SizedBox(key: ValueKey('header'), height: 125),
                ),
              ],
              body: PageView(
                controller: pages,
                children: List.generate(
                  2,
                  (index) => Builder(
                    builder: (context) => CustomScrollView(
                      controller: context
                          .findAncestorStateOfType<NestedScrollViewState>()!
                          .innerController,
                      slivers: [
                        SliverToBoxAdapter(
                          child: SizedBox(
                            key: ValueKey('page-$index-marker'),
                            height: 1200,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            ['header', 'page-$page-marker'],
            () {
              k.currentState!.innerController.jumpTo(inner);
              o.jumpTo(outer);
            },
          );
        }
    for (final type in ['list', 'grid']) {
      final outer = ScrollController();
      final inner = type == 'list'
          ? ListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: const [
                SizedBox(key: ValueKey('inner-marker'), height: 40),
                SizedBox(height: 120),
              ],
            )
          : GridView.count(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisCount: 2,
              children: List.generate(
                4,
                (i) => SizedBox(
                  key: i == 0 ? const ValueKey('inner-marker') : null,
                ),
              ),
            );
      await capture(
        'outer single with non-scrollable shrinkWrap $type',
        SingleChildScrollView(
          controller: outer,
          child: Column(
            children: [
              const SizedBox(height: 100),
              inner,
              const SizedBox(height: 1000),
            ],
          ),
        ),
        ['inner-marker'],
        () => outer.jumpTo(80),
      );
    }
    await capture(
      'fixed single content fits viewport',
      const Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          height: 180,
          child: SingleChildScrollView(
            physics: NeverScrollableScrollPhysics(),
            child: SizedBox(key: ValueKey('marker'), height: 40),
          ),
        ),
      ),
      ['marker'],
      () {},
    );
    final path =
        Platform.environment['PV_SCROLL_MATRIX_FIXTURE'] ??
        '${Directory.systemTemp.path}/pickview-scroll-matrix.json';
    File(path).writeAsStringSync(jsonEncode(records));
    print('Exported ${records.length} runtime geometry cases');
  });
}
