// 一次性图标生成脚本。
//
// 从 icon/source_icon.png（任意尺寸的正方形 PNG，建议 ≥256×256，推荐 1024×1024；
// 非正方形会自动居中裁方）自动生成：
//   - Android：android/app/src/main/res/mipmap-*/ic_launcher.png（各密度）
//     （Android 由系统启动器统一裁切形状，保持正方形源图即可）
//   - Windows：windows/runner/resources/app_icon.ico（多尺寸，自动裁切透明圆角）
//
// 用法（在项目根目录执行）：
//   dart run icon/generate_icons.dart
//
// 依赖：dev_dependencies 中的 image 包（纯 Dart，跨平台，无需安装系统工具）。
// 替换图标：把新的 PNG 命名为 source_icon.png 放入 icon/ 目录后重跑本脚本
// （源图过小会被放大导致模糊，建议边长 ≥256px，推荐 1024×1024）。
import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart' as img;

/// Android mipmap 密度 → 图标边长（px）。
const Map<String, int> _kAndroidDensities = {
  'mdpi': 48,
  'hdpi': 72,
  'xhdpi': 96,
  'xxhdpi': 144,
  'xxxhdpi': 192,
};

/// Windows ICO 包含的尺寸（encodeIco 默认按这些尺寸输出多分辨率图标）。
const List<int> _kWindowsIconSizes = [16, 24, 32, 48, 64, 128, 256];

void main() {
  final root = _findProjectRoot();
  final sourceFile = File(
    '${root.path}${Platform.pathSeparator}icon${Platform.pathSeparator}'
    'source_icon.png',
  );

  if (!sourceFile.existsSync()) {
    stderr.writeln('未找到源图：${sourceFile.path}');
    stderr.writeln('请将正方形 PNG 命名为 source_icon.png 放入 icon/ 目录后重试'
        '（任意尺寸均可，建议边长 ≥256px）。');
    exitCode = 1;
    return;
  }

  final source = img.decodeImage(sourceFile.readAsBytesSync());
  if (source == null) {
    stderr.writeln('无法解码源图（支持 PNG/JPG 等常见图片格式）：${sourceFile.path}');
    exitCode = 1;
    return;
  }

  // 居中裁切为正方形，避免非正方形源图被拉伸变形。
  final square = _centerSquare(source);

  // 源图小于最大输出尺寸（Windows ICO 的 256px）时会被放大，提示可能模糊。
  final maxOutput = _kWindowsIconSizes.last;
  if (square.width < maxOutput) {
    stdout.writeln(
      '警告：源图裁方后仅 ${square.width}×${square.width}px，小于最大输出 '
      '${maxOutput}px，会被放大可能模糊；建议使用边长 ≥${maxOutput}px'
      '（推荐 1024×1024）的源图。',
    );
  }

  _generateAndroidIcons(root, square);
  _generateWindowsIco(root, square);

  stdout.writeln('');
  stdout.writeln('完成：Android mipmap 与 Windows app_icon.ico 已生成。');
  stdout.writeln('再次生成：替换 icon/source_icon.png 后重跑本脚本即可。');
}

/// 从脚本位置向上查找项目根目录（含 pubspec.yaml 的目录）。
Directory _findProjectRoot() {
  var dir = File(Platform.script.toFilePath()).parent;
  while (true) {
    if (File('${dir.path}${Platform.pathSeparator}pubspec.yaml').existsSync()) {
      return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('未找到 pubspec.yaml，无法定位项目根目录');
    }
    dir = parent;
  }
}

/// 居中裁切为正方形（取短边）。
img.Image _centerSquare(img.Image image) {
  final side = image.width < image.height ? image.width : image.height;
  final x = (image.width - side) ~/ 2;
  final y = (image.height - side) ~/ 2;
  return img.copyCrop(image, x: x, y: y, width: side, height: side);
}

/// 为 Windows 图标应用透明圆角（Android 由系统启动器统一裁切，无需处理）。
///
/// 用圆角矩形符号距离场（SDF）逐像素计算覆盖率：边界 1px 软过渡实现抗锯齿。
/// [radiusFraction] 为圆角半径占边长的比例。
img.Image _applyRoundedCorners(
  img.Image image, {
  double radiusFraction = 0.22,
}) {
  final w = image.width;
  final h = image.height;
  final radius = radiusFraction * w;
  // 确保带 alpha 通道（convert 返回新图，缺失的 alpha 默认填满 255）。
  image = image.convert(numChannels: 4);

  // 圆角矩形 SDF（Inigo Quilez）：内部为负、外部为正、边界为 0。
  final cx = (w - 1) / 2;
  final cy = (h - 1) / 2;
  final halfW = w / 2 - radius;
  final halfH = h / 2 - radius;
  for (final p in image) {
    // 像素中心坐标（+0.5）相对图像中心。
    final qx = (p.x + 0.5 - cx).abs() - halfW;
    final qy = (p.y + 0.5 - cy).abs() - halfH;
    final ax = math.max(qx, 0);
    final ay = math.max(qy, 0);
    final dist = math.sqrt(ax * ax + ay * ay) +
        math.min(math.max(qx, qy), 0) -
        radius;
    // 距边界 0.5px 内线性过渡 → 抗锯齿；外部为 0（透明）。
    final alpha = (0.5 - dist).clamp(0.0, 1.0);
    if (alpha < 1.0) {
      p.a = (p.a * alpha).round();
    }
  }
  return image;
}

void _generateAndroidIcons(Directory root, img.Image square) {
  final resDir = ['android', 'app', 'src', 'main', 'res'].join(
    Platform.pathSeparator,
  );
  for (final entry in _kAndroidDensities.entries) {
    final resized = img.copyResize(
      square,
      width: entry.value,
      height: entry.value,
      interpolation: img.Interpolation.cubic,
    );
    final file = File(
      '${root.path}${Platform.pathSeparator}$resDir'
      '${Platform.pathSeparator}mipmap-${entry.key}'
      '${Platform.pathSeparator}ic_launcher.png',
    );
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(img.encodePng(resized));
    stdout.writeln(
      '[Android] ${entry.key} ${entry.value}×${entry.value}px '
      '→ ${file.path}',
    );
  }
}

void _generateWindowsIco(Directory root, img.Image square) {
  final file = File(
    '${root.path}${Platform.pathSeparator}windows'
    '${Platform.pathSeparator}runner${Platform.pathSeparator}resources'
    '${Platform.pathSeparator}app_icon.ico',
  );
  file.parent.createSync(recursive: true);
  // 顶层 encodeIco 只接受单张 ≤256px 的图；用 IcoEncoder.encodeImages
  // 将各尺寸图片打包为多分辨率 ICO（PNG-in-ICO，Windows Vista+ 支持）。
  // 每个尺寸均应用透明圆角（Windows 图标惯例；Android 不处理）。
  final images = <img.Image>[
    for (final size in _kWindowsIconSizes)
      _applyRoundedCorners(
        img.copyResize(
          square,
          width: size,
          height: size,
          interpolation: img.Interpolation.average,
        ),
      ),
  ];
  final ico = img.IcoEncoder().encodeImages(images);
  file.writeAsBytesSync(ico);
  stdout.writeln(
    '[Windows] 多尺寸 ICO（${_kWindowsIconSizes.join('/')}）→ ${file.path}',
  );
}
