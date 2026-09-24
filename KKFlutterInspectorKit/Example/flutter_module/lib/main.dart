import 'package:flutter/material.dart';

import 'widget_coverage/widget_coverage_gallery.dart';

void main() => runApp(const InspectorExampleApp());

class InspectorExampleApp extends StatelessWidget {
  const InspectorExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flutter Inspector Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6558D3)),
        scaffoldBackgroundColor: const Color(0xFFF5F5FA),
        useMaterial3: true,
      ),
      home: const WidgetCoverageGalleryPage(),
    );
  }
}
