import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/screens/watch_auth_key_dialog.dart';

void main() {
  testWidgets('watch auth key dialog validates hex length', (tester) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showWatchAuthKeyDialog(context);
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('请输入手表的认证 key'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(find.byType(TextField), 'zz${'0' * 62}');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('认证 key 只能是十六进制字符'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'ab12');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(find.text('认证 key 应为 64 个十六进制字符（32 字节）'), findsOneWidget);

    await tester.enterText(find.byType(TextField), ' ${'AB' * 32} ');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result, ('ab' * 32));
  });
}
