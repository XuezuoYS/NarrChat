import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:http/http.dart' as http;

import '../utils/app_version.dart';

/// GitHub Release 摘要信息（「发现新版本」对话框展示用）。
class GitHubRelease {
  const GitHubRelease({
    required this.tagVersion,
    required this.displayName,
    required this.pageUrl,
    required this.notes,
    this.publishedAt,
  });

  /// 从 `releases/latest` 响应 JSON 解析，字段缺失/类型不符时安全兜底
  /// （tag 缺失 → 空串，后续比较会归为失败；展示字段缺失 → 空串/`null`）。
  ///
  /// [fallbackPageUrl]：API 未返回 `html_url` 时使用（仓库 Releases 页）。
  factory GitHubRelease.fromJson(
    Map<String, dynamic> json, {
    required String fallbackPageUrl,
  }) {
    String text(String key) => json[key] is String ? json[key] as String : '';
    final tag = text('tag_name');
    final name = text('name');
    return GitHubRelease(
      tagVersion: tag,
      displayName: name.isEmpty ? tag : name,
      pageUrl: text('html_url').isEmpty ? fallbackPageUrl : text('html_url'),
      notes: text('body'),
      publishedAt:
          json['published_at'] is String ? json['published_at'] as String : null,
    );
  }

  /// GitHub 发布的 tag 名（如 `v1.4.0`）。
  final String tagVersion;

  /// Release 标题（`name`；为空时回退为 [tagVersion]）。
  final String displayName;

  /// Release 页面地址（优先 API 的 `html_url`，缺失时用仓库 Releases 页）。
  final String pageUrl;

  /// Release 发布说明（`body`，Markdown 文本；可为空串）。
  final String notes;

  /// 发布时间（ISO8601 字符串；缺失为 `null`）。
  final String? publishedAt;
}

/// 检查更新结果（sealed：调用方只需 switch 分支，不感知网络细节）。
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

/// 本地已是最新（远端无更高版本）。
class UpToDate extends UpdateCheckResult {
  const UpToDate();
}

/// 远端存在更高版本，[release] 为最新版本信息。
class UpdateAvailable extends UpdateCheckResult {
  const UpdateAvailable(this.release);

  final GitHubRelease release;
}

/// 仓库从未发布任何 Release（GitHub API 返回 404）。
class NoRelease extends UpdateCheckResult {
  const NoRelease();
}

/// 检查失败（网络 / 限流 / 响应异常），[reason] 为面向用户的中文描述。
class CheckFailed extends UpdateCheckResult {
  const CheckFailed(this.reason);

  final String reason;
}

/// GitHub Releases 更新检查服务（网络 + 解析 + 版本比较）。
///
/// 「注入 `http.Client`」写法与 `AiService` / `HtmlSearchService` 一致：
/// 测试传 `MockClient`，生产默认真实客户端。
/// 对外承诺**不抛异常**：所有失败收敛为 [CheckFailed]，调用方只分支结果。
class UpdateCheckService {
  /// 默认仓库（`owner/repo`）。
  static const String defaultRepoSlug = 'XuezuoYS/NarrChat';

  /// 请求超时（超时归为失败，不阻塞启动流程太久）。
  static const Duration requestTimeout = Duration(seconds: 8);

  UpdateCheckService({http.Client? client, String repoSlug = defaultRepoSlug})
      : _client = client ?? http.Client(),
        _apiUrl = 'https://api.github.com/repos/$repoSlug/releases/latest',
        _pageUrl = 'https://github.com/$repoSlug/releases';

  final http.Client _client;
  final String _apiUrl;
  final String _pageUrl;

  /// 查询最新版本并与 [currentVersion]（本地 `release.yaml` 的 version）比较。
  ///
  /// - 远端更高 → [UpdateAvailable]；
  /// - 远端相同或更低 / 本地版本无法解析 → [UpToDate]（不打扰用户）；
  /// - 仓库无任何发布（HTTP 404）→ [NoRelease]（静默）；
  /// - 其余异常 → [CheckFailed]（含面向用户的中文原因）。
  Future<UpdateCheckResult> check({required String currentVersion}) async {
    try {
      final response = await _client
          .get(
            Uri.parse(_apiUrl),
            // GitHub API 强制 User-Agent（缺失返回 403）；Accept 指定 vnd.github 响应。
            headers: const {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'NarrChat',
            },
          )
          .timeout(requestTimeout);
      if (response.statusCode == 404) return const NoRelease();
      if (response.statusCode == 403) {
        return const CheckFailed(
          'GitHub API 访问受限（HTTP 403，可能是未登录限流）',
        );
      }
      if (response.statusCode != 200) {
        return CheckFailed('GitHub API 请求失败（HTTP ${response.statusCode}）');
      }
      final decoded = jsonDecode(response.body);
      if (decoded is! Map<String, dynamic>) {
        return const CheckFailed('GitHub API 响应格式异常');
      }
      final release = GitHubRelease.fromJson(
        decoded,
        fallbackPageUrl: _pageUrl,
      );
      final remote = AppVersion.tryParse(release.tagVersion);
      if (remote == null) {
        return const CheckFailed('GitHub API 版本号无法解析');
      }
      final local = AppVersion.tryParse(currentVersion);
      // 本地版本号未知时按"已是最新"处理：宁可少打扰，不可误报。
      if (local != null && remote.compareTo(local) <= 0) {
        return const UpToDate();
      }
      return UpdateAvailable(release);
    } on TimeoutException {
      return const CheckFailed('网络请求超时');
    } on SocketException catch (e) {
      return CheckFailed('网络请求失败：${e.message}');
    } on http.ClientException catch (e) {
      return CheckFailed('网络请求失败：${e.message}');
    } on FormatException {
      return const CheckFailed('GitHub API 响应格式异常');
    } catch (e) {
      return CheckFailed('网络请求失败：$e');
    }
  }
}
