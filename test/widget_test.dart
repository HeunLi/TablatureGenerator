import 'package:flutter_test/flutter_test.dart';

import 'package:bass_tab_studio/main.dart';

void main() {
  testWidgets('Editor screen renders with app bar', (WidgetTester tester) async {
    await tester.pumpWidget(const BassTabStudioApp());

    expect(find.textContaining('Bass Tab Studio'), findsOneWidget);
  });
}
