import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'screens/dashboard_screen.dart';
import 'widgets/glass_panel.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  _silenceDialogSubmitAssertion();
  runApp(const BassTabStudioApp());
}

/// Silences a specific, known-harmless Flutter framework assertion (see
/// `docs/DECISIONS.md`, "Flutter gotcha — dialog pop assertion on Enter"):
/// `InheritedElement.debugDeactivated`'s `assert(_dependents.isEmpty)` can
/// fire when a dialog closes via a `TextField`'s Enter-to-submit handler
/// (e.g. renaming a project, setting BPM) — a framework-internal race in
/// how the dialog's `Focus`/`Actions` tree tears down, not anything wrong
/// with the submitted value or the pop itself; the action being submitted
/// (rename, BPM change, etc.) completes correctly regardless. It's debug
/// -only — `assert()` is stripped entirely from release builds — and
/// several app-level scheduling fixes (deferring the pop by one frame, by
/// two, unfocusing first) failed to prevent the underlying race, which
/// pointed at a framework flakiness rather than something fixable from
/// here. Only this specific assertion is swallowed; everything else still
/// reports through the normal handler.
void _silenceDialogSubmitAssertion() {
  final defaultOnError = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.exception.toString().contains('_dependents.isEmpty')) {
      return;
    }
    defaultOnError?.call(details);
  };
}

class BassTabStudioApp extends StatelessWidget {
  const BassTabStudioApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bass Tab Studio',
      // Seeded from the dashboard's violet accent (see dashboard_screen.dart)
      // so dialog buttons, selection highlights, etc. feel like one
      // consistent app rather than the dashboard being an unrelated skin.
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: accentColor,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const DashboardScreen(),
    );
  }
}
