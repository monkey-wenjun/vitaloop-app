import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vitaloop/src/rust/api/types.dart';
import 'package:vitaloop/state/app_state.dart';
import 'package:vitaloop/theme/tokens.dart';
import 'package:vitaloop/ui/screens/auth_screen.dart';

void main() {
  testWidgets('已登录进入个人中心，不再显示登录表单', (tester) async {
    final state = AppState()
      ..signedIn = true
      ..accountEmail = 'hi@example.com'
      ..cloudServer = 'https://cloud.example.com'
      ..profile = const Profile(
        nickname: '测试跑者',
        gender: 'male',
        heightCm: 175,
        weightKg: 68,
        birthDate: '1995-01-01',
        email: 'hi@example.com',
      );

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: AccountCenterScreen(state: state),
      ),
    );

    expect(find.text('个人中心'), findsOneWidget);
    expect(find.text('测试跑者'), findsOneWidget);
    expect(find.text('hi@example.com'), findsWidgets);
    expect(find.text('https://cloud.example.com'), findsOneWidget);
    expect(find.text('欢迎回来'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
