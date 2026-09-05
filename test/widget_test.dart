import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/widgets/chat_theme.dart';
import 'package:lanchat/widgets/media_preview.dart';

void main() {
  testWidgets('LanChat theme uses jade actions on a warm white surface', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: LanChatTheme.light(),
        home: Scaffold(
          body: FilledButton(onPressed: () {}, child: const Text('发送')),
        ),
      ),
    );

    final theme = Theme.of(tester.element(find.byType(FilledButton)));

    expect(theme.colorScheme.primary, LanChatTheme.jade);
    expect(theme.scaffoldBackgroundColor, LanChatTheme.warmWhite);
  });

  testWidgets('media preview exposes a save action', (tester) async {
    var saveCount = 0;
    var shareCount = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: MediaPreviewPage(
          path: 'missing-preview.png',
          title: 'preview.png',
          onSave: () async => saveCount++,
          onShare: () async => shareCount++,
        ),
      ),
    );
    await tester.tap(find.byTooltip('保存图片'));
    await tester.pump();

    expect(saveCount, 1);
    expect(shareCount, 0);
  });
}
