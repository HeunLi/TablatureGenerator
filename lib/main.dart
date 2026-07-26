import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'screens/editor_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  runApp(const BassTabStudioApp());
}

class BassTabStudioApp extends StatelessWidget {
  const BassTabStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bass Tab Studio',
      theme: ThemeData.dark(useMaterial3: true),
      home: const EditorScreen(),
    );
  }
}
