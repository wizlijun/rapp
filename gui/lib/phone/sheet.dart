/// The bottom sheet of the phone shell: 设备, 设置 (V1b Task 7). No project section (P5).
library;

import 'package:flutter/material.dart';

import '../ui/tokens.dart';
import 'phone_nav.dart';
import 'widgets.dart';

Future<void> showPhoneSheet(BuildContext context, PhoneNav nav) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: RappTokens.of(context).float.first,
    elevation: 0,
    builder: (sheet) {
      final t = RappTokens.of(sheet);
      final style = Theme.of(sheet).textTheme.bodyMedium;
      Widget row(String label, PhoneView v) => InkWell(
            onTap: () {
              Navigator.of(sheet).pop();
              nav.open(v);
            },
            child: Container(
              constraints: const BoxConstraints(minHeight: phoneTap),
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(label, style: style?.copyWith(color: t.text)),
            ),
          );
      return SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: phoneMaxWidth),
            child: DecoratedBox(
              decoration: t.floatBox().copyWith(
                  border: Border(top: BorderSide(color: t.line)), borderRadius: BorderRadius.zero),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [row('设备', PhoneView.devices), row('设置', PhoneView.settings)],
              ),
            ),
          ),
        ),
      );
    },
  );
}
