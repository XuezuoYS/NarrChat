import 'dart:convert';

import '../../utils/timestamp_format.dart';
import 'backup_digest.dart';
import 'backup_unit.dart';

/// 云端清单（`manifest_<基名>.json`）的内容。
///
/// 每个库一份，记录：代数、保存时间、内容摘要、设备 id、内容时间、引用图片。
/// - **清单不存在** = 这个库还没备份过（写第 1 代）；
/// - **清单损坏** = 停止备份并报错，绝不当空清单重新 bootstrap
///   （否则会把云端历史当不存在，用本地旧数据覆盖别人的新数据）。
class BackupManifest {
  const BackupManifest({
    required this.unitKey,
    required this.kind,
    required this.refUuid,
    required this.generation,
    required this.digest,
    required this.snapshotName,
    required this.savedAt,
    this.deviceId = '',
    this.contentUpdatedAt = '',
    this.latestRoundIndex = 0,
    this.roundGenerationCount = 0,
    this.images = const [],
    this.digestVersion = backupDigestVersion,
  });

  final String unitKey;
  final BackupUnitKind kind;
  final String refUuid;

  /// 代数：同一个库每推一次 +1，各库独立。
  final int generation;

  /// 规范化内容摘要（sha256，见 `backup_digest.dart`）。
  final String digest;

  /// 摘要算法版本；不一致时不做摘要比对（当作冲突让用户裁决）。
  final int digestVersion;

  /// 这一代对应的云端快照文件名。
  final String snapshotName;

  /// 写入清单的时间（R3 标准时间戳）。
  final String savedAt;

  /// 推送它的设备标识。
  final String deviceId;

  /// 推送时书籍 `book_meta.updated_at`（冲突默认裁决用；library / mods 为空）。
  final String contentUpdatedAt;

  /// 这一代的最新轮号（0 = 未知 / 空书）。
  ///
  /// 与 [roundGenerationCount] 一起，供其它设备做冲突 PK；旧版清单没有这两个
  /// 字段，解析为 0，PK 时按「未知」处理（交给人决定）。
  final int latestRoundIndex;

  /// 这一代的全书代数：`round_stack` 的行数（0 = 未知 / 空书）。
  final int roundGenerationCount;

  /// 这一代引用到的图片相对路径（还原这本书时顺带把图拉下来）。
  final List<String> images;

  Map<String, Object?> toJson() => {
        'unitKey': unitKey,
        'kind': kind.name,
        'refUuid': refUuid,
        'generation': generation,
        'digest': digest,
        'digestVersion': digestVersion,
        'snapshotName': snapshotName,
        'savedAt': savedAt,
        'deviceId': deviceId,
        'contentUpdatedAt': contentUpdatedAt,
        'latestRoundIndex': latestRoundIndex,
        'roundGenerationCount': roundGenerationCount,
        'images': images,
      };

  /// 解析清单；结构不对直接抛 [BackupManifestException]。
  factory BackupManifest.fromJson(Map<String, Object?> json) {
    final unitKey = json['unitKey'];
    final generation = json['generation'];
    final digest = json['digest'];
    final snapshotName = json['snapshotName'];
    if (unitKey is! String || unitKey.isEmpty) {
      throw const BackupManifestException('清单缺少 unitKey');
    }
    if (generation is! num || generation < 0) {
      throw BackupManifestException('清单代数非法：$generation');
    }
    if (digest is! String || digest.isEmpty) {
      throw const BackupManifestException('清单缺少内容摘要');
    }
    if (snapshotName is! String || snapshotName.isEmpty) {
      throw const BackupManifestException('清单缺少快照文件名');
    }
    final images = json['images'];
    final kindRaw = json['kind'];
    return BackupManifest(
      unitKey: unitKey,
      kind: _parseKind(kindRaw, unitKey),
      refUuid: (json['refUuid'] as String?) ?? '',
      generation: generation.toInt(),
      digest: digest,
      digestVersion: (json['digestVersion'] as num?)?.toInt() ?? 0,
      snapshotName: snapshotName,
      savedAt: (json['savedAt'] as String?) ?? '',
      deviceId: (json['deviceId'] as String?) ?? '',
      contentUpdatedAt: (json['contentUpdatedAt'] as String?) ?? '',
      latestRoundIndex: (json['latestRoundIndex'] as num?)?.toInt() ?? 0,
      roundGenerationCount:
          (json['roundGenerationCount'] as num?)?.toInt() ?? 0,
      images: images is List
          ? images.map((e) => e.toString()).toList()
          : const [],
    );
  }

