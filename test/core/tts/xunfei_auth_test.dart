import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/tts/tts.dart';

void main() {
  group('formatHttpDate', () {
    test('RFC1123 GMT 格式', () {
      expect(formatHttpDate(DateTime.utc(2026, 8, 24, 8, 0, 0)), 'Mon, 24 Aug 2026 08:00:00 GMT');
    });

    test('日与时分秒补零', () {
      expect(formatHttpDate(DateTime.utc(2026, 1, 5, 0, 0, 0)), 'Mon, 05 Jan 2026 00:00:00 GMT');
    });

    test('本地时间自动转 UTC', () {
      // 本地时间 2026-08-24 16:00:00 视为 UTC+8，转 UTC 后为 08:00:00
      final local = DateTime(2026, 8, 24, 16, 0, 0);
      expect(formatHttpDate(local.toUtc()), 'Mon, 24 Aug 2026 08:00:00 GMT');
    });
  });

  group('buildAuthorization', () {
    test('golden 向量（与 .NET HMACSHA256 计算结果一致）', () {
      final auth = buildAuthorization(
        apiKey: 'test-key',
        apiSecret: 'test-secret',
        host: 'tts-api.xfyun.cn',
        date: 'Mon, 24 Aug 2026 08:00:00 GMT',
        requestLine: 'GET /v2/tts HTTP/1.1',
      );
      expect(
        auth,
        'api_key="test-key", algorithm="hmac-sha256", '
        'headers="host date request-line", '
        'signature="3PA+ntCxYwj5VkL8FcIVyp9nwWM/IMWTaecJ03Hx7mM="',
      );
    });

    test('更换 secret 后签名变化', () {
      String sign(String secret) => buildAuthorization(
            apiKey: 'key',
            apiSecret: secret,
            host: 'tts-api.xfyun.cn',
            date: 'Mon, 24 Aug 2026 08:00:00 GMT',
            requestLine: 'GET /v2/tts HTTP/1.1',
          );
      expect(sign('secret-a'), isNot(sign('secret-b')));
    });

    test('签名随 host / date / requestLine 变化', () {
      String build({String host = 'h', String date = 'd', String line = 'l'}) =>
          buildAuthorization(
            apiKey: 'k',
            apiSecret: 's',
            host: host,
            date: date,
            requestLine: line,
          );
      final base = build();
      expect(build(host: 'other'), isNot(base));
      expect(build(date: 'other'), isNot(base));
      expect(build(line: 'other'), isNot(base));
    });
  });
}
