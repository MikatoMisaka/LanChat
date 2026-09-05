import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanchat/services/sticker_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('copies a custom sticker into the app sticker directory', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('lanchat-stickers');
    final source = await File('${root.path}/../unsafe name.png')
        .writeAsBytes([1, 2, 3]);
    final service = StickerService(supportDirectory: () async => root);

    final sticker = await service.addCustomSticker(source.path);

    expect(File(sticker.path).existsSync(), isTrue);
    expect(sticker.path, isNot(source.path));
    expect(await service.customStickers(), contains(sticker));
    await root.delete(recursive: true);
  });

  test('persists recent stickers and favorites', () async {
    SharedPreferences.setMockInitialValues({});
    final root = await Directory.systemTemp.createTemp('lanchat-stickers');
    final path = '${root.path}/pig.gif';
    await File(path).writeAsBytes([1]);
    final service = StickerService(supportDirectory: () async => root);
    final sticker = LocalSticker(
      id: 'pig-1',
      path: path,
      name: 'pig.gif',
      isGif: true,
    );

    await service.markRecent(sticker);
    await service.setFavorite(sticker, true);

    final reloaded = StickerService(supportDirectory: () async => root);
    expect((await reloaded.recentStickers()).single.id, 'pig-1');
    expect((await reloaded.favoriteStickers()).single.id, 'pig-1');
    await root.delete(recursive: true);
  });
}
