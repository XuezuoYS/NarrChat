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

  /// 从 GitHub Release 响应 JSON 解析，字段缺失/类型不符时安全兜底
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
      publishedAt: json['published_at'] is String
          ? json['published_at'] as String
          : null,
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

/// 仓库从未发布任何 Release（GitHub API 返回 404，或发布列表为空）。
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
///
/// 版本号按 README「版本号规范」判断：`a.b.c` 是正式版，
/// `a.b.c-beta.d` / `a.b.c-rc.d` 是测试版。正式版与测试版只看 tag 的版本号
/// 形态（不看 GitHub 的 `prerelease` 标记），这样发布时忘了勾「预发布」
/// 也不会把测试版推给只查正式版的用户。两个取数接口的取舍：
/// - 默认只认正式版：先请求 `releases/latest`；万一 latest 返回测试版
///   （发布方没勾「预发布」时会发生），再回退 `releases` 列表挑最高正式版；
/// - 勾选「包含预发布版本」：直接请求 `releases` 列表，正式版与测试版一起
///   按版本号挑最高。
class UpdateCheckService {
  /// 默认仓库（`owner/repo`）。
  static const String defaultRepoSlug = 'XuezuoYS/NarrChat';

  /// 请求超时（超时归为失败，不阻塞启动流程太久）。
  static const Duration requestTimeout = Duration(seconds: 8);

  /// 发布列表每页条数（列表接口默认 30 条；近期版本足够覆盖，
  /// 避免把大段发布说明整页拉下来）。
  static const int releaseListLimit = 30;

  UpdateCheckService({http.Client? client, String repoSlug = defaultRepoSlug})
    : _client = client ?? http.Client(),
      _latestUrl = 'https://api.github.com/repos/$repoSlug/releases/latest',
      _releasesUrl =
          'https://api.github.com/repos/$repoSlug/releases'
          '?per_page=$releaseListLimit',
      _pageUrl = 'https://github.com/$repoSlug/releases';

  final http.Client _client;
  final String _latestUrl;
  final String _releasesUrl;
  final String _pageUrl;

