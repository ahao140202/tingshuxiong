import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/core/tts/tencent/tencent_stream_tts_provider.dart';
import 'package:tingshuxiong/core/tts/tts_provider.dart';

/// 可控的伪 WebSocket：测试向 [pushText] / [pushBytes] 注入服务端消息，
/// 观察 [closeCode] 确认连接按协议关闭。
class FakeSocket implements TtsWebSocket {
  final StreamController<dynamic> _controller = StreamController<dynamic>();
  final Completer<void> _done = Completer<void>();

  /// 客户端主动关闭时的 close code（未关闭为 null）。
  int? closeCode;

  /// 测试辅助：推送文本消息（JSON 响应）。
  void pushText(String text) => _controller.add(text);

  /// 测试辅助：推送二进制消息（音频帧）。
  void pushBytes(List<int> bytes) => _controller.add(bytes);

  /// 测试辅助：模拟连接中断。
  void fail(Object error) => _controller.addError(error);

  @override
  Stream<dynamic> get stream => _controller.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close([int? code, String? reason]) async {
    closeCode = code;
    if (!_done.isCompleted) {
      _done.complete();
      await _controller.close();
    }
  }
}

/// 固定时间源：1690000000 秒（2023-07-22 UTC）。
DateTime fixedNow() => DateTime.fromMillisecondsSinceEpoch(1690000000 * 1000);

/// 按 provider 相同算法独立计算签名，验证 URL 中的 Signature 参数。
String expectedSign(String secretKey, Map<String, String> params) {
  final sortedKeys = params.keys.toList()..sort();
  final raw = '${TencentStreamTTSProvider.signPrefix}?'
      '${sortedKeys.map((k) => '$k=${params[k]}').join('&')}';
  final digest =
      Hmac(sha1, utf8.encode(secretKey)).convert(utf8.encode(raw)).bytes;
  return base64Encode(digest);
}

