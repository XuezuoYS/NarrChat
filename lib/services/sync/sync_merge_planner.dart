import 'sync_local_snapshot.dart';

/// 三向部件级合并规划器（纯逻辑，不写库、不联网）。
///
/// 输入是**指纹级**快照：本机共基（`sync_book_base`）、本地现状、远端 manifest，
/// 全部以 **uuid** 为键（跨设备身份）。title / name 仅作展示与回退匹配：
/// - 同一 uuid 在三侧出现 → 按 uuid 精确对齐；
/// - 某侧 uuid 缺失或不同（旧版 format=1 清单、首连双端、手动合并后"保留本地"
///   的过渡态）→ 按 title / name **唯一**匹配回退（每侧恰一个候选）；
///   不唯一（同名多书/多 Mod）→ 不链接，按各自实体独立判定（冲突场景走人工）。
///
/// 输出每个书 / Mod 的部件级决策，供同步服务决定：
/// - 哪些部件可**自动**采用某侧（localOnly / remoteOnly）；
/// - 哪些部件是**真冲突**（local 与 remote 都改过 base）→ 需要进入合并决策页；
/// - 整本书的存在性（只本地 / 只远端 / 删除传播）。
///
/// 合并判据=内容指纹，**时间戳不作为合并依据**（仅用于决策页的建议）。
class SyncMergePlanner {
  SyncMergePlanner._();

  /// 计算三向部件级合并规划。
  static SyncMergePlan plan({
    required Map<String, SyncBookBaseParts> base,
    required Map<String, SyncBookRecord> local,
    required Map<String, RemoteBookParts> remote,
    required Map<String, SyncModRecord> localMods,
    required Map<String, RemoteModParts> remoteMods,
    required Map<String, SyncModBaseParts> baseMods,
  }) {
    final bookDecisions = <BookSyncDecision>[];
    for (final party in _groupBooks(base: base, local: local, remote: remote)) {
      final bv = party.base;
      final lv = party.local;
      final rv = party.remote;

      final localPresent = lv != null && !lv.parts.deleted;
      final remotePresent = rv != null && !rv.deleted;
      final basePresent = bv != null;

      final SyncBookPresence presence;
      SyncPartStatus settings = SyncPartStatus.unchanged;
      SyncPartStatus rounds = SyncPartStatus.unchanged;
      SyncPartStatus worldBook = SyncPartStatus.unchanged;
      SyncPartStatus bookMods = SyncPartStatus.unchanged;

      if (localPresent && remotePresent) {
        presence = SyncBookPresence.both;
        settings =
            _classify(bv?.settingsFp ?? '', lv.parts.settingsFp, rv.settingsFp, basePresent);
        rounds = _classify(bv?.roundsFp ?? '', lv.parts.roundsFp, rv.roundsFp, basePresent);
        worldBook =
            _classify(bv?.worldBookFp ?? '', lv.parts.worldBookFp, rv.worldBookFp, basePresent);
        bookMods =
            _classify(bv?.bookModsFp ?? '', lv.parts.bookModsFp, rv.bookModsFp, basePresent);
      } else if (localPresent && !remotePresent) {
        presence = basePresent
            ? (_unchangedSinceBase(bv, lv.parts) == true
                ? SyncBookPresence.deletedOnRemote
                : SyncBookPresence.deletionConflict)
            : SyncBookPresence.localOnly;
      } else if (!localPresent && remotePresent) {
        presence = basePresent
            ? (_unchangedSinceBase(bv, remoteToParts(rv)) == true
                ? SyncBookPresence.deletedOnLocal
                : SyncBookPresence.deletionConflict)
            : SyncBookPresence.remoteOnly;
      } else {
        presence = SyncBookPresence.none;
      }

      bookDecisions.add(
        BookSyncDecision(
          localUuid: lv?.uuid,
          remoteUuid: rv?.uuid,
          title: lv?.title ?? rv?.title ?? bv?.title ?? '',
          presence: presence,
          settings: settings,
          rounds: rounds,
          worldBook: worldBook,
          bookMods: bookMods,
        ),
      );
    }

    // Mod 规划（单部件）。
    final modDecisions = <ModSyncDecision>[];
    for (final party in _groupMods(
      base: baseMods,
      local: localMods,
      remote: remoteMods,
    )) {
      final bfp = party.base?.fingerprint;
      final lfp = party.local?.fingerprint;
      final rfp = party.remote?.fingerprint;
      final basePresent = bfp != null;
      final lDeleted = lfp == null;
      final rDeleted = rfp == null;
      final SyncModStatus status;
      if (!basePresent) {
        if (lfp != null && rfp != null && lfp == rfp) {
          status = SyncModStatus.unchanged;
        } else if (lfp != null && rfp == null) {
          status = SyncModStatus.localOnly;
        } else if (lfp == null && rfp != null) {
          status = SyncModStatus.remoteOnly;
        } else if (lfp == null && rfp == null) {
          status = SyncModStatus.absent;
        } else {
          status = SyncModStatus.conflict;
        }
      } else if (lDeleted && rDeleted) {
        status = SyncModStatus.absent;
      } else if (lDeleted && !rDeleted) {
        status = SyncModStatus.deletedOnLocal;
      } else if (!lDeleted && rDeleted) {
        status = SyncModStatus.deletedOnRemote;
      } else if (lfp == bfp && rfp == bfp) {
        status = SyncModStatus.unchanged;
      } else if (rfp == bfp) {
        status = SyncModStatus.localOnly;
      } else if (lfp == bfp) {
        status = SyncModStatus.remoteOnly;
      } else {
        status = SyncModStatus.conflict;
      }
      modDecisions.add(
        ModSyncDecision(
          localUuid: party.local?.uuid,
          remoteUuid: party.remote?.uuid,
          name: party.local?.name ?? party.remote?.name ?? party.base?.name ?? '',
          status: status,
        ),
      );
    }

    return SyncMergePlan(books: bookDecisions, mods: modDecisions);
  }

