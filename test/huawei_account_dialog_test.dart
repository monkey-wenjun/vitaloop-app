import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/screens/huawei_account_dialog.dart';

void main() {
  testWidgets('Huawei account dialog validates empty and spaced values', (
    tester,
  ) async {
    String? result;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showHuaweiAccountDialog(
                    context,
                    name: 'HUAWEI WATCH',
                    address: 'AA:BB:CC:DD:EE:FF',
                    initialAccount: '',
                  );
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

    await tester.tap(find.text('连接'));
    await tester.pump();
    expect(find.text('请输入手表绑定的华为账号'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(find.byType(TextField), 'bad account');
    await tester.tap(find.text('连接'));
    await tester.pump();
    expect(find.text('华为账号不能包含空格'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(find.byType(TextField), 'hi@example.com');
    await tester.tap(find.text('连接'));
    await tester.pumpAndSettle();
    expect(result, 'hi@example.com');
    expect(find.byType(AlertDialog), findsNothing);
  });
}
