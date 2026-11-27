// 按键 settings (quick-row spec §6.4): the 按键动作 and the key layout. A placeholder for now, so 「按键▾」's 设置… has
// somewhere to go; the editor comes later.
import 'package:flutter/material.dart';

import '../ui/main_state.dart';
import '../ui/tokens.dart';

Future<void> openKeysPage(BuildContext context, MainState state) => Navigator.of(context)
    .push(MaterialPageRoute<void>(builder: (_) => KeysPage(state: state)));

class KeysPage extends StatelessWidget {
  const KeysPage({super.key, required this.state});
  final MainState state;

  @override
  Widget build(BuildContext context) {
    final t = RappTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: AppBar(backgroundColor: t.bg, foregroundColor: t.text, title: Text('按键', style: TextStyle(color: t.text))),
      body: const SizedBox.shrink(),
    );
  }
}
