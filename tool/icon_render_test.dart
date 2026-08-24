import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tingshuxiong/ui/widgets/bear_logo.dart';

/// 渲染应用图标源图：把 [BearLogo] 渲染为 1024x1024 PNG
/// （tool/build/logo.png，golden 文件路径相对本测试文件），
/// 供 tool/gen_icons.ps1 生成 Windows / Android / iOS 三端图标。
///
/// 运行：`flutter test --update-goldens tool/icon_render_test.dart`
void main() {
  testWidgets('render bear logo to png', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 1024));
    await tester.pumpWidget(
      const Material(child: BearLogo(size: 1024)),
    );
    await tester.pump();

    await expectLater(
      find.byType(BearLogo),
      matchesGoldenFile('build/logo.png'),
    );
  });
}
