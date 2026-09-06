import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/server_profile.dart';
import 'package:lanchat/widgets/server_profile_editor.dart';

void main() {
  testWidgets('shows password rules and validates before closing', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ServerProfileEditor())),
    );

    expect(find.text('8-128 位，可使用任意字符。'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('保存服务器'),
      200,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.text('保存服务器'));
    await tester.pump();

    expect(find.text('请输入有效的 http 或 https 服务器地址。'), findsOneWidget);
    expect(find.text('用户名需要 3-32 位小写字母、数字、下划线或短横线。'), findsOneWidget);
    expect(find.text('申请加入时需要填写邀请码。'), findsOneWidget);
  });

  testWidgets(
    'keeps the editor inside the visible area when the keyboard opens',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const ServerProfileEditor(),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      final scrollView = tester.renderObject<RenderBox>(
        find.byType(SingleChildScrollView),
      );
      expect(scrollView.size.height, lessThanOrEqualTo(340));
    },
  );

  testWidgets('uses join mode when an existing profile has an invite code', (
    tester,
  ) async {
    final profile = ServerProfile(
      id: 'home',
      name: '家庭服务器',
      baseUrl: 'https://home.example.com',
      username: 'alice',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ServerProfileEditor(
            profile: profile,
            password: 'user-password',
            inviteCode: 'invite-code',
          ),
        ),
      ),
    );

    expect(find.text('邀请码（必填）'), findsOneWidget);
  });
}
