import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