  /// 查询最新版本并与 [currentVersion]（本地 `release.yaml` 的 version）比较。
  ///
  /// - 远端更高 → [UpdateAvailable]；
  /// - 远端相同或更低 / 本地版本号不合规范 → [UpToDate]（不打扰用户）；
  /// - 仓库无任何发布（HTTP 404 / 空列表）→ [NoRelease]（静默）；
  /// - 当前渠道暂无可用版本（如只发布了测试版但没勾选）→ [UpToDate]；
  /// - 响应异常 / tag 不合版本号规范 → [CheckFailed]（含中文原因）。
  ///
  /// [includePrerelease]：是否把测试版（`-beta.d` / `-rc.d`）纳入检查。
  /// 默认 `false` 只认正式版，`true` 时与正式版一起按版本号挑最高。
  ///
  /// [forceShow]：调试用「强制演示」模式——即使远端版本相同或更旧也返回
  /// [UpdateAvailable]（调试菜单「触发检查更新提示框」使用；默认 `false`
  /// 保持生产「不打扰」语义，提示框仅展示已获取到的远端信息）。
  Future<UpdateCheckResult> check({
    required String currentVersion,
    bool forceShow = false,
    bool includePrerelease = false,
  }) async {
    try {
      final lookup = includePrerelease
          ? await _lookupFromList(formalOnly: false)
          : await _lookupLatestFormal();
      late final GitHubRelease release;
      late final AppVersion remote;
      switch (lookup) {
        case _LookupResult(:final result):
          return result;
        case _FoundRelease(release: final found, version: final foundVersion):
          release = found;
          remote = foundVersion;
      }
      final local = AppVersion.tryParse(currentVersion);
      // 本地版本号无法解析时按"已是最新"处理：宁可少打扰，不可误报。
      // forceShow：调试强制演示，跳过版本比较直接返回 UpdateAvailable。
      if (!forceShow && (local == null || remote.compareTo(local) <= 0)) {
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

  /// 发一次 GitHub API 请求（统一请求头与超时）。
  Future<http.Response> _get(Uri url) {
    return _client
        .get(
          url,
          // GitHub API 强制 User-Agent（缺失返回 403）；Accept 指定 vnd.github 响应。
          headers: const {
            'Accept': 'application/vnd.github+json',
            'User-Agent': 'NarrChat',
          },
        )
        .timeout(requestTimeout);
  }

  /// 请求 `/releases/latest`，拿到最新正式版；若它返回测试版则回退列表。
  ///
  /// latest 接口理论上只含正式版；发布方没把测试版标记为「预发布」时，
  /// 它会返回带 `-beta/-rc` 后缀的 tag。这时改拉列表，按版本号只挑正式版。
  Future<_ReleaseLookup> _lookupLatestFormal() async {
    final response = await _get(Uri.parse(_latestUrl));
    final statusResult = _resultForStatus(response.statusCode);
    if (statusResult != null) return _LookupResult(statusResult);
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      return const _LookupResult(CheckFailed('GitHub API 响应格式异常'));
    }
    final latest = GitHubRelease.fromJson(decoded, fallbackPageUrl: _pageUrl);
    final version = AppVersion.tryParse(latest.tagVersion);
    if (version == null) {
      return const _LookupResult(CheckFailed('GitHub API 版本号无法解析'));
    }
    if (version.isPrerelease) return _lookupFromList(formalOnly: true);
    return _FoundRelease(latest, version);
  }

  /// 请求 `/releases` 列表，按版本号挑最高。
  ///
  /// 列表按发布时间倒序，但时间顺序未必等于版本高低（可能补发旧线补丁），
  /// 所以逐个比较版本号取最高。跳过草稿与不合规范的 tag。
  /// [formalOnly] 为 true 时只挑正式版（没有 `-beta.d` / `-rc.d` 后缀）。
  Future<_ReleaseLookup> _lookupFromList({required bool formalOnly}) async {
    final response = await _get(Uri.parse(_releasesUrl));
    final statusResult = _resultForStatus(response.statusCode);
    if (statusResult != null) return _LookupResult(statusResult);
    final decoded = jsonDecode(response.body);
    if (decoded is! List) {
      return const _LookupResult(CheckFailed('GitHub API 响应格式异常'));
    }
    if (decoded.isEmpty) return const _LookupResult(NoRelease());

    GitHubRelease? newest;
    AppVersion? newestVersion;
    var parsedAny = false;
    for (final item in decoded) {
      if (item is! Map<String, dynamic>) continue;
      if (item['draft'] == true) continue;
      final release = GitHubRelease.fromJson(item, fallbackPageUrl: _pageUrl);
      final version = AppVersion.tryParse(release.tagVersion);
      if (version == null) continue;
      parsedAny = true;
      if (formalOnly && version.isPrerelease) continue;
      if (newestVersion == null || version.compareTo(newestVersion) > 0) {
        newest = release;
        newestVersion = version;
      }
    }
    if (!parsedAny) {
      return const _LookupResult(CheckFailed('GitHub API 版本号无法解析'));
    }
    if (newest == null || newestVersion == null) {
      // 有版本号但没有当前渠道可用的（如只发了测试版却没勾选）。
      return const _LookupResult(UpToDate());
    }
    return _FoundRelease(newest, newestVersion);
  }

  /// 非 200 响应的统一归类；200 返回 `null` 表示继续解析响应体。
  UpdateCheckResult? _resultForStatus(int status) {
    if (status == 200) return null;
    if (status == 404) return const NoRelease();
    if (status == 403) {
      return const CheckFailed('GitHub API 访问受限（HTTP 403，可能是未登录限流）');
    }
    return CheckFailed('GitHub API 请求失败（HTTP $status）');
  }
}

/// 取数阶段的结果：已经拿到远端发布，或提前得到检查结论。
sealed class _ReleaseLookup {
  const _ReleaseLookup();
}

/// 成功拿到一个远端发布及其解析后的版本号。
class _FoundRelease extends _ReleaseLookup {
  const _FoundRelease(this.release, this.version);

  final GitHubRelease release;
  final AppVersion version;
}

/// 无需再比较版本，直接返回的结论（[NoRelease] / [CheckFailed] / [UpToDate]）。
class _LookupResult extends _ReleaseLookup {
  const _LookupResult(this.result);

  final UpdateCheckResult result;
}
