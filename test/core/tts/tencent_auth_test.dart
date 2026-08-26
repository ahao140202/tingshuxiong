import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/core/tts/tencent/tencent_auth.dart';

void main() {
  group('TencentSigner', () {
    const secretId = 'AKIDz8krbsJ5yKBZQpn74WFkmLPx3TEST';
    const secretKey = 'Gu5t9xGARNpq86cd98joQYCN3TEST';
    const host = 'tts.tencentcloudapi.com';
    const timestamp = 1690000000; // 2023-07-22 UTC

    test('生成官方算法一致的 Authorization 头（黄金值）', () {
      // 期望值由腾讯云官方 SDK（tencentcloud-sdk-python）同参数计算得出。
      const payload = '{"Text":"你好世界","VoiceType":101001}';
      final auth = TencentSigner(
        secretId: secretId,
        secretKey: secretKey,
      ).authorization(timestamp: timestamp, payload: payload, host: host);
      expect(
        auth,
        'TC3-HMAC-SHA256 Credential=$secretId/2023-07-22/tts/tc3_request, '
        'SignedHeaders=content-type;host, '
        'Signature=d162a1f8e05babdf49cbd334fadf96dd0350aa3aa7653801ce9707b043b48696',
      );
    });

    test('payload 变化导致签名变化', () {
      final signer = TencentSigner(secretId: secretId, secretKey: secretKey);
      final a = signer.authorization(
          timestamp: timestamp, payload: '{"Text":"a"}', host: host);
      final b = signer.authorization(
          timestamp: timestamp, payload: '{"Text":"b"}', host: host);
      expect(a, isNot(b));
    });

    test('timestamp 变化导致签名变化（日期随 UTC 推进）', () {
      final signer = TencentSigner(secretId: secretId, secretKey: secretKey);
      final a = signer.authorization(
          timestamp: 1690000000, payload: '{"Text":"a"}', host: host);
      final b = signer.authorization(
          timestamp: 1690000001, payload: '{"Text":"a"}', host: host);
      expect(a, isNot(b));
    });

    test('host 变化导致签名变化', () {
      final signer = TencentSigner(secretId: secretId, secretKey: secretKey);
      final a = signer.authorization(
          timestamp: timestamp, payload: '{"Text":"a"}', host: host);
      final b = signer.authorization(
          timestamp: timestamp, payload: '{"Text":"a"}', host: 'other.com');
      expect(a, isNot(b));
    });

    test('Authorization 头包含 Credential 与 scope', () {
      final auth = TencentSigner(
        secretId: secretId,
        secretKey: secretKey,
      ).authorization(timestamp: timestamp, payload: '{}', host: host);
      expect(auth, startsWith('TC3-HMAC-SHA256 Credential=$secretId/2023-07-22/tts/tc3_request, '));
      expect(auth, contains('SignedHeaders=content-type;host'));
      expect(auth, contains('Signature='));
    });
  });
}
