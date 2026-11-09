import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/ui/scroll_capture.dart';

void main() {
  testWidgets('finds the Scrollable inside a ListView', (tester) async {
    final listKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: ListView(
          key: listKey,
          children: [
            for (var i = 0; i < 20; i++)
              SizedBox(height: 120, child: Text('item $i')),
          ],
        ),
      ),
    );

    final position = findDescendantScrollPosition(listKey.currentContext!);
    expect(position, isNotNull);
    expect(position!.maxScrollExtent, greaterThan(0));
  });
}
