import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/core/text/chapter_splitter.dart';

void main() {
  final splitter = ChapterSplitter();

  group('ChapterSplitter', () {
    test('标准中文数字章节', () {
      final text = '第一章 相遇\n正文一\n第二章 离别\n正文二\n';
      final chapters = splitter.split(text);
      expect(chapters.length, 2);
      expect(chapters[0].title, '第一章 相遇');
      expect(chapters[0].rawText, '正文一');
      expect(chapters[0].status, ChapterStatus.notGenerated);
      expect(chapters[0].id, 0);
      expect(chapters[1].id, 1);
    });

    test('阿拉伯数字与多位编号', () {
      final text = '第1章 开始\n内容\n第12章 发展\n内容2\n第123章 高潮\n内容3';
      final chapters = splitter.split(text);
      expect(chapters.length, 3);
      expect(chapters[1].title, '第12章 发展');
      expect(chapters[2].title, '第123章 高潮');
    });

    test('前言与章节并存', () {
      final text = '这是前言内容\n第一章 开始\n正文';
      final chapters = splitter.split(text);
      expect(chapters.length, 2);
      expect(chapters[0].title, '前言');
      expect(chapters[0].rawText, '这是前言内容');
    });

    test('首个标题前的纯符号分隔线不作为章节（如 ------------）', () {
      final text = '------------\n第一章 开始\n正文';
      final chapters = splitter.split(text);
      expect(chapters.length, 1);
      expect(chapters[0].title, '第一章 开始');
      expect(chapters[0].rawText, '正文');
    });

    test('无标题且全为符号噪声时返回空列表', () {
      expect(splitter.split('------------\n===='), isEmpty);
    });

    test('无标题时整本作为一章', () {
      final text = '没有任何标题的整本内容\n只有文字';
      final chapters = splitter.split(text);
      expect(chapters.length, 1);
      expect(chapters[0].title, '全文');
      expect(chapters[0].rawText, text.trim());
    });

    test('空文本返回空列表', () {
      expect(splitter.split(''), isEmpty);
      expect(splitter.split('   \n  '), isEmpty);
    });

    test('正文行不以行首第X章格式时不会被误判', () {
      final text = '第一章 开始\n他说：第二章 还没到\n第二章 真的\n正文';
      final chapters = splitter.split(text);
      expect(chapters.length, 2);
      expect(chapters[0].rawText, '他说：第二章 还没到');
    });

    test('中文数字与空格变体', () {
      final text = '第 一 章 初见\n内容甲\n第一百二十回 终章\n内容乙';
      final chapters = splitter.split(text);
      expect(chapters.length, 2);
      expect(chapters[0].title, '第 一 章 初见');
      expect(chapters[1].title, '第一百二十回 终章');
    });

    test('卷/回/集/部/篇 标题变体', () {
      final text = '第一卷 风起\n内容一\n第十二回 对决\n内容二\n第三集 转折\n内容三\n';
      final chapters = splitter.split(text);
      expect(chapters.length, 3);
      expect(chapters[0].title, '第一卷 风起');
      expect(chapters[1].title, '第十二回 对决');
      expect(chapters[2].title, '第三集 转折');
    });

    test('CRLF 换行也能正确切分', () {
      final text = '第一章 相遇\r\n正文一\r\n第二章 离别\r\n正文二';
      final chapters = splitter.split(text);
      expect(chapters.length, 2);
      expect(chapters[0].title, '第一章 相遇');
      expect(chapters[0].rawText, '正文一');
    });

    test('标题后无正文时保留空章节（标题可见可重生成）', () {
      final text = '第一章 相遇\n正文\n第二章 离别\n';
      final chapters = splitter.split(text);
      expect(chapters.length, 2);
      expect(chapters[1].title, '第二章 离别');
      expect(chapters[1].rawText, '');
    });

    test('仅标题行也被保留为章节', () {
      final text = '第一章 只有标题';
      final chapters = splitter.split(text);
      expect(chapters.length, 1);
      expect(chapters[0].title, '第一章 只有标题');
    });
  });
}