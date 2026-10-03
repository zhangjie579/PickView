import 'package:flutter/material.dart';

/// Coverage case for the box based scrollable: a SingleChildScrollView moves its
/// content at paint time instead of giving it a parentData offset, so the
/// hierarchy has to apply the viewport's scroll offset to the content subtree.
/// Scroll both lists and refresh the hierarchy: every row has to stay where the
/// app draws it, not at the unscrolled content position.
class SingleChildScrollCoveragePage extends StatelessWidget {
  const SingleChildScrollCoveragePage({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('SingleChildScrollView'),
          bottom: const TabBar(
            tabs: <Widget>[
              Tab(text: 'Vertical'),
              Tab(text: 'Horizontal'),
            ],
          ),
        ),
        body: TabBarView(
          children: <Widget>[
            SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (int index = 0; index < 24; index++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Container(
                        height: 72,
                        alignment: Alignment.centerLeft,
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        decoration: BoxDecoration(
                          color: index.isEven
                              ? scheme.primaryContainer
                              : scheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          'Vertical item ${index + 1}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.all(16),
              child: Row(
                children: <Widget>[
                  for (int index = 0; index < 16; index++)
                    Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: Container(
                        width: 132,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: index.isEven
                              ? scheme.tertiaryContainer
                              : scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          'Card ${index + 1}',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
