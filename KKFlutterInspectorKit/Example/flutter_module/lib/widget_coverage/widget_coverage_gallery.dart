import 'package:flutter/material.dart';

import 'interaction_coverage_page.dart';
import 'layout_coverage_page.dart';
import 'paint_coverage_page.dart';
import 'route_coverage_page.dart';
import 'scroll_coverage_page.dart';

class WidgetCoverageGalleryPage extends StatelessWidget {
  const WidgetCoverageGalleryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final entries = <_CoverageEntry>[
      _CoverageEntry(
        icon: Icons.dashboard_customize_outlined,
        title: 'Layout & Constraints',
        subtitle: 'Flex、Wrap、Stack、Table、Flow 与约束传递',
        builder: (_) => const LayoutCoveragePage(),
      ),
      _CoverageEntry(
        icon: Icons.view_day_outlined,
        title: 'Scroll & Sliver',
        subtitle: 'CustomScrollView、SliverAppBar、Grid 和嵌套滚动',
        builder: (_) => const ScrollCoveragePage(),
      ),
      _CoverageEntry(
        icon: Icons.auto_awesome_outlined,
        title: 'Paint & Effects',
        subtitle: 'Decoration、Clip、Transform、Filter 和 CustomPaint',
        builder: (_) => const PaintCoveragePage(),
      ),
      _CoverageEntry(
        icon: Icons.touch_app_outlined,
        title: 'Interaction & Semantics',
        subtitle: '手势包装、Focus、Semantics、表单、Dialog 和 BottomSheet',
        builder: (_) => const InteractionCoveragePage(),
      ),
      _CoverageEntry(
        icon: Icons.route_outlined,
        title: 'Route & Transition',
        subtitle: '前后 Route、AppBar、Hero、SlideTransition 和 Stack',
        builder: (_) => const RouteCoveragePage(),
      ),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text('Widget Coverage')),
      body: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: entries.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          if (index == 0) {
            return const _CoverageIntroduction();
          }
          final entry = entries[index - 1];
          return Card(
            child: ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 10,
              ),
              leading: CircleAvatar(child: Icon(entry.icon)),
              title: Text(
                entry.title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(entry.subtitle),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute<void>(builder: entry.builder));
              },
            ),
          );
        },
      ),
    );
  }
}

class _CoverageIntroduction extends StatelessWidget {
  const _CoverageIntroduction();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: const Padding(
        padding: EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.science_outlined, size: 32),
            SizedBox(height: 12),
            Text(
              'Inspector 场景目录',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
            ),
            SizedBox(height: 6),
            Text('每个页面只覆盖一类结构，便于在 PickView 中判断节点分类、frame 和截图是否正确。'),
          ],
        ),
      ),
    );
  }
}

class _CoverageEntry {
  const _CoverageEntry({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;
}
