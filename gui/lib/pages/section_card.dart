import 'package:flutter/material.dart';

/// A titled card used for each of the three main sections.
class SectionCard extends StatelessWidget {
  const SectionCard({super.key, required this.title, required this.children, this.action});
  final String title;
  final List<Widget> children;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
              ?action,
            ]),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}
