import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'coverage_section.dart';

class PaintCoveragePage extends StatelessWidget {
  const PaintCoveragePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Paint & Effects')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          CoverageSection(
            title: 'Decoration',
            description: '渐变、圆角、边框和阴影组成的 BoxDecoration。',
            child: _DecorationExample(),
          ),
          SizedBox(height: 12),
          CoverageSection(
            title: 'Clip and physical model',
            description: 'ClipRRect、ClipOval 与 PhysicalModel 的绘制边界。',
            child: _ClipExample(),
          ),
          SizedBox(height: 12),
          CoverageSection(
            title: 'Transform and opacity',
            description: 'Transform、FractionalTranslation、Opacity 的合成层。',
            child: _TransformExample(),
          ),
          SizedBox(height: 12),
          CoverageSection(
            title: 'Filters',
            description:
                'BackdropFilter、ImageFilter、ColorFiltered 和 ShaderMask。',
            child: _FilterExample(),
          ),
          SizedBox(height: 12),
          CoverageSection(
            title: 'Custom paint',
            description: 'RenderCustomPaint 自己绘制背景，子节点继续参与布局。',
            child: _CustomPaintExample(),
          ),
        ],
      ),
    );
  }
}

class _DecorationExample extends StatelessWidget {
  const _DecorationExample();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 120,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Theme.of(context).colorScheme.primary,
            Theme.of(context).colorScheme.tertiary,
          ],
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: Colors.white70, width: 2),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 14,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: const Row(
        children: [
          Icon(Icons.gradient, color: Colors.white, size: 38),
          SizedBox(width: 14),
          Expanded(
            child: Text(
              'Decorated Container',
              style: TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ClipExample extends StatelessWidget {
  const _ClipExample();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        ClipOval(
          child: ColoredBox(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: const SizedBox.square(
              dimension: 76,
              child: Icon(Icons.crop_square, size: 34),
            ),
          ),
        ),
        PhysicalModel(
          color: Theme.of(context).colorScheme.secondaryContainer,
          elevation: 8,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: const SizedBox(
            width: 112,
            height: 76,
            child: Center(child: Text('Physical')),
          ),
        ),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: const ColoredBox(
            color: Color(0xFFFFD7C2),
            child: SizedBox.square(
              dimension: 76,
              child: Icon(Icons.rounded_corner),
            ),
          ),
        ),
      ],
    );
  }
}

class _TransformExample extends StatelessWidget {
  const _TransformExample();

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 132,
      child: Stack(
        children: [
          Positioned(
            left: 12,
            top: 22,
            child: Transform.rotate(
              angle: -0.12,
              child: Container(
                width: 132,
                height: 82,
                alignment: Alignment.center,
                color: Theme.of(context).colorScheme.primaryContainer,
                child: const Text('Transform'),
              ),
            ),
          ),
          Positioned(
            right: 8,
            top: 20,
            child: FractionalTranslation(
              translation: const Offset(-0.08, 0.16),
              child: Opacity(
                opacity: 0.62,
                child: Container(
                  width: 132,
                  height: 82,
                  alignment: Alignment.center,
                  color: Theme.of(context).colorScheme.tertiary,
                  child: const Text(
                    'Opacity',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterExample extends StatelessWidget {
  const _FilterExample();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: SizedBox(
            height: 126,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Color(0xFFFF8A65), Color(0xFF5C6BC0)],
                    ),
                  ),
                ),
                const Align(
                  alignment: Alignment(-0.65, -0.35),
                  child: Icon(Icons.blur_on, size: 72, color: Colors.white54),
                ),
                Positioned(
                  left: 72,
                  right: 18,
                  top: 24,
                  bottom: 24,
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.22),
                        border: Border.all(color: Colors.white54),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text(
                        'BackdropFilter',
                        style: TextStyle(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Colors.indigo,
                  BlendMode.modulate,
                ),
                child: const FlutterLogo(size: 58),
              ),
            ),
            Expanded(
              child: ShaderMask(
                blendMode: BlendMode.srcIn,
                shaderCallback: (bounds) {
                  return const LinearGradient(
                    colors: [Colors.pink, Colors.deepPurple],
                  ).createShader(bounds);
                },
                child: const Text(
                  'Shader',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            Expanded(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(sigmaX: 0.8, sigmaY: 0.8),
                child: const Icon(Icons.filter_vintage, size: 52),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _CustomPaintExample extends StatelessWidget {
  const _CustomPaintExample();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _InspectorChartPainter(),
      child: const SizedBox(
        height: 126,
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'CustomPaint chart',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ),
      ),
    );
  }
}

class _InspectorChartPainter extends CustomPainter {
  const _InspectorChartPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()..color = const Color(0xFFE9E7FF);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(16)),
      background,
    );

    final line = Paint()
      ..color = const Color(0xFF6558D3)
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final path = Path()
      ..moveTo(18, size.height - 24)
      ..lineTo(size.width * 0.28, size.height * 0.55)
      ..lineTo(size.width * 0.48, size.height * 0.7)
      ..lineTo(size.width * 0.7, size.height * 0.32)
      ..lineTo(size.width - 18, size.height * 0.42);
    canvas.drawPath(path, line);
  }

  @override
  bool shouldRepaint(covariant _InspectorChartPainter oldDelegate) => false;
}
