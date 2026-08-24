import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:tingshuxiong/platform/platform.dart';

void main() {
  late Directory tempDir;
  final sep = Platform.pathSeparator;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('audio_store_test');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('AudioStore', () {
    test('写入音频文件并返回路径（audio 子目录）', () async {
      final store = AudioStore(rootProvider: () async => tempDir);
      final bytes = Uint8List.fromList(utf8.encode('mp3-data'));

      final path = await store.saveAudio('novel.txt', 3, bytes);

      expect(
        path,
        endsWith(
          '${tempDir.path}$sep${p.join('novel.txt', 'audio', '3.mp3')}',
        ),
      );
      final file = File(path);
      expect(await file.exists(), isTrue);
      expect(await file.readAsBytes(), bytes);
    });

    test('saveRewrite 写入改写稿中间文件并返回路径', () async {
      final store = AudioStore(rootProvider: () async => tempDir);

      final path = await store.saveRewrite('novel.txt', 0, '改写稿内容');

      expect(path, endsWith('${tempDir.path}$sep${p.join('novel.txt', 'rewrite', '0.txt')}'));
      expect(await File(path).readAsString(), '改写稿内容');
    });

    test('bookId 非法字符被替换', () async {
      final store = AudioStore(rootProvider: () async => tempDir);
      final path = await store.saveAudio('a/b:c*?<>|"', 0, Uint8List(0));
      expect(path.contains('/'), isFalse);
      expect(path, contains('a_b_c_____'));
    });

    test('多章节写入互不覆盖', () async {
      final store = AudioStore(rootProvider: () async => tempDir);
      await store.saveAudio('book', 0, Uint8List.fromList([1]));
      await store.saveAudio('book', 1, Uint8List.fromList([2]));
      expect(await File('${tempDir.path}$sep${p.join('book', 'audio', '0.mp3')}').exists(), isTrue);
      expect(await File('${tempDir.path}$sep${p.join('book', 'audio', '1.mp3')}').exists(), isTrue);
    });

    test('setRoot 切换输出根目录，null 恢复默认', () async {
      final store = AudioStore(rootProvider: () async => tempDir);
      final custom = Directory('${tempDir.path}${sep}custom');
      store.setRoot(custom.path);

      final path = await store.saveAudio('book', 0, Uint8List(0));

      expect(path, startsWith(custom.path));
      expect(File(path).existsSync(), isTrue);

      store.setRoot(null);
      final defaultPath = await store.saveAudio('book', 1, Uint8List(0));
      expect(defaultPath, startsWith(tempDir.path));
    });

    test('moveToHistory 把旧文件转移到历史目录并带时间戳', () async {
      final store = AudioStore(rootProvider: () async => tempDir);
      final audio = await store.saveAudio('book', 2, Uint8List.fromList([1]));
      final rewrite = await store.saveRewrite('book', 2, '旧改写稿');

      final moved = await store.moveToHistory(
        'book',
        2,
        audioPath: audio,
        rewritePath: rewrite,
      );

      expect(File(audio).existsSync(), isFalse);
      expect(File(rewrite).existsSync(), isFalse);
      expect(moved.audioPath, isNotNull);
      expect(moved.rewritePath, isNotNull);
      // 历史目录：<root>/book/history/2-<时间戳>.mp3
      expect(
        moved.audioPath,
        matches(RegExp(r'history[\\/]2-\d{14}\.mp3$')),
      );
      expect(
        moved.rewritePath,
        matches(RegExp(r'history[\\/]2-\d{14}\.txt$')),
      );
      expect(await File(moved.audioPath!).readAsBytes(), [1]);
      expect(await File(moved.rewritePath!).readAsString(), '旧改写稿');
    });

    test('moveToHistory 源文件不存在时对应历史路径为 null', () async {
      final store = AudioStore(rootProvider: () async => tempDir);

      final moved = await store.moveToHistory(
        'book',
        0,
        audioPath: '${tempDir.path}${sep}not-exist.mp3',
      );

      expect(moved.audioPath, isNull);
      expect(moved.rewritePath, isNull);
    });
  });
}
