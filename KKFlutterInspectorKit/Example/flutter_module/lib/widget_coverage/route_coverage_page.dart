import 'package:flutter/material.dart';

import 'coverage_section.dart';

class RouteCoveragePage extends StatelessWidget {
  const RouteCoveragePage({super.key});

  static const _heroTag = 'inspector-route-card';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Route Source'),
        actions: [
          IconButton(
            onPressed: () => _pushDetail(context),
            icon: const Icon(Icons.arrow_forward),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'The first text on previous route',
            style: Theme.of(
              context,
            ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          const Text(
            'Push 到详情页后，当前页面会作为 Offstage Route 保留，用于检查前一个页面的 frame 和截图。',
          ),
          const SizedBox(height: 18),
          Hero(
            tag: _heroTag,
            child: Material(
              color: Colors.transparent,
              child: Container(
                height: 138,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF405DE6), Color(0xFF8C7CF0)],
                  ),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.route, color: Colors.white),
                    SizedBox(height: 10),
                    Text(
                      'Hero subtree',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Background and children move together.',
                      style: TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const CoverageSection(
            title: 'Static SlideTransition',
            description: '使用固定 Animation，便于稳定检查 transition 的 frame。',
            child: _StaticSlideExample(),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () => _pushDetail(context),
            icon: const Icon(Icons.open_in_new),
            label: const Text('Push detail with slide + fade'),
          ),
        ],
      ),
    );
  }

  void _pushDetail(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder<void>(
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 320),
        pageBuilder: (_, _, _) => const _RouteCoverageDetailPage(),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          final position =
              Tween<Offset>(
                begin: const Offset(1, 0),
                end: Offset.zero,
              ).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              );
          return SlideTransition(
            position: position,
            child: FadeTransition(opacity: animation, child: child),
          );
        },
      ),
    );
  }
}

class _StaticSlideExample extends StatelessWidget {
  const _StaticSlideExample();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 96,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(14),
              ),
            ),
          ),
          SlideTransition(
            position: const AlwaysStoppedAnimation<Offset>(Offset(0.12, 0)),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(
                width: 168,
                height: 62,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Text('Offset(0.12, 0)'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteCoverageDetailPage extends StatelessWidget {
  const _RouteCoverageDetailPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Route Detail AppBar'),
        actions: [
          IconButton(
            onPressed: () {},
            tooltip: 'Inspect action',
            icon: const Icon(Icons.bug_report_outlined),
          ),
        ],
      ),
      body: Stack(
        children: [
          const Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFFF2F0FF), Color(0xFFFFFFFF)],
                ),
              ),
            ),
          ),
          ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Text(
                'Flutter Detail Page',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '检查 AppBar title、Route transition、Hero 与前一个 Offstage 页面。',
              ),
              const SizedBox(height: 24),
              Hero(
                tag: RouteCoveragePage._heroTag,
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    height: 188,
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.layers, color: Colors.white, size: 44),
                        SizedBox(height: 14),
                        Text(
                          'Expanded Hero',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          'A complete painted subtree',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              OutlinedButton.icon(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.arrow_back),
                label: const Text('Pop route'),
              ),
            ],
          ),
          Positioned(
            right: 14,
            bottom: 18,
            child: FloatingActionButton.small(
              onPressed: () {},
              child: const Icon(Icons.my_location),
            ),
          ),
        ],
      ),
    );
  }
}
