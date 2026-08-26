import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/core/tts/tencent/tencent_stream_tts_provider.dart';
import 'package:tingshuxiong/core/tts/tencent/tencent_tts_provider.dart';
import 'package:tingshuxiong/core/tts/tts_provider.dart';

/// 构造带拦截器的 Dio：拦截所有请求，由 [handler] 返回伪造响应。
Dio fakeDio({required Response<dynamic> Function(RequestOptions options) handler}) {
  final dio = Dio(BaseOptions(baseUrl: 'http://fake'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler0) => handler0.resolve(handler(options)),
    ),
  );
  return dio;
}

/// 固定时间源：1690000000 秒（2023-07-22 UTC）。
DateTime fixedNow() => DateTime.fromMillisecondsSinceEpoch(1690000000 * 1000);

void main() {
  group('TencentTTSProvider', () {
    test('kind 为 tencent，默认音色为 101001', () {
      final provider = TencentTTSProvider(secretId: 'sid', secretKey: 'skey');
      expect(provider.kind, TTSKind.tencent);
      expect(TTSKind.tencent.defaultVoice, '101001');
    });

    test('synthesize 发送正确的请求体与签名头', () async {
      Map<String, dynamic>? body;
      Map<String, dynamic>? headers;

      final dio = fakeDio(handler: (options) {
        body = jsonDecode(options.data as String) as Map<String, dynamic>;
        headers = options.headers;
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'Response': {'Audio': base64Encode(utf8.encode('audio-bytes'))},
          },
        );
      });

      final provider = TencentTTSProvider(
        secretId: 'AKIDsid',
        secretKey: 'skey',
        dio: dio,
        now: fixedNow,
      );
      final audio = await provider.synthesize(
        text: '你好世界',
        config: const TTSConfig(voice: '501000', speed: 50, volume: 50),
      );

      expect(audio, utf8.encode('audio-bytes'));
      // 请求体：VoiceType 按音色 ID 解析，默认语速/音量映射为 0。
      expect(body!['Text'], '你好世界');
      expect(body!['VoiceType'], 501000);
      expect(body!['Speed'], 0);
      expect(body!['Volume'], 0);
      expect(body!['SampleRate'], 16000);
      expect(body!['Codec'], 'mp3');
      expect(body!['SessionId'], isNotEmpty);
      // 请求头：TC3 签名 + API 3.0 常量。
      expect(headers!['X-TC-Action'], 'TextToVoice');
      expect(headers!['X-TC-Version'], '2019-08-23');
      expect(headers!['X-TC-Timestamp'], '1690000000');
      expect(headers!['X-TC-Region'], 'ap-guangzhou');
      expect(headers!['Host'], 'tts.tencentcloudapi.com');
      final auth = headers!['Authorization'] as String;
      expect(auth, startsWith('TC3-HMAC-SHA256 Credential=AKIDsid/2023-07-22/tts/tc3_request, '));
      expect(auth, contains('SignedHeaders=content-type;host'));
      expect(auth, contains('Signature='));
    });

    test('语速/音量按 TTSConfig 0-100 映射到接口范围', () async {
      Map<String, dynamic>? body;
      final dio = fakeDio(handler: (options) {
        body = jsonDecode(options.data as String) as Map<String, dynamic>;
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'Response': {'Audio': base64Encode([1, 2, 3])},
          },
        );
      });
      final provider = TencentTTSProvider(
        secretId: 'sid',
        secretKey: 'skey',
        dio: dio,
        now: fixedNow,
      );

      // 最慢/最小：语速 -2（0.6x）、音量 -10。
      await provider.synthesize(
          text: 't', config: const TTSConfig(speed: 0, volume: 0));
      expect(body!['Speed'], -2.0);
      expect(body!['Volume'], -10.0);

      // 最快/最大：语速 6（2.5x）、音量 10。
      await provider.synthesize(
          text: 't', config: const TTSConfig(speed: 100, volume: 100));
      expect(body!['Speed'], 6.0);
      expect(body!['Volume'], 10.0);

      // 中间：语速 1.2x=1、音量 5。
      await provider.synthesize(
          text: 't', config: const TTSConfig(speed: 58, volume: 75));
      expect(body!['Speed'], closeTo(0.96, 0.001));
      expect(body!['Volume'], 5.0);
    });

    test('超长文本按块多次合成并拼接', () async {
      // 每块最多 440 字节：100 个汉字（300 字节）1 次，600 个汉字（1800 字节）分多块。
      final texts = <String>[];
      final dio = fakeDio(handler: (options) {
        final body = jsonDecode(options.data as String) as Map<String, dynamic>;
        texts.add(body['Text'] as String);
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'Response': {
              'Audio': base64Encode(utf8.encode('chunk-${texts.length}')),
            },
          },
        );
      });
      final provider = TencentTTSProvider(
        secretId: 'sid',
        secretKey: 'skey',
        dio: dio,
        now: fixedNow,
      );

      final longText = List.filled(600, '字').join();
      final audio = await provider.synthesize(
          text: longText, config: const TTSConfig());

      expect(texts.length, greaterThan(1));
      expect(utf8.encode(texts.join()).length, utf8.encode(longText).length);
      // 分块拼接后音频完整。
      final expected = utf8.encode(List.generate(texts.length, (i) => 'chunk-${i + 1}').join());
      expect(audio, Uint8List.fromList(expected));
    });

    test('接口返回 Error 时抛出 TTSException', () async {
      final dio = fakeDio(handler: (options) {
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'Response': {
              'Error': {'Code': 'AuthFailure.SignatureFailure', 'Message': '签名错误'},
            },
          },
        );
      });
      final provider = TencentTTSProvider(
          secretId: 'sid', secretKey: 'skey', dio: dio, now: fixedNow);
      await expectLater(
        provider.synthesize(text: 't', config: const TTSConfig()),
        throwsA(
          isA<TTSException>().having(
            (e) => e.message,
            'message',
            contains('签名错误'),
          ),
        ),
      );
    });

    test('响应缺少音频数据时抛出 TTSException', () async {
      final dio = fakeDio(handler: (options) {
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'Response': {'SessionId': 'x'},
          },
        );
      });
      final provider = TencentTTSProvider(
          secretId: 'sid', secretKey: 'skey', dio: dio, now: fixedNow);
      await expectLater(
        provider.synthesize(text: 't', config: const TTSConfig()),
        throwsA(isA<TTSException>()),
      );
    });

    test('DioException 包装为 TTSException', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://fake'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException(requestOptions: options, message: 'Connection refused'),
          ),
        ),
      );
      final provider = TencentTTSProvider(
          secretId: 'sid', secretKey: 'skey', dio: dio, now: fixedNow);
      await expectLater(
        provider.synthesize(text: 't', config: const TTSConfig()),
        throwsA(
          isA<TTSException>()
              .having((e) => e.message, 'message', contains('Connection refused')),
        ),
      );
    });

    test('超自然音色自动切换到实时合成（WebSocket），不触发基础接口', () async {
      var wsCalled = false;
      var httpCalled = false;
      final dio = fakeDio(handler: (options) {
        httpCalled = true;
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {'Response': {'Audio': base64Encode([1])}},
        );
      });
      final provider = TencentTTSProvider(
        secretId: 'sid',
        secretKey: 'skey',
        appId: '125',
        dio: dio,
        wsConnect: (uri) async {
          wsCalled = true;
          throw const WebSocketException('fake connect failure');
        },
        now: fixedNow,
      );
      await expectLater(
        provider.synthesize(text: 't', config: const TTSConfig(voice: '502007')),
        throwsA(isA<TTSException>()),
      );
      expect(wsCalled, isTrue);
      expect(httpCalled, isFalse);
    });

    test('普通音色走基础接口，不触发 WebSocket', () async {
      var wsCalled = false;
      final dio = fakeDio(handler: (options) {
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {'Response': {'Audio': base64Encode([1, 2, 3])}},
        );
      });
      final provider = TencentTTSProvider(
        secretId: 'sid',
        secretKey: 'skey',
        dio: dio,
        wsConnect: (uri) async {
          wsCalled = true;
          throw UnimplementedError();
        },
        now: fixedNow,
      );
      final audio = await provider.synthesize(
          text: 't', config: const TTSConfig(voice: '501000'));
      expect(audio, [1, 2, 3]);
      expect(wsCalled, isFalse);
    });
  });
}
