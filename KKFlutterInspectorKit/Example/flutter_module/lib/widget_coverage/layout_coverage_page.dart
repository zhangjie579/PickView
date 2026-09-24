import 'package:flutter/material.dart';

import 'coverage_section.dart';

class LayoutCoveragePage extends StatelessWidget {
  const LayoutCoveragePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Layout & Constraints')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          CoverageSection(
            title: 'Flex family',
            description: 'Row、Expanded、Flexible、Spacer 与交叉轴对齐。',
            child: _FlexExample(),
          ),
          SizedBox(height: 12),
          CoverageSection(
            title: 'Wrap and Flow',
            description: '普通换行布局与由 FlowDelegate 决定位置的绘制布局。',
            child: _WrapAndFlowExample(),
          ),
          SizedBox(height: 12),
          CoverageSection(
            title: 'Stack positioning',
            description: 'Stack、Positioned、Align、FractionallySizedBox。',
            child: _StackExample(),
          ),
          SizedBox(height: 12),
          CoverageSection(
            title: 'Constraint chain',
            description:
                'ConstrainedBox、AspectRatio、FittedBox 和 IntrinsicHeight。',
            child: _ConstraintExample(),
          ),
          SizedBox(height: 12),
          CoverageSection(
            title: 'Table layout',
            description: 'Table 的行列尺寸以及 Baseline 对齐。',
            child: _TableExample(),
          ),
          SizedBox(height: 12),
          CoverageSection(
            title: 'Custom multi-child layout',
            description: 'LayoutId 与 MultiChildLayoutDelegate 的自定义定位。',
            child: _CustomLayoutExample(),
          ),
        ],
      ),
    );
  }
}

class _FlexExample extends StatelessWidget {
  const _FlexExample();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            flex: 2,
            child: ColoredBox(
              color: Theme.of(context).colorScheme.primaryContainer,
              child: const Center(child: Text('Expanded 2')),
            ),
          ),
          const SizedBox(width: 8),
          const Spacer(),
          const SizedBox(width: 8),
          Flexible(
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: const FittedBox(child: Text('Flexible')),
            ),
          ),
        ],
      ),
    );
  }
}

class _WrapAndFlowExample extends StatelessWidget {
  const _WrapAndFlowExample();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text('Wrap A')),
            Chip(label: Text('Wrap B')),
            Chip(label: Text('Long Wrap C')),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 76,
          child: Flow(
            delegate: const _ChipFlowDelegate(gap: 8),
            children: const [
              Chip(label: Text('Flow 1')),
              Chip(label: Text('Flow 2')),
              Chip(label: Text('Flow 3')),
              Chip(label: Text('Flow 4')),
            ],
          ),
        ),
      ],
    );
  }
}

class _StackExample extends StatelessWidget {
  const _StackExample();

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 2.2,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            const Positioned(
              left: 16,
              top: 18,
              child: CircleAvatar(radius: 28, child: Icon(Icons.layers)),
            ),
            const PositionedDirectional(
              end: 16,
              bottom: 16,
              child: Chip(label: Text('Positioned')),
            ),
            Align(
              alignment: Alignment.topCenter,
              child: FractionallySizedBox(
                widthFactor: 0.42,
                child: Container(
                  height: 8,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConstraintExample extends StatelessWidget {
  const _ConstraintExample();

  @override
  Widget build(BuildContext context) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 96),
              child: ColoredBox(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: const Center(child: Text('minHeight')),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: AspectRatio(
              aspectRatio: 1,
              child: Container(
                padding: const EdgeInsets.all(12),
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: const FittedBox(child: FlutterLogo()),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TableExample extends StatelessWidget {
  const _TableExample();

  @override
  Widget build(BuildContext context) {
    return Table(
      border: TableBorder.all(color: Theme.of(context).dividerColor),
      columnWidths: const {0: FixedColumnWidth(72), 1: FlexColumnWidth()},
      children: const [
        TableRow(
          children: [
            Padding(padding: EdgeInsets.all(8), child: Text('Widget')),
            Padding(padding: EdgeInsets.all(8), child: Text('RenderObject')),
          ],
        ),
        TableRow(
          children: [
            Padding(
              padding: EdgeInsets.all(8),
              child: Baseline(
                baseline: 18,
                baselineType: TextBaseline.alphabetic,
                child: Text('Text'),
              ),
            ),
            Padding(padding: EdgeInsets.all(8), child: Text('RenderParagraph')),
          ],
        ),
      ],
    );
  }
}

class _CustomLayoutExample extends StatelessWidget {
  const _CustomLayoutExample();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 104,
      child: CustomMultiChildLayout(
        delegate: _InspectorCardLayoutDelegate(),
        children: [
          LayoutId(
            id: _InspectorCardSlot.icon,
            child: const CircleAvatar(radius: 26, child: Icon(Icons.widgets)),
          ),
          LayoutId(
            id: _InspectorCardSlot.title,
            child: Text(
              'Custom layout',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          LayoutId(
            id: _InspectorCardSlot.subtitle,
            child: const Text('Three children positioned by a delegate.'),
          ),
        ],
      ),
    );
  }
}

class _ChipFlowDelegate extends FlowDelegate {
  const _ChipFlowDelegate({required this.gap});

  final double gap;

  @override
  void paintChildren(FlowPaintingContext context) {
    var x = 0.0;
    var y = 0.0;
    for (var index = 0; index < context.childCount; index++) {
      final childSize = context.getChildSize(index) ?? Size.zero;
      if (x + childSize.width > context.size.width && x > 0) {
        x = 0;
        y += childSize.height + gap;
      }
      context.paintChild(index, transform: Matrix4.translationValues(x, y, 0));
      x += childSize.width + gap;
    }
  }

  @override
  bool shouldRepaint(covariant _ChipFlowDelegate oldDelegate) {
    return oldDelegate.gap != gap;
  }
}

enum _InspectorCardSlot { icon, title, subtitle }

class _InspectorCardLayoutDelegate extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    const iconSize = Size.square(52);
    if (hasChild(_InspectorCardSlot.icon)) {
      layoutChild(
        _InspectorCardSlot.icon,
        const BoxConstraints.tightFor(width: 52, height: 52),
      );
      positionChild(_InspectorCardSlot.icon, const Offset(0, 16));
    }

    final contentWidth = (size.width - iconSize.width - 12).clamp(
      0.0,
      double.infinity,
    );
    if (hasChild(_InspectorCardSlot.title)) {
      layoutChild(
        _InspectorCardSlot.title,
        BoxConstraints(maxWidth: contentWidth),
      );
      positionChild(_InspectorCardSlot.title, const Offset(64, 18));
    }
    if (hasChild(_InspectorCardSlot.subtitle)) {
      layoutChild(
        _InspectorCardSlot.subtitle,
        BoxConstraints(maxWidth: contentWidth),
      );
      positionChild(_InspectorCardSlot.subtitle, const Offset(64, 50));
    }
  }

  @override
  bool shouldRelayout(covariant _InspectorCardLayoutDelegate oldDelegate) {
    return false;
  }
}