  /// 从字节解析；JSON 非法同样抛 [BackupManifestException]。
  static BackupManifest decode(List<int> bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const BackupManifestException('清单不是 JSON 对象');
      }
      return BackupManifest.fromJson(
        decoded.map((key, value) => MapEntry(key.toString(), value)),
      );
    } on BackupManifestException {
      rethrow;
    } catch (error) {
      throw BackupManifestException('清单无法解析：$error');
    }
  }

  List<int> encode() => utf8.encode(jsonEncode(toJson()));

  static BackupUnitKind _parseKind(Object? raw, String unitKey) {
    switch (raw) {
      case 'library':
        return BackupUnitKind.library;
      case 'mods':
        return BackupUnitKind.mods;
      case 'book':
        return BackupUnitKind.book;
    }
    // 老清单 / 手改过的清单：按 unitKey 兜底推断。
    if (unitKey == 'library') return BackupUnitKind.library;
    if (unitKey == 'mods') return BackupUnitKind.mods;
    return BackupUnitKind.book;
  }

  BackupManifest copyWith({
    int? generation,
    String? digest,
    String? snapshotName,
    String? savedAt,
    String? deviceId,
    String? contentUpdatedAt,
    int? latestRoundIndex,
    int? roundGenerationCount,
    List<String>? images,
  }) {
    return BackupManifest(
      unitKey: unitKey,
      kind: kind,
      refUuid: refUuid,
      generation: generation ?? this.generation,
      digest: digest ?? this.digest,
      digestVersion: digestVersion,
      snapshotName: snapshotName ?? this.snapshotName,
      savedAt: savedAt ?? this.savedAt,
      deviceId: deviceId ?? this.deviceId,
      contentUpdatedAt: contentUpdatedAt ?? this.contentUpdatedAt,
      latestRoundIndex: latestRoundIndex ?? this.latestRoundIndex,
      roundGenerationCount: roundGenerationCount ?? this.roundGenerationCount,
      images: images ?? this.images,
    );
  }

  /// 组装一份新清单（推送时用）。
  static BackupManifest build({
    required BackupUnit unit,
    required int generation,
    required String digest,
    required String deviceId,
    DateTime? savedAt,
    DateTime? contentUpdatedAt,
    int latestRoundIndex = 0,
    int roundGenerationCount = 0,
    List<String> images = const [],
  }) {
    final now = (savedAt ?? DateTime.now()).toUtc();
    return BackupManifest(
      unitKey: unit.unitKey,
      kind: unit.kind,
      refUuid: unit.refUuid,
      generation: generation,
      digest: digest,
      snapshotName: unit.snapshotName(generation),
      savedAt: formatTimestamp(now),
      deviceId: deviceId,
      contentUpdatedAt: contentUpdatedAt == null
          ? formatTimestamp(now)
          : formatTimestamp(contentUpdatedAt),
      latestRoundIndex: latestRoundIndex,
      roundGenerationCount: roundGenerationCount,
      images: images,
    );
  }
}

/// 清单损坏（存在但读不懂）。
///
/// 遇到它必须**停止备份并报错**：这时把云端当空的多半会用本地旧数据覆盖
/// 另一台设备刚推上来的内容。
class BackupManifestException implements Exception {
  const BackupManifestException(this.message);

  final String message;

  @override
  String toString() => 'BackupManifestException: $message';
}
