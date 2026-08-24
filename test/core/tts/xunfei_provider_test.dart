import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/core/tts/tts.dart';

/// 本地伪讯飞服务端：监听回环地址，用真实 WebSocket 升级处理请求，
/// 校验请求头/请求体后按测试脚本回帧。
class FakeXunfeiServer {
  FakeXunfeiServer();

  late final HttpServer server;
  final requests = <Map<String, dynamic>>[];
  final headers = <String>[];
  bool _started = false;

  /// 启动并配置请求处理：[onRequest] 负责回帧（可多次 add）。
  Future<void> start(
    void Function(WebSocket ws, Map<String, dynamic> request) onRequest,
  ) async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _started = true;
    server.listen((req) async {
      final ws = await WebSocketTransformer.upgrade(req);
      headers.addAll([
        '${req.method} ${req.uri.path}',
        'authorization=${req.headers.value('authorization')}',
        'date=${req.headers.value('date')}',
        'host=${req.headers.value('host')}',
      ]);
      ws.listen(
        (msg) {
          requests.add(jsonDecode(msg as String) as Map<String, dynamic>);
          onRequest(ws, requests.last);
        },
        onDone: () => ws.close(),
      );
    });
  }

  Uri get wsUri => Uri.parse('ws://127.0.0.1:${server.port}/v2/tts');

  Future<void> close() async {
    if (!_started) return;
    await server.close(force: true);
  }
}

/// 便捷回帧：单帧 status=2。
void sendFrame(WebSocket ws, String? audio, {int status = 2, int code = 0, String message = 'success'}) {
  ws.add(jsonEncode({
    'code': code,
    'message': message,
    'data': {'audio': audio, 'status': status},
  }));
}

void main() {
  const config = TTSConfig();

  group('XunfeiTTSProvider', () {
    late FakeXunfeiServer server;

    setUp(() async {
      server = FakeXunfeiServer();
    });

    tearDown(() async {
      await server.close();
    });

    XunfeiTTSProvider makeProvider() => XunfeiTTSProvider(
          appId: 'app-1',
          apiKey: 'key-1',
          apiSecret: 'secret-1',
          baseUrl: server.wsUri.toString(),
        );

    test('请求体与鉴权头正确，多帧音频拼接并解码', () async {
      const audio1 = 'part1';
      const audio2 = 'part2';
      await server.start((ws, request) {
        // 响应分两帧返回（status=1 中间帧 + status=2 结束帧）。
        sendFrame(ws, base64Encode(utf8.encode(audio1)), status: 1);
        sendFrame(ws, base64Encode(utf8.encode(audio2)), status: 2);
      });

      final provider = makeProvider();
      final result = await provider.synthesize(text: '你好世界', config: config);

      expect(utf8.decode(result), '$audio1$audio2');
      expect(provider.kind, TTSKind.xunfei);
      expect(server.requests.length, 1);
      final body = server.requests.single;
      expect(body['common'], {'app_id': 'app-1'});
      final business = body['business'] as Map;
      expect(business['vcn'], 'xiaoyan');
      expect(business['speed'], 50);
      expect(business['volume'], 50);
      expect(business['pitch'], 50);
      expect(business['aue'], 'lame');
      final data = body['data'] as Map;
      expect(data['text'], base64Encode(utf8.encode('你好世界')));
      expect(data['status'], 2);
      // 鉴权头
      final auth = server.headers.firstWhere((h) => h.startsWith('authorization='));
      expect(auth, contains('api_key="key-1"'));
      expect(auth, contains('algorithm="hmac-sha256"'));
      expect(auth, contains('headers="host date request-line"'));
      expect(server.headers, contains('host=127.0.0.1'));
      expect(
        server.headers.firstWhere((h) => h.startsWith('date=')),
        matches(RegExp(r'^date=[A-Z][a-z]{2}, \d{2} [A-Z][a-z]{2} \d{4} \d{2}:\d{2}:\d{2} GMT$')),
      );
    });

    test('合成参数从 config 透传', () async {
      await server.start((ws, request) {
        sendFrame(ws, base64Encode(utf8.encode('x')));
      });
      final provider = makeProvider();
      const custom = TTSConfig(voice: 'aisjiu', speed: 70, volume: 30, pitch: 60);
      await provider.synthesize(text: '测试', config: custom);

      final business = server.requests.single['business'] as Map;
      expect(business['vcn'], 'aisjiu');
      expect(business['speed'], 70);
      expect(business['volume'], 30);
      expect(business['pitch'], 60);
    });

    test('业务错误码抛出 TTSException', () async {
      await server.start((ws, request) {
        sendFrame(ws, null, code: 10001, message: 'invalid app_id');
      });
      final provider = makeProvider();
      await expectLater(
        provider.synthesize(text: 't', config: config),
        throwsA(
          isA<TTSException>()
              .having((e) => e.message, 'message', contains('10001'))
              .having((e) => e.message, 'message', contains('invalid app_id')),
        ),
      );
    });

    test('响应缺少音频数据抛出 TTSException', () async {
      await server.start((ws, request) {
        sendFrame(ws, null, status: 2);
      });
      final provider = makeProvider();
      await expectLater(
        provider.synthesize(text: 't', config: config),
        throwsA(isA<TTSException>()),
      );
    });

    test('音频 base64 非法时抛出 TTSException', () async {
      await server.start((ws, request) {
        sendFrame(ws, '!!!not-base64!!!', status: 2);
      });
      final provider = makeProvider();
      await expectLater(
        provider.synthesize(text: 't', config: config),
        throwsA(
          isA<TTSException>()
              .having((e) => e.message, 'message', contains('base64')),
        ),
      );
    });

    test('连接失败包装为 TTSException', () async {
      final provider = XunfeiTTSProvider(
        appId: 'app-1',
        apiKey: 'key-1',
        apiSecret: 'secret-1',
        connect: (uri, {headers}) async {
          throw SocketException('Connection refused');
        },
      );
      await expectLater(
        provider.synthesize(text: 't', config: config),
        throwsA(
          isA<TTSException>()
              .having((e) => e.message, 'message', contains('讯飞连接失败'))
              .having((e) => e.message, 'message', contains('Connection refused')),
        ),
      );
    });

    test('超长文本自动分块合成并拼接（单次不超过 12000 字节）', () async {
      await server.start((ws, request) {
        sendFrame(ws, base64Encode(utf8.encode('p${server.requests.length}')));
      });
      final provider = makeProvider();
      // 22500 字节 ≈ 2 块，验证分块、逐块合成、拼接与文本无损。
      final longText = '你好。' * 2500;
      final result = await provider.synthesize(text: longText, config: config);

      expect(server.requests.length, greaterThanOrEqualTo(2));
      // 每块请求文本均不超过单次上限（UTF-8 字节）。
      for (final request in server.requests) {
        final textB64 = (request['data'] as Map)['text'] as String;
        expect(
          utf8.encode(utf8.decode(base64Decode(textB64))).length <= 12000,
          isTrue,
        );
      }
      // 拼接后的音频顺序对应各块响应。
      final expected = StringBuffer();
      for (var i = 1; i <= server.requests.length; i++) {
        expected.write('p$i');
      }
      expect(utf8.decode(result), expected.toString());
      // 文本未丢失：全部请求文本拼接后等于原文。
      final sent = server.requests
          .map((r) =>
              utf8.decode(base64Decode((r['data'] as Map)['text'] as String)))
          .join();
      expect(sent, longText);
    });
  });
}