  static SyncPartStatus _classify(
    String baseFp,
    String localFp,
    String remoteFp,
    bool basePresent,
  ) {
    final localSame = localFp == baseFp;
    final remoteSame = remoteFp == baseFp;
    if (!basePresent) {
      return localSame && remoteSame
          ? SyncPartStatus.unchanged
          : SyncPartStatus.conflict;
    }
    if (localSame && remoteSame) return SyncPartStatus.unchanged;
    if (!localSame && remoteSame) return SyncPartStatus.localOnly;
    if (localSame && !remoteSame) return SyncPartStatus.remoteOnly;
    return SyncPartStatus.conflict;
  }

  static bool? _unchangedSinceBase(SyncBookBaseParts b, SyncBookParts p) {
    return b.settingsFp == p.settingsFp &&
        b.roundsFp == p.roundsFp &&
        b.worldBookFp == p.worldBookFp &&
        b.bookModsFp == p.bookModsFp;
  }

  static SyncBookParts remoteToParts(RemoteBookParts r) => SyncBookParts(
        deleted: r.deleted,
        settingsFp: r.settingsFp,
        roundsFp: r.roundsFp,
        worldBookFp: r.worldBookFp,
        bookModsFp: r.bookModsFp,
      );

  // ---------------------------------------------------------------------------
  // 身份分组：uuid 精确匹配 + title/name 唯一回退
  // ---------------------------------------------------------------------------

  static List<_BookParty> _groupBooks({
    required Map<String, SyncBookBaseParts> base,
    required Map<String, SyncBookRecord> local,
    required Map<String, RemoteBookParts> remote,
  }) {
    final localByTitle = _unambiguous(local, (r) => r.title);
    final remoteByTitle = _unambiguous(remote, (r) => r.title);
    final baseByTitle = _unambiguous(base, (b) => b.title);

    final groups = _linkGroups(
      namesOf: {
        'local': localByTitle,
        'remote': remoteByTitle,
        'base': baseByTitle,
      },
      uuids: {...base.keys, ...local.keys, ...remote.keys},
    );

    return [
      for (final uuids in groups.values)
        _BookParty(
          base: _firstOf(base, uuids),
          local: _firstOf(local, uuids),
          remote: _firstOf(remote, uuids),
        ),
    ];
  }

  static List<_ModParty> _groupMods({
    required Map<String, SyncModBaseParts> base,
    required Map<String, SyncModRecord> local,
    required Map<String, RemoteModParts> remote,
  }) {
    final localByName = _unambiguous(local, (r) => r.name);
    final remoteByName = _unambiguous(remote, (r) => r.name);
    final baseByName = _unambiguous(base, (b) => b.name);

    final groups = _linkGroups(
      namesOf: {
        'local': localByName,
        'remote': remoteByName,
        'base': baseByName,
      },
      uuids: {...base.keys, ...local.keys, ...remote.keys},
    );

    return [
      for (final uuids in groups.values)
        _ModParty(
          base: _firstOf(base, uuids),
          local: _firstOf(local, uuids),
          remote: _firstOf(remote, uuids),
        ),
    ];
  }