void main() {
  group('TencentStreamTTSProvider', () {
    test('kind 为 tencent，超自然音色判断覆盖官方 ID 段', () {
      final provider = TencentStreamTTSProvider(
          secretId: 'sid', secretKey: 'skey');
      expect(provider.kind, TTSKind.tencent);
      // 超自然：502 / 602 / 603 段。
      expect(TencentStreamTTSProvider.isSupernaturalVoice('502007'), isTrue);
      expect(TencentStreamTTSProvider.isSupernaturalVoice('502001'), isTrue);
      expect(TencentStreamTTSProvider.isSupernaturalVoice('602003'), isTrue);
      expect(TencentStreamTTSProvider.isSupernaturalVoice('603000'), isTrue);
      // 非超自然：大模型 / 精品音色。
      expect(TencentStreamTTSProvider.isSupernaturalVoice('501000'), isFalse);
      expect(TencentStreamTTSProvider.isSupernaturalVoice('601015'), isFalse);
      expect(TencentStreamTTSProvider.isSupernaturalVoice('101001'), isFalse);
    });

    test('未配置 AppId 时明确报错', () async {
      final provider = TencentStreamTTSProvider(
          secretId: 'sid', secretKey: 'skey');
      await expectLater(
        provider.synthesize(text: '你好', config: const TTSConfig()),
        throwsA(
          isA<TTSException>()
              .having((e) => e.message, 'message', contains('AppId')),
        ),
      );
    });

    test('签名 URL 参数齐全、字典序、编码与签名值正确', () async {
      Uri? captured;
      final ws = FakeSocket();
      final provider = TencentStreamTTSProvider(
        secretId: 'AKIDsid',
        secretKey: 'skey',
        appId: '1250000000',
        wsConnect: (uri) async {
          captured = uri;
          return ws;
        },
        now: fixedNow,
      );

      final future = provider.synthesize(
        text: '你好世界',
        config: const TTSConfig(voice: '502007', speed: 58, volume: 75),
      );
      ws.pushText('{"code":0,"final":1}');
      final audio = await future;

      expect(audio, isEmpty);
      final url = captured!;
      expect(url.scheme, 'wss');
      expect(url.host, 'tts.cloud.tencent.com');
      expect(url.path, '/stream_ws');
      // 参数按字典序排列（Action 最小、Volume 最大，Signature 追加末尾）。
      final expectedKeys = [
        'Action', 'AppId', 'Codec', 'EnableSubtitle', 'Expired',
        'SampleRate', 'SecretId', 'SessionId', 'Speed', 'Text',
        'Timestamp', 'VoiceType', 'Volume', 'Signature',
      ];
      expect(url.queryParameters.keys.toList(), expectedKeys);
      expect(url.queryParameters['Action'], 'TextToStreamAudioWS');
      expect(url.queryParameters['AppId'], '1250000000');
      expect(url.queryParameters['Codec'], 'mp3');
      expect(url.queryParameters['SampleRate'], '16000');
      expect(url.queryParameters['SecretId'], 'AKIDsid');
      expect(url.queryParameters['Timestamp'], '1690000000');
      expect(url.queryParameters['Expired'], '1690086400');
      expect(url.queryParameters['VoiceType'], '502007');
      // 文本 URL 编码后可还原，签名用原文（含中文）。
      expect(url.queryParameters['Text'], '你好世界');
      // 语速 58 → 0.96（非整数保留小数），音量 75 → 5（[0,10] 映射）。
      expect(url.queryParameters['Speed'], '0.96');
      expect(url.queryParameters['Volume'], '5');
      // 签名值与独立计算一致（HMAC-SHA1 + Base64，密钥为 SecretKey）。
      final params = {
        'Action': 'TextToStreamAudioWS',
        'AppId': '1250000000',
        'Codec': 'mp3',
        'EnableSubtitle': 'false',
        'Expired': '1690086400',
        'SampleRate': '16000',
        'SecretId': 'AKIDsid',
        'SessionId': url.queryParameters['SessionId']!,
        'Speed': '0.96',
        'Text': '你好世界',
        'Timestamp': '1690000000',
        'VoiceType': '502007',
        'Volume': '5',
      };
      expect(url.queryParameters['Signature'], expectedSign('skey', params));
    });

    test('语速/音量按实时接口范围映射（语速 [-2,6]、音量 [0,10]）', () async {
      Uri? captured;
      final sockets = <FakeSocket>[];
      final provider = TencentStreamTTSProvider(
        secretId: 'sid',
        secretKey: 'skey',
        appId: '125',
        wsConnect: (uri) async {
          captured = uri;
          final ws = FakeSocket();
          sockets.add(ws);
          return ws;
        },
        now: fixedNow,
      );

      final future = provider.synthesize(
          text: 't', config: const TTSConfig(voice: '502001', speed: 0, volume: 0));
      sockets.last.pushText('{"code":0,"final":1}');
      await future;
      expect(captured!.queryParameters['Speed'], '-2');
      expect(captured!.queryParameters['Volume'], '0');

      final future2 = provider.synthesize(
          text: 't', config: const TTSConfig(voice: '502001', speed: 100, volume: 100));
      sockets.last.pushText('{"code":0,"final":1}');
      await future2;
      expect(captured!.queryParameters['Speed'], '6');
      expect(captured!.queryParameters['Volume'], '10');
    });

    test('流式接收：二进制音频按序拼接，尾包后主动关闭连接', () async {
      final ws = FakeSocket();
      final provider = TencentStreamTTSProvider(
        secretId: 'sid',
        secretKey: 'skey',
        appId: '125',
        wsConnect: (uri) async => ws,
        now: fixedNow,
      );

      final future = provider.synthesize(
          text: '你好', config: const TTSConfig(voice: '502007'));
      // 顺序无关：状态消息与音频帧可交错到达。
      ws.pushText('{"code":0,"session_id":"s"}');
      ws.pushBytes([1, 2, 3]);
      ws.pushBytes([4, 5]);
      ws.pushText('{"code":0,"final":1,"session_id":"s"}');

      final audio = await future;
      expect(audio, [1, 2, 3, 4, 5]);
      // 收到尾包后客户端按协议主动关闭（close code 默认 1000）。
      expect(ws.closeCode, 1000);
    });

    test('响应 code 非 0 时抛出 TTSException 并携带服务端 message', () async {
      final ws = FakeSocket();
      final provider = TencentStreamTTSProvider(
        secretId: 'sid',
        secretKey: 'skey',
        appId: '125',
        wsConnect: (uri) async => ws,
        now: fixedNow,
      );

      final future = provider.synthesize(
          text: '你好', config: const TTSConfig(voice: '502007'));
      ws.pushText('{"code":-1,"message":"音色未开通"}');
      await expectLater(
        future,
        throwsA(
          isA<TTSException>()
              .having((e) => e.message, 'message', contains('音色未开通')),
        ),
      );
    });

    test('连接失败包装为 TTSException', () async {
      final provider = TencentStreamTTSProvider(
        secretId: 'sid',
        secretKey: 'skey',
        appId: '125',
        wsConnect: (uri) async => throw const WebSocketException('connect refused'),
        now: fixedNow,
      );
      await expectLater(
        provider.synthesize(text: 't', config: const TTSConfig(voice: '502007')),
        throwsA(
          isA<TTSException>()
              .having((e) => e.message, 'message', contains('连接失败')),
        ),
      );
    });

    test('等待超时抛出 TTSException', () async {
      final ws = FakeSocket();
      final provider = TencentStreamTTSProvider(
        secretId: 'sid',
        secretKey: 'skey',
        appId: '125',
        wsConnect: (uri) async => ws,
        now: fixedNow,
        timeout: const Duration(milliseconds: 50),
      );
      // 不推送任何消息，等待超时触发。
      await expectLater(
        provider.synthesize(text: 't', config: const TTSConfig(voice: '502007')),
        throwsA(
          isA<TTSException>()
              .having((e) => e.message, 'message', contains('超时')),
        ),
      );
    });

    test('连接中途断开包装为 TTSException', () async {
      final ws = FakeSocket();
      final provider = TencentStreamTTSProvider(
        secretId: 'sid',
        secretKey: 'skey',
        appId: '125',
        wsConnect: (uri) async => ws,
        now: fixedNow,
      );
      final future = provider.synthesize(
          text: '你好', config: const TTSConfig(voice: '502007'));
      ws.pushBytes([1, 2]);
      ws.fail(Exception('socket closed'));
      await expectLater(
        future,
        throwsA(
          isA<TTSException>()
              .having((e) => e.message, 'message', contains('连接中断')),
        ),
      );
    });

    test('超长文本按块多次合成并拼接', () async {
      // 每块最多 1800 字节：600 汉字（1800 字节）1 次，601 汉字分 2 块。
      final sockets = <FakeSocket>[];
      final provider = TencentStreamTTSProvider(
        secretId: 'sid',
        secretKey: 'skey',
        appId: '125',
        wsConnect: (uri) async {
          final ws = FakeSocket();
          sockets.add(ws);
          return ws;
        },
        now: fixedNow,
      );

      final longText = List.filled(601, '字').join();
      final future = provider.synthesize(
          text: longText, config: const TTSConfig(voice: '502007'));
      // 分块按顺序合成：等待每块对应的连接建立后再推送尾包。
      for (var i = 0; i < 2; i++) {
        while (sockets.length <= i) {
          await Future<void>.delayed(const Duration(milliseconds: 1));
        }
        sockets[i].pushBytes([i + 1]);
        sockets[i].pushText('{"code":0,"final":1}');
      }

      final audio = await future;
      expect(sockets.length, 2);
      expect(audio, [1, 2]);
    });
  });
}
