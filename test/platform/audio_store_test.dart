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

    test('deleteChapterFiles 删除章节旧生成文件（存在则删）', () async {
      final store = AudioStore(rootProvider: () async => tempDir);
      final audio = await store.saveAudio('book', 2, Uint8List.fromList([1]));
      final rewrite = await store.saveRewrite('book', 2, '旧改写稿');
      expect(File(audio).existsSync(), isTrue);
      expect(File(rewrite).existsSync(), isTrue);

      await store.deleteChapterFiles(audioPath: audio, rewritePath: rewrite);

      expect(File(audio).existsSync(), isFalse);
      expect(File(rewrite).existsSync(), isFalse);
      // 旧版不保留：不创建 history 目录。
      expect(
        Directory('${tempDir.path}$sep${p.join('book', 'history')}').existsSync(),
        isFalse,
      );
    });

    test('deleteBookFiles 删除整本书生成目录，目录不存在时静默', () async {
      final store = AudioStore(rootProvider: () async => tempDir);
      await store.saveAudio('book', 0, Uint8List.fromList([1]));
      await store.saveRewrite('book', 0, '改写稿');
      final bookDir = Directory('${tempDir.path}$sep${p.join('book')}');
      expect(await bookDir.exists(), isTrue);

      await store.deleteBookFiles('book');

      expect(await bookDir.exists(), isFalse);
      // 目录不存在时静默跳过，不抛错。
      await store.deleteBookFiles('book');
    });

    test('deleteChapterFiles 源文件不存在时静默跳过', () async {
      final store = AudioStore(rootProvider: () async => tempDir);

      await store.deleteChapterFiles(
        audioPath: '${tempDir.path}${sep}not-exist.mp3',
        rewritePath: '${tempDir.path}${sep}not-exist.txt',
      );

      expect(File('${tempDir.path}${sep}not-exist.mp3').existsSync(), isFalse);
      expect(File('${tempDir.path}${sep}not-exist.txt').existsSync(), isFalse);
    });
  });
}
