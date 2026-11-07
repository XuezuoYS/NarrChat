import 'package:url_launcher/url_launcher.dart';

/// 外部链接打开器：交给系统默认浏览器 / 关联应用处理。
///
/// 返回值语义：`true` 表示系统已接住并打开了链接；`false` 表示没打开
/// （系统无可用浏览器、或平台层直接拒绝），调用方可据此退化成
/// 「复制链接」并提示用户。
typedef ExternalLinkOpener = Future<bool> Function(Uri url);

/// 用系统默认浏览器打开 [url]（设置页「关于」→ GitHub 仓库使用）。
///
/// 平台层抛错（如缺少插件实现）也统一按「没打开」处理：链接类操作失败
/// 不应打断页面，交给调用方提示即可。
Future<bool> openExternalLink(Uri url) async {
  try {
    return await launchUrl(url, mode: LaunchMode.externalApplication);
  } catch (_) {
    return false;
  }
}
