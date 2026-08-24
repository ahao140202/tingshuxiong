import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/domain/domain.dart';
import 'package:tingshuxiong/core/llm/llm.dart';

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

void main() {
  group('DeepSeekProvider', () {
    test('rewrite 发送正确的请求体并返回改写文本', () async {
      Map<String, dynamic>? body;
      String? authHeader;

      final dio = fakeDio(handler: (options) {
        body = options.data as Map<String, dynamic>;
        authHeader = options.headers['Authorization'] as String?;
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'choices': [
              {
                'message': {'content': '  改写后的口语化文本  '},
              },
            ],
          },
        );
      });

      final provider = DeepSeekProvider(apiKey: 'sk-test', dio: dio);
      final result = await provider.rewrite(title: '第一章 相遇', rawText: '原文内容');

      expect(result, '改写后的口语化文本');
      expect(authHeader, 'Bearer sk-test');
      expect(body!['model'], 'deepseek-v4-flash');
      expect(body!['max_tokens'], 1500);
      expect(body!['temperature'], 0.7);
      final messages = body!['messages'] as List;
      expect(messages.length, 2);
      expect((messages[0] as Map)['role'], 'system');
      expect((messages[1] as Map)['role'], 'user');
      expect((messages[1] as Map)['content'], contains('第一章 相遇'));
      expect((messages[1] as Map)['content'], contains('原文内容'));
    });

    test('rewrite 透传 maxTokens 与 temperature', () async {
      Map<String, dynamic>? body;
      final dio = fakeDio(handler: (options) {
        body = options.data as Map<String, dynamic>;
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'choices': [
              {
                'message': {'content': 'ok'},
              },
            ],
          },
        );
      });
      final provider = DeepSeekProvider(apiKey: 'sk-test', dio: dio);
      await provider.rewrite(title: 't', rawText: 'r', maxTokens: 800, temperature: 0.3);

      expect(body!['max_tokens'], 800);
      expect(body!['temperature'], 0.3);
      expect(provider.model, 'deepseek-v4-flash');
      expect(provider.kind, LLMKind.deepSeek);
    });

    test('响应缺少 choices 时抛出 LLMException', () async {
      final dio = fakeDio(handler: (options) {
        return Response(requestOptions: options, statusCode: 200, data: {'foo': 1});
      });
      final provider = DeepSeekProvider(apiKey: 'sk-test', dio: dio);
      expect(
        () => provider.rewrite(title: 't', rawText: 'r'),
        throwsA(isA<LLMException>()),
      );
    });

    test('响应内容为空时抛出 LLMException', () async {
      final dio = fakeDio(handler: (options) {
        return Response(
          requestOptions: options,
          statusCode: 200,
          data: {
            'choices': [
              {
                'message': {'content': '   '},
              },
            ],
          },
        );
      });
      final provider = DeepSeekProvider(apiKey: 'sk-test', dio: dio);
      expect(
        () => provider.rewrite(title: 't', rawText: 'r'),
        throwsA(isA<LLMException>()),
      );
    });

    test('DioException 包装为 LLMException', () async {
      final dio = Dio(BaseOptions(baseUrl: 'http://fake'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) => handler.reject(
            DioException(requestOptions: options, message: 'Connection refused'),
          ),
        ),
      );
      final provider = DeepSeekProvider(apiKey: 'sk-test', dio: dio);
      await expectLater(
        provider.rewrite(title: 't', rawText: 'r'),
        throwsA(
          isA<LLMException>()
              .having((e) => e.message, 'message', contains('Connection refused')),
        ),
      );
    });
  });
}