  /// 名称 → uuid 的唯一映射（该名称在源 Map 中出现多次则整个跳过）。
  static Map<String, String> _unambiguous<K, V>(
    Map<K, V> source,
    String Function(V) nameOf,
  ) {
    final result = <String, String>{};
    final count = <String, int>{};
    for (final e in source.entries) {
      final name = nameOf(e.value).trim();
      if (name.isEmpty) continue;
      count[name] = (count[name] ?? 0) + 1;
      result[name] = e.key.toString();
    }
    // 同名多候选 → 撤销该名称的链接（按独立实体判定）。
    return {
      for (final e in count.entries)
        if (e.value == 1) e.key: result[e.key]!,
    };
  }

  /// 书名/Mod 名唯一回退链接：同一名称在 ≥2 侧各有一个候选 → 并成一个实体。
  ///
  /// 并查集实现；[namesOf] 的值为"名称 → 各侧唯一 uuid"。
  static Map<String, List<String>> _linkGroups({
    required Map<String, Map<String, String>> namesOf,
    required Set<String> uuids,
  }) {
    final parent = <String, String>{for (final u in uuids) u: u};
    String find(String x) {
      var r = x;
      while (parent[r] != r) {
        r = parent[r]!;
      }
      // 路径压缩。
      var cur = x;
      while (parent[cur] != cur) {
        final next = parent[cur]!;
        parent[cur] = r;
        cur = next;
      }
      return r;
    }

    void union(String a, String b) {
      final ra = find(a);
      final rb = find(b);
      if (ra != rb) parent[rb] = ra;
    }

    final names = <String>{};
    for (final m in namesOf.values) {
      names.addAll(m.keys);
    }
    for (final name in names) {
      final candidates = <String>{};
      for (final m in namesOf.values) {
        final u = m[name];
        if (u != null) candidates.add(u);
      }
      if (candidates.length >= 2) {
        final first = candidates.first;
        for (final u in candidates) {
          union(u, first);
        }
      }
    }

    final groups = <String, List<String>>{};
    for (final u in uuids) {
      groups.putIfAbsent(find(u), () => []).add(u);
    }
    return groups;
  }

  static V? _firstOf<K, V>(Map<K, V> source, List<String> uuids) {
    for (final u in uuids) {
      final v = source[u];
      if (v != null) return v;
    }
    return null;
  }
}

/// 单个部件的三向状态。
enum SyncPartStatus {
  unchanged, // local == base && remote == base
  localOnly, // local != base && remote == base → 自动用本地
  remoteOnly, // local == base && remote != base → 自动用远端
  conflict, // local != base && remote != base → 弹合并页
}

/// 一本书的存在性/整体走向。
enum SyncBookPresence {
  both, // 两端都存在（逐部件判定）
  localOnly, // 仅本地有 → 推送
  remoteOnly, // 仅远端有 → 拉取
  deletedOnRemote, // 本地有、远端删除了且本地未改 → 传播删除
  deletedOnLocal, // 远端有、本地删除了且远端未改 → 传播删除
  deletionConflict, // 删除 vs 修改冲突 → 弹窗
  none, // 两端都无 / 都删除
}

/// 一本书的部件级决策。
class BookSyncDecision {
  /// 本地侧的 uuid（存在时；用 f 落地本地删除/推送本地变更）。
  final String? localUuid;

  /// 远端侧的 uuid（存在时；拉取/远端删除用）。
  final String? remoteUuid;

  final String title;
  final SyncBookPresence presence;
  final SyncPartStatus settings;
  final SyncPartStatus rounds;
  final SyncPartStatus worldBook;
  final SyncPartStatus bookMods;

  const BookSyncDecision({
    required this.localUuid,
    required this.remoteUuid,
    required this.title,
    required this.presence,
    required this.settings,
    required this.rounds,
    required this.worldBook,
    required this.bookMods,
  });

  /// 是否任一部件是真冲突。
  bool get hasConflict =>
      presence == SyncBookPresence.deletionConflict ||
      settings == SyncPartStatus.conflict ||
      rounds == SyncPartStatus.conflict ||
      worldBook == SyncPartStatus.conflict ||
      bookMods == SyncPartStatus.conflict;
}

