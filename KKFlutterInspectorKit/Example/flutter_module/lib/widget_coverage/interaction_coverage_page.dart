import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'coverage_section.dart';

class InteractionCoveragePage extends StatefulWidget {
  const InteractionCoveragePage({super.key});

  @override
  State<InteractionCoveragePage> createState() =>
      _InteractionCoveragePageState();
}

class _InteractionCoveragePageState extends State<InteractionCoveragePage> {
  var _tapCount = 0;
  var _checked = true;
  var _enabled = true;
  var _sliderValue = 0.45;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Interaction & Semantics')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          CoverageSection(
            title: 'Wrapper chain',
            description:
                'Semantics → Focus → MouseRegion → Listener → GestureDetector → TapRegion。',
            child: _buildWrapperChain(context),
          ),
          const SizedBox(height: 12),
          CoverageSection(
            title: 'Actions and shortcuts',
            description: 'Shortcuts、Actions 与 FocusableActionDetector。',
            child: _buildActionChain(context),
          ),
          const SizedBox(height: 12),
          CoverageSection(
            title: 'Pointer gates',
            description: 'IgnorePointer 与 AbsorbPointer 保留子节点布局。',
            child: Row(
              children: [
                Expanded(
                  child: IgnorePointer(
                    ignoring: false,
                    child: OutlinedButton(
                      onPressed: () {},
                      child: const Text('Ignore false'),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: AbsorbPointer(
                    absorbing: false,
                    child: FilledButton.tonal(
                      onPressed: () {},
                      child: const Text('Absorb false'),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          CoverageSection(
            title: 'Material controls',
            description: 'EditableText、Checkbox、Switch 与 Slider 的复合结构。',
            child: Column(
              children: [
                const TextField(
                  decoration: InputDecoration(
                    labelText: 'Editable text',
                    prefixIcon: Icon(Icons.edit_outlined),
                    border: OutlineInputBorder(),
                  ),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('CheckboxListTile'),
                  value: _checked,
                  onChanged: (value) {
                    setState(() => _checked = value ?? false);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('SwitchListTile'),
                  value: _enabled,
                  onChanged: (value) {
                    setState(() => _enabled = value);
                  },
                ),
                Slider(
                  value: _sliderValue,
                  label: _sliderValue.toStringAsFixed(2),
                  onChanged: (value) {
                    setState(() => _sliderValue = value);
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          CoverageSection(
            title: 'Overlay routes',
            description: '打开后可检查 Overlay、ModalBarrier、Dialog 与 BottomSheet。',
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: () => _showDialog(context),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Dialog'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _showBottomSheet(context),
                    icon: const Icon(Icons.vertical_align_top),
                    label: const Text('Sheet'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWrapperChain(BuildContext context) {
    return MergeSemantics(
      child: Semantics(
        button: true,
        label: 'Inspector tappable wrapper',
        child: Focus(
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Listener(
              onPointerDown: (_) {},
              child: GestureDetector(
                onTap: () => setState(() => _tapCount++),
                child: TapRegion(
                  onTapInside: (_) {},
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    height: 92,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Text(
                      'Tap count: $_tapCount',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionChain(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              setState(() => _tapCount++);
              return null;
            },
          ),
        },
        child: FocusableActionDetector(
          child: Container(
            height: 72,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.primary),
              borderRadius: BorderRadius.circular(14),
            ),
            child: const Text('Press Enter with hardware keyboard'),
          ),
        ),
      ),
    );
  }

  Future<void> _showDialog(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Inspector Dialog'),
          content: const Text('检查 Overlay、ModalBarrier、Card 和 Text 的层级。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showBottomSheet(BuildContext context) {
    return showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Modal Bottom Sheet',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text('这个 Route 会与下面的页面同时保留在 Element Tree 中。'),
              ],
            ),
          ),
        );
      },
    );
  }
}
