import 'package:flutter/material.dart';

/// 听书熊品牌图标：扁平插画风熊头（戴耳机），年轻化审美。
///
/// 可作应用内装饰（书架空态 / 关于页），也是应用图标的绘制源
/// （tool/icon_render_test.dart 渲染出 1024 PNG 后由脚本生成三端图标）。
class BearLogo extends StatelessWidget {
  const BearLogo({super.key, this.size = 128});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: BearLogoPainter()),
    );
  }
}

/// 熊头绘制器：背景圆角方块 + 焦糖棕熊脸 + 深蓝耳机 + 闭眼微笑。
class BearLogoPainter extends CustomPainter {
  const BearLogoPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = Offset(size.width / 2, size.height / 2);

    // 背景：圆角方块 + 品牌蓝渐变
    final bg = RRect.fromRectAndRadius(
      Rect.fromCenter(center: c, width: s, height: s),
      Radius.circular(s * 0.22),
    );
    canvas.drawRRect(
      bg,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
        ).createShader(
          Rect.fromCenter(center: c, width: s, height: s),
        ),
    );

    // 坐标按 1024 设计稿缩放
    final k = s / 1024;
    Offset p(double x, double y) => c + Offset((x - 512) * k, (y - 512) * k);
    double r(double v) => v * k;

    const fur = Color(0xFFA9714B);
    const cream = Color(0xFFF7E8D9);
    const nose = Color(0xFF5C3A21);
    const headphone = Color(0xFF12315B);
    const headphoneInner = Color(0xFFE3F2FD);

    // 耳机：头梁弧 + 两侧耳罩（先画，压在耳朵下层留出轮廓）
    final headband = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r(66)
      ..strokeCap = StrokeCap.round
      ..color = headphone;
    final headbandPath = Path()
      ..moveTo(p(255, 420).dx, p(255, 420).dy)
      ..quadraticBezierTo(
        p(512, 130).dx,
        p(512, 130).dy,
        p(769, 420).dx,
        p(769, 420).dy,
      );
    canvas.drawPath(headbandPath, headband);
    for (final x in [265.0, 759.0]) {
      canvas.drawCircle(p(x, 585), r(118), Paint()..color = headphone);
      canvas.drawCircle(p(x, 585), r(66), Paint()..color = headphoneInner);
    }

    // 耳朵
    for (final x in [300.0, 724.0]) {
      canvas.drawCircle(p(x, 315), r(112), Paint()..color = fur);
      canvas.drawCircle(p(x, 315), r(56), Paint()..color = cream);
    }

    // 脸
    canvas.drawCircle(p(512, 575), r(305), Paint()..color = fur);

    // 口鼻区（奶油色）
    canvas.drawOval(
      Rect.fromCenter(
        center: p(512, 665),
        width: r(320),
        height: r(250),
      ),
      Paint()..color = cream,
    );

    // 鼻子
    canvas.drawOval(
      Rect.fromCenter(
        center: p(512, 610),
        width: r(74),
        height: r(58),
      ),
      Paint()..color = nose,
    );

    // 微笑：从鼻子下端向下的弧线
    final smile = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r(16)
      ..strokeCap = StrokeCap.round
      ..color = nose;
    final smilePath = Path()
      ..moveTo(p(512, 640).dx, p(512, 640).dy)
      ..quadraticBezierTo(
        p(512, 735).dx,
        p(512, 735).dy,
        p(455, 660).dx,
        p(455, 660).dy,
      );
    final smilePath2 = Path()
      ..moveTo(p(512, 640).dx, p(512, 640).dy)
      ..quadraticBezierTo(
        p(512, 735).dx,
        p(512, 735).dy,
        p(569, 660).dx,
        p(569, 660).dy,
      );
    canvas.drawPath(smilePath, smile);
    canvas.drawPath(smilePath2, smile);

    // 闭眼微笑眼（弯月弧）
    final eye = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = r(20)
      ..strokeCap = StrokeCap.round
      ..color = nose;
    for (final x in [375.0, 649.0]) {
      final eyePath = Path()
        ..moveTo(p(x - 55, 465).dx, p(x - 55, 465).dy)
        ..quadraticBezierTo(
          p(x, 500).dx,
          p(x, 500).dy,
          p(x + 55, 465).dx,
          p(x + 55, 465).dy,
        );
      canvas.drawPath(eyePath, eye);
    }
  }

  @override
  bool shouldRepaint(covariant BearLogoPainter oldDelegate) => false;
}