/// 单个 Mod 的三向状态（Mod 无子部件）。
enum SyncModStatus {
  unchanged,
  localOnly,
  remoteOnly,
  conflict,
  deletedOnRemote,
  deletedOnLocal,
  deletionConflict,
  absent,
}

class ModSyncDecision {
  final String? localUuid;
  final String? remoteUuid;
  final String name;
  final SyncModStatus status;

  const ModSyncDecision({
    required this.localUuid,
    required this.remoteUuid,
    required this.name,
    required this.status,
  });

  bool get isConflict =>
      status == SyncModStatus.conflict ||
      status == SyncModStatus.deletionConflict;
}

/// 本地一本书的部件指纹与删除标记。
class SyncBookParts {
  final bool deleted;
  final String settingsFp;
  final String roundsFp;
  final String worldBookFp;
  final String bookModsFp;

  const SyncBookParts({
    this.deleted = false,
    this.settingsFp = '',
    this.roundsFp = '',
    this.worldBookFp = '',
    this.bookModsFp = '',
  });
}

/// 合并规划结果。
class SyncMergePlan {
  final List<BookSyncDecision> books;
  final List<ModSyncDecision> mods;

  const SyncMergePlan({required this.books, this.mods = const []});

  List<BookSyncDecision> get conflictBooks =>
      books.where((b) => b.hasConflict).toList();

  bool get hasConflict => conflictBooks.isNotEmpty || mods.any((m) => m.isConflict);

  /// 汇总计数，供首连/决策页摘要展示。
  Map<String, int> summarize() {
    var push = 0, pull = 0, localDel = 0, remoteDel = 0, conflict = 0;
    for (final b in books) {
      switch (b.presence) {
        case SyncBookPresence.localOnly:
          push++;
        case SyncBookPresence.remoteOnly:
          pull++;
        case SyncBookPresence.deletedOnRemote:
          localDel++;
        case SyncBookPresence.deletedOnLocal:
          remoteDel++;
        case SyncBookPresence.both:
          if (b.hasConflict) conflict++;
        case SyncBookPresence.deletionConflict:
          conflict++;
        case SyncBookPresence.none:
          break;
      }
    }
    return {
      'push': push,
      'pull': pull,
      'deleteLocal': localDel,
      'deleteRemote': remoteDel,
      'conflict': conflict,
    };
  }
}

/// 共基部件指纹（对应 `sync_book_base`，uuid 为主键）。
class SyncBookBaseParts {
  final String title;
  final String settingsFp;
  final String roundsFp;
  final String worldBookFp;
  final String bookModsFp;

  const SyncBookBaseParts({
    this.title = '',
    this.settingsFp = '',
    this.roundsFp = '',
    this.worldBookFp = '',
    this.bookModsFp = '',
  });
}

/// 共基 Mod 部件（对应 `sync_mod_base`，uuid 为主键）。
class SyncModBaseParts {
  final String name;
  final String fingerprint;

  const SyncModBaseParts({this.name = '', this.fingerprint = ''});
}

/// 远端（manifest）一侧的书籍部件。
class RemoteBookParts {
  final String uuid;
  final String title;
  final bool deleted;
  final String settingsFp;
  final String roundsFp;
  final String worldBookFp;
  final String bookModsFp;

  const RemoteBookParts({
    this.uuid = '',
    this.title = '',
    this.deleted = false,
    this.settingsFp = '',
    this.roundsFp = '',
    this.worldBookFp = '',
    this.bookModsFp = '',
  });
}

/// 远端一个 Mod 的部件。
class RemoteModParts {
  final String uuid;
  final String name;
  final bool deleted;
  final String fingerprint;

  const RemoteModParts({
    this.uuid = '',
    this.name = '',
    this.deleted = false,
    this.fingerprint = '',
  });
}

/// 一个逻辑实体的三侧观测（uuid 回退分组后的结果）。
class _BookParty {
  final SyncBookBaseParts? base;
  final SyncBookRecord? local;
  final RemoteBookParts? remote;

  const _BookParty({this.base, this.local, this.remote});
}

class _ModParty {
  final SyncModBaseParts? base;
  final SyncModRecord? local;
  final RemoteModParts? remote;

  const _ModParty({this.base, this.local, this.remote});
}
