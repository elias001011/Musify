import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:musify/widgets/no_artwork_cube.dart';

void main() {
  testWidgets('centers the placeholder music note optically', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: NullArtworkWidget(size: 100, iconSize: 25)),
    );

    final transform = tester.widget<Transform>(find.byType(Transform));
    expect(transform.transform.getTranslation().x, -1);
    expect(transform.transform.getTranslation().y, -1);
  });
}
