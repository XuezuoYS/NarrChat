// NarrChat 发布构建脚本（替代 build_release.bat）。
//
// 用法（在项目根目录执行）：
//   dart run tool/build_release.dart                # 交互菜单
//   dart run tool/build_release.dart --android      # 仅 Android（CI / 非交互）
//   dart run tool/build_release.dart --windows      # Windows（setup.exe 安装包 + ZIP 便携包）
//   dart run tool/build_release.dart --zip-only     # Windows 仅 ZIP 便携包
//   dart run tool/build_release.dart --all          # Android + Windows
//   dart run tool/build_release.dart --no-bump      # 跳过 build 号自增
//   dart run tool/build_release.dart --version 1.2.0  # 构建前设置版本号（x.y.z）
//
// 流程：
//   1. 读取 release.yaml（版本号唯一来源：version 显示用 / build = Android versionCode）
//   2. 选定构建目标后，第一步自动把 build 号 +1 写回 release.yaml，
//      并同步 pubspec.yaml 的 version 字段为 `{version}+{build}`
//   3. 执行 flutter build ...
//   4. 产物统一输出到 build/release/
//      - Android: NarrChat_{version}-{build}_android_arm64.apk
//      - Windows: NarrChat_{version}-{build}_windows_x64.zip
//                 + NarrChat_{version}-{build}_windows_x64-setup.exe（安装包）
//
// Windows 安装包依赖 Inno Setup（免费开源，https://jrsoftware.org/isdl.php）。
// 未安装时自动降级为仅产出 ZIP 便携包。
//
// 依赖：dev_dependencies 中的 archive 包（纯 Dart 打 ZIP，无需系统工具）。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

// ---------------------------------------------------------------------------
// 纯函数（可单元测试）
// ---------------------------------------------------------------------------

/// release.yaml 中解析出的版本信息。
class ReleaseConfig {
  const ReleaseConfig({required this.version, required this.build});

  /// 语义化版本号（显示用，如 1.2.3）。
  final String version;

  /// 构建号（Android versionCode）。
  final int build;
}

/// 从 release.yaml 文本中解析 `version` 与 `build`。
///
/// 轻量正则解析，不引入 yaml 依赖（与 lib/utils/release_info.dart 一致）。
/// 缺失 / 非法字段回退到 [defaultVersion] / [defaultBuild]。
ReleaseConfig parseReleaseYaml(
  String raw, {
  String defaultVersion = '1.0.0',
  int defaultBuild = 1,
}) {
  var version = defaultVersion;
  var build = defaultBuild;
  for (final line in raw.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
    final v = RegExp(r'^version\s*:\s*(\S+)').firstMatch(trimmed);
    if (v != null) {
      version = v.group(1)!;
      continue;
    }
    final b = RegExp(r'^build\s*:\s*(\d+)').firstMatch(trimmed);
    if (b != null) {
      build = int.tryParse(b.group(1)!) ?? build;
    }
  }
  return ReleaseConfig(version: version, build: build);
}

/// 更新 release.yaml 文本中的 `version` 字段为 [version]。
/// 保留其余内容与注释不变；未找到该行时原样返回。
String setVersionInYaml(String raw, String version) {
  final line = RegExp(r'^(\s*version\s*:\s*)\S+.*$', multiLine: true);
  if (!line.hasMatch(raw)) return raw;
  return raw.replaceAllMapped(line, (m) => '${m.group(1)}$version');
}

/// 把 release.yaml 文本中的 `build` 改为 [newBuild]（缺省为当前 build + 1）。
/// 保留其余内容与注释不变；未找到 `build` 行时在文件末尾追加。
String bumpBuildInYaml(String raw, {int? newBuild}) {
  final current = parseReleaseYaml(raw);
  final target = newBuild ?? current.build + 1;
  final line = RegExp(r'^(\s*build\s*:\s*)\d+\s*$', multiLine: true);
  if (line.hasMatch(raw)) {
    return raw.replaceAllMapped(line, (m) => '${m.group(1)}$target');
  }
  final sep = raw.endsWith('\n') ? '' : '\n';
  return '$raw${sep}build: $target\n';
}

/// 生成 pubspec.yaml 的 version 字段值（如 `1.2.3+8`）。
String buildPubspecVersion(String version, int build) => '$version+$build';

/// 同步 pubspec.yaml 中的 `version` 字段为 `{version}+{build}`。
/// 返回更新后的文本；未找到 `version` 行时原样返回。
String syncPubspecVersion(String pubspec, String version, int build) {
  final line = RegExp(r'^version\s*:\s*.*$', multiLine: true);
  if (!line.hasMatch(pubspec)) return pubspec;
  return pubspec
      .replaceAllMapped(line, (m) => 'version: ${buildPubspecVersion(version, build)}');
}

/// 生成发布产物的统一基础名，格式：`NarrChat_{version}-{build}_{device}_{arch}`。
///
/// 例如 `NarrChat_1.2.3-57_windows_x64`。
/// [device] 为目标设备（如 android / windows），[arch] 为架构（如 arm64 / x64）。
String artifactBaseName(
  ReleaseConfig config, {
  required String device,
  required String arch,
}) =>
    'NarrChat_${config.version}-${config.build}_${device}_$arch';

// ---------------------------------------------------------------------------
// 控制台输出
// ---------------------------------------------------------------------------

const _ansiReset = '\x1B[0m';
const _ansiBold = '\x1B[1m';
const _ansiGreen = '\x1B[32m';
const _ansiYellow = '\x1B[33m';
const _ansiRed = '\x1B[31m';
const _ansiCyan = '\x1B[36m';
const _ansiDim = '\x1B[2m';

bool get _useColor => stdout.supportsAnsiEscapes;

void _print(String message, {String? color, bool bold = false}) {
  if (_useColor && color != null) {
    stdout.writeln('${bold ? _ansiBold : ''}$color$message$_ansiReset');
  } else {
    stdout.writeln(message);
  }
}

void _info(String m) => _print(m, color: _ansiCyan);
void _success(String m) => _print(m, color: _ansiGreen);
void _warn(String m) => _print(m, color: _ansiYellow);
void _error(String m) => _print(m, color: _ansiRed);
void _step(String m) => _print('==> $m', color: _ansiCyan, bold: true);
void _dim(String m) => _print(m, color: _ansiDim);

Never _fail(String message) {
  _error('[错误] $message');
  _waitForExit();
  exit(1);
}

/// 交互模式下等待用户按键后退出，避免双击 .bat 时窗口一闪而过。
/// CI / 管道输入（无终端）时自动跳过，不阻塞。
void _waitForExit() {
  if (!stdin.hasTerminal) return;
  stdout.writeln();
  stdout.write('按回车键退出...');
  stdin.readLineSync();
}

// ---------------------------------------------------------------------------
// 全局状态
// ---------------------------------------------------------------------------

late final Directory _root;
late final Directory _releaseDir;
final List<String> _artifacts = [];

/// Flutter 版本号解析结果缓存（见 [_resolveFlutterVersion]）。
String? _cachedFlutterVersion;

// ---------------------------------------------------------------------------
// 构建目标
// ---------------------------------------------------------------------------

enum BuildTarget { android, windows, zipOnly, all }

enum _MenuChoice { android, windows, zipOnly, all, setVersion, exit }

// ---------------------------------------------------------------------------
// 入口
// ---------------------------------------------------------------------------

Future<void> main(List<String> args) async {
  _root = _findProjectRoot();
  _releaseDir = Directory(p.join(_root.path, 'build', 'release'))
    ..createSync(recursive: true);

  final cli = _parseArgs(args);
  if (cli == null) return; // 帮助 / 参数错误已处理

  if (cli.target != null) {
    final target = cli.target!;
    if (target == BuildTarget.all) {
      await _runBuild(BuildTarget.all, bump: cli.bump, newVersion: cli.version);
    } else {
      await _runBuild(target, bump: cli.bump, newVersion: cli.version);
    }
    _waitForExit();
    return;
  }

  // 交互菜单
  var bump = true;
  String? newVersion;
  while (true) {
    final choice = await _promptMenu(newVersion: newVersion);
    switch (choice) {
      case _MenuChoice.exit:
        _info('已退出。');
        return;
      case _MenuChoice.setVersion:
        newVersion = _promptVersion();
        continue;
      case _MenuChoice.android:
        await _runBuild(BuildTarget.android, bump: bump, newVersion: newVersion);
        _waitForExit();
        return;
      case _MenuChoice.windows:
        await _runBuild(BuildTarget.windows, bump: bump, newVersion: newVersion);
        _waitForExit();
        return;
      case _MenuChoice.zipOnly:
        await _runBuild(BuildTarget.zipOnly, bump: bump, newVersion: newVersion);
        _waitForExit();
        return;
      case _MenuChoice.all:
        await _runBuild(BuildTarget.all, bump: bump, newVersion: newVersion);
        _waitForExit();
        return;
    }
  }
}

// ---------------------------------------------------------------------------
// 参数解析
// ---------------------------------------------------------------------------

class _CliArgs {
  const _CliArgs({this.target, this.bump = true, this.version});
  final BuildTarget? target;
  final bool bump;
  final String? version;
}

_CliArgs? _parseArgs(List<String> args) {
  if (args.isEmpty) return const _CliArgs();
  BuildTarget? target;
  var bump = true;
  String? version;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--android':
        target = BuildTarget.android;
      case '--windows':
        target = BuildTarget.windows;
      case '--zip-only':
        target = BuildTarget.zipOnly;
      case '--all':
        target = BuildTarget.all;
      case '--no-bump':
        bump = false;
      case '--version':
        if (i + 1 >= args.length) {
          _error('--version 需要一个参数（如 --version 1.2.0）');
          _printUsage();
          _waitForExit();
          exit(2);
        }
        version = args[++i];
      case '--help':
      case '-h':
        _printUsage();
        return null;
      default:
        _error('未知参数：${args[i]}');
        _printUsage();
        _waitForExit();
        exit(2);
    }
  }
  return _CliArgs(target: target, bump: bump, version: version);
}

void _printUsage() {
  _print('''
NarrChat 发布构建脚本
用法：
  dart run tool/build_release.dart                 交互菜单
  dart run tool/build_release.dart --android       仅 Android arm64 APK
  dart run tool/build_release.dart --windows       Windows（setup.exe 安装包 + ZIP）
  dart run tool/build_release.dart --zip-only      Windows 仅 ZIP 便携包
  dart run tool/build_release.dart --all           Android + Windows
  dart run tool/build_release.dart --no-bump       跳过 build 号自增
  dart run tool/build_release.dart --version 1.2.0 构建前设置版本号（x.y.z）
''');
}

// ---------------------------------------------------------------------------
// 交互菜单
// ---------------------------------------------------------------------------

Future<_MenuChoice> _promptMenu({String? newVersion}) async {
  while (true) {
    final cfg = _loadConfig();
    _print('============================================', color: _ansiCyan);
    _print('  NarrChat Release 构建脚本', color: _ansiCyan, bold: true);
    _print('============================================', color: _ansiCyan);
    _print('  1. Android arm64 APK');
    _print('  2. Windows（setup.exe 安装包 + ZIP 便携包）');
    _print('  3. Windows ZIP 便携包（免安装）');
    _print('  4. 全部构建');
    _print('  5. 设置版本号');
    _print('  0. 退出');
    _print('============================================');
    _print('  产物输出目录：${_releaseDir.path}');
    _print('  当前版本：${cfg.version}  (build ${cfg.build})');
    // 已设置新版本号时，展示构建后即将使用的版本（交互模式下 build 恒会 +1）。
    if (newVersion != null && newVersion.isNotEmpty) {
      _print('  构建后新版本号：$newVersion  (build ${cfg.build + 1})');
    }
    _print('============================================');
    stdout.write('请选择 (0/1/2/3/4/5): ');
    final input = stdin.readLineSync()?.trim() ?? '';
    switch (input) {
      case '0':
        return _MenuChoice.exit;
      case '1':
        return _MenuChoice.android;
      case '2':
        return _MenuChoice.windows;
      case '3':
        return _MenuChoice.zipOnly;
      case '4':
        return _MenuChoice.all;
      case '5':
        return _MenuChoice.setVersion;
      default:
        _error('无效输入，请重新选择。');
    }
  }
}

String? _promptVersion() {
  stdout.write('请输入新版本号（x.y.z，回车取消）: ');
  final input = stdin.readLineSync()?.trim() ?? '';
  if (input.isEmpty) return null;
  if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(input)) {
    _warn('无效版本号：$input（应为 x.y.z，如 1.2.3），已忽略。');
    return null;
  }
  return input;
}

ReleaseConfig _loadConfig() {
  final f = File(p.join(_root.path, 'release.yaml'));
  return parseReleaseYaml(f.readAsStringSync());
}

// ---------------------------------------------------------------------------
// 版本准备（第一步：build 号自增 + pubspec 同步）
// ---------------------------------------------------------------------------

/// 读取 release.yaml，按需设置版本号 / 自增 build，写回并同步 pubspec.yaml。
/// 返回最终使用的版本配置。
ReleaseConfig _prepareVersion({required bool bump, String? newVersion}) {
  final releaseFile = File(p.join(_root.path, 'release.yaml'));
  final pubspecFile = File(p.join(_root.path, 'pubspec.yaml'));

  var text = releaseFile.readAsStringSync();

  if (newVersion != null && newVersion.isNotEmpty) {
    _step('设置版本号：$newVersion');
    text = setVersionInYaml(text, newVersion);
  }

  var config = parseReleaseYaml(text);
  if (bump) {
    _step('自增 build 号：${config.build} → ${config.build + 1}');
    config = ReleaseConfig(version: config.version, build: config.build + 1);
    text = bumpBuildInYaml(text, newBuild: config.build);
  }

  releaseFile.writeAsStringSync(text);
  _success('已更新 release.yaml → version: ${config.version}, build: ${config.build}');

  // 同步 pubspec.yaml 的 version 字段，保持与 release.yaml 一致。
  final pubspec = pubspecFile.readAsStringSync();
  final synced = syncPubspecVersion(pubspec, config.version, config.build);
  if (synced != pubspec) {
    pubspecFile.writeAsStringSync(synced);
    _dim('已同步 pubspec.yaml version → ${buildPubspecVersion(config.version, config.build)}');
  }
  return config;
}

// ---------------------------------------------------------------------------
// 构建执行
// ---------------------------------------------------------------------------

Future<void> _runBuild(
  BuildTarget target, {
  required bool bump,
  String? newVersion,
}) async {
  // 第一步：版本号准备（build +1 并同步 pubspec）。
  final config = _prepareVersion(bump: bump, newVersion: newVersion);
  _print('');
  _info('本次构建版本：${config.version} (build ${config.build})');
  _print('');

  switch (target) {
    case BuildTarget.android:
      await _buildAndroid(config);
    case BuildTarget.zipOnly:
      await _buildWindows(config, withInstaller: false);
    case BuildTarget.windows:
      await _buildWindows(config, withInstaller: true);
    case BuildTarget.all:
      await _buildAndroid(config);
      await _buildWindows(config, withInstaller: true);
  }

  _printSummary();
}

Future<void> _buildAndroid(ReleaseConfig config) async {
  _step('Android：编译 arm64 Release APK '
      '(build-name=${config.version}, build-number=${config.build})');
  final code = await _runFlutterLive([
    'build',
    'apk',
    '--release',
    '--target-platform',
    'android-arm64',
    '--build-name=${config.version}',
    '--build-number=${config.build}',
    ..._flutterVersionDefine(),
  ]);
  if (code != 0) _fail('Android 构建失败（flutter 退出码 $code）。');

  final src = File(p.join(_root.path, 'build', 'app', 'outputs', 'flutter-apk',
      'app-release.apk'));
  if (!src.existsSync()) _fail('未找到构建产物：${src.path}');

  final name =
      '${artifactBaseName(config, device: 'android', arch: 'arm64')}.apk';
  final dst = File(p.join(_releaseDir.path, name));
  _deleteIfExists(dst);
  src.renameSync(dst.path);
  _success('APK 已生成：${dst.path}');
  _artifacts.add(dst.path);
}

Future<void> _buildWindows(ReleaseConfig config, {required bool withInstaller}) async {
  _checkWindowsEphemeralHealth();
  _step('Windows：编译 x64 Release');
  final code = await _runFlutterLive([
    'build',
    'windows',
    '--release',
    ..._flutterVersionDefine(),
  ]);
  if (code != 0) _fail('Windows 构建失败（flutter 退出码 $code）。');

  final srcDir = Directory(p.join(
      _root.path, 'build', 'windows', 'x64', 'runner', 'Release'));
  if (!File(p.join(srcDir.path, 'narrchat.exe')).existsSync()) {
    _fail('未找到构建产物：${p.join(srcDir.path, 'narrchat.exe')}');
  }

  _cleanWindowsArtifacts(config);

  // --- ZIP 便携包 ---
  final zipName =
      '${artifactBaseName(config, device: 'windows', arch: 'x64')}.zip';
  final zipPath = p.join(_releaseDir.path, zipName);
  // 暂存目录：ZIP 顶层统一为 Narrchat 文件夹（解压即得干净程序目录）。
  final staging = Directory(p.join(_releaseDir.path, 'Narrchat'));
  _copyDirContents(srcDir, staging);

  _step('打包 ZIP：$zipName');
  try {
    await _zipDir(staging, zipPath);
  } on FileSystemException catch (e) {
    _fail('ZIP 打包失败（可能旧 ZIP 正被其他程序占用）：$e');
  }
  _success('ZIP 已生成：$zipPath');
  _artifacts.add(zipPath);

  // 清理暂存目录。
  _deleteDirIfExists(staging);

  // --- setup.exe 安装包（Inno Setup） ---
  if (!withInstaller) return;
  final iscc = _findIscc();
  if (iscc == null) {
    _warn('未检测到 Inno Setup（ISCC.exe），跳过安装包生成。');
    _warn('请安装 Inno Setup 后重试：https://jrsoftware.org/isdl.php');
    return;
  }

  final issPath = _writeIss(config, appDir: srcDir);
  _step('Inno Setup：编译安装包');
  final result = await Process.run(iscc, [issPath], workingDirectory: _root.path);
  if (result.exitCode != 0) {
    _error('Inno Setup 输出：\n${result.stdout}${result.stderr}');
    _warn('已保留调试脚本：$issPath（修复后可手动删除 iss_tmp 目录）');
    _fail('setup.exe 生成失败（ISCC 退出码 ${result.exitCode}）。');
  }
  _deleteDirIfExists(Directory(p.dirname(issPath)));

  final setupName =
      '${artifactBaseName(config, device: 'windows', arch: 'x64')}-setup.exe';
  final setupPath = p.join(_releaseDir.path, setupName);
  if (!File(setupPath).existsSync()) {
    _fail('未找到 Inno Setup 产物：$setupPath');
  }
  _success('setup.exe 已生成：$setupPath');
  _artifacts.add(setupPath);
}

// ---------------------------------------------------------------------------
// Windows 引擎缓存自愈
// ---------------------------------------------------------------------------

/// 检查 Flutter 引擎包装源码（cpp_client_wrapper/*.cc）是否就位。
///
/// 根因：MSBuild 的 up-to-date 检查可能跳过 `flutter_assemble` 步骤（负责把
/// SDK 引擎缓存的 cpp_client_wrapper/*.cc 解包到 windows/flutter/ephemeral/），
/// 导致 .cc 缺失、MSBuild 报 C1083（无法打开源文件）。
/// 检测到缺失时自动清理相关缓存强制重新解包。
void _checkWindowsEphemeralHealth() {
  const required = [
    'core_implementations.cc',
    'flutter_engine.cc',
    'flutter_view_controller.cc',
    'plugin_registrar.cc',
    'standard_codec.cc',
  ];
  final wrapper = Directory(p.join(
      _root.path, 'windows', 'flutter', 'ephemeral', 'cpp_client_wrapper'));
  final missing =
      required.where((f) => !File(p.join(wrapper.path, f)).existsSync()).toList();
  if (missing.isEmpty) return;

  _warn('检测到 Windows 引擎包装源码缺失（${missing.join(', ')}），'
      '可能是增量构建缓存损坏，正在清理后重新构建...');
  // 1) 删除残缺的 ephemeral，触发重新解包。
  _deleteDirIfExists(
      Directory(p.join(_root.path, 'windows', 'flutter', 'ephemeral')));
  // 2) 删除 flutter assemble 的 depfile，防止增量跳过解包。
  final flutterBuild = Directory(p.join(_root.path, '.dart_tool', 'flutter_build'));
  if (flutterBuild.existsSync()) {
    for (final dir in flutterBuild.listSync().whereType<Directory>()) {
      _deleteIfExists(File(p.join(dir.path, 'windows_engine_sources.d')));
    }
  }
  // 3) 删除 build/windows，强制 CMake 重新配置（仅删 ephemeral/depfile 不够，
  //    MSBuild 仍可能按 up-to-date 跳过 flutter_assemble）。
  _deleteDirIfExists(Directory(p.join(_root.path, 'build', 'windows')));
}

// ---------------------------------------------------------------------------
// Flutter 进程
// ---------------------------------------------------------------------------

/// 启动 flutter 进程。Windows 下 `flutter` 无法直接启动（.bat）时回退 `flutter.bat`。
Future<Process> _startFlutter(List<String> args) async {
  final candidates = Platform.isWindows ? const ['flutter', 'flutter.bat'] : const ['flutter'];
  ProcessException? last;
  for (final cmd in candidates) {
    try {
      return await Process.start(cmd, args, workingDirectory: _root.path);
    } on ProcessException catch (e) {
      last = e;
    }
  }
  throw last!;
}

/// 解析当前 Flutter 版本号（`flutter --version --machine` 的 frameworkVersion），
/// 供 `--dart-define=NARRCHAT_FLUTTER_VERSION` 注入「关于」面板展示。
///
/// 解析失败返回 null（此时不注入 define，「关于」面板隐藏 Flutter 行）；
/// 结果缓存，一次构建只解析一次。
String? _resolveFlutterVersion() {
  if (_cachedFlutterVersion != null) return _cachedFlutterVersion;
  String? version;
  final candidates =
      Platform.isWindows ? const ['flutter', 'flutter.bat'] : const ['flutter'];
  for (final cmd in candidates) {
    try {
      final result = Process.runSync(
        cmd,
        ['--version', '--machine'],
        workingDirectory: _root.path,
      );
      if (result.exitCode != 0) continue;
      final map = jsonDecode((result.stdout as String).trim());
      final v = (map as Map<String, dynamic>)['frameworkVersion'];
      if (v is String && v.isNotEmpty) {
        version = v;
        break;
      }
    } catch (_) {
      // 尝试下一个候选命令。
    }
  }
  _cachedFlutterVersion = version;
  return version;
}

/// `--dart-define=NARRCHAT_FLUTTER_VERSION=...` 参数列表；解析失败返回空列表。
///
/// ⚠️ 不能使用 `FLUTTER_VERSION`——Flutter 3.44 已将其保留为框架内置
/// dart-define（`FlutterVersion`），运行时用 `--dart-define` 覆盖会直接报错。
List<String> _flutterVersionDefine() {
  final version = _resolveFlutterVersion();
  return version == null
      ? const []
      : ['--dart-define=NARRCHAT_FLUTTER_VERSION=$version'];
}

/// 实时输出 flutter 构建日志，返回退出码。
Future<int> _runFlutterLive(List<String> args) async {
  final Process process;
  try {
    process = await _startFlutter(args);
  } on ProcessException catch (e) {
    _fail('无法启动 flutter 命令：${e.message}（请确认 Flutter 已加入 PATH）');
  }
  process.stdout.transform(utf8.decoder).listen((s) => stdout.write(s));
  process.stderr.transform(utf8.decoder).listen((s) => stderr.write(s));
  return process.exitCode;
}

// ---------------------------------------------------------------------------
// 文件与目录工具
// ---------------------------------------------------------------------------

Directory _findProjectRoot() {
  var dir = Directory.current;
  while (true) {
    if (File(p.join(dir.path, 'pubspec.yaml')).existsSync()) return dir;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError('未找到项目根目录（缺少 pubspec.yaml）。请在项目根目录运行本脚本。');
}

void _deleteIfExists(File file) {
  if (!file.existsSync()) return;
  try {
    file.deleteSync();
  } catch (_) {
    _warn('无法删除旧产物 ${p.basename(file.path)}（可能被占用），已跳过。');
  }
}

void _deleteDirIfExists(Directory dir) {
  if (!dir.existsSync()) return;
  try {
    dir.deleteSync(recursive: true);
  } catch (e) {
    _warn('无法清理目录 ${dir.path}：$e');
  }
}

/// 清理 Windows 旧产物（同名 ZIP / setup.exe）与 NarrChat* 暂存目录残留。
void _cleanWindowsArtifacts(ReleaseConfig config) {
  final base = artifactBaseName(config, device: 'windows', arch: 'x64');
  final names = [
    '$base.zip',
    '$base-setup.exe',
  ];
  for (final name in names) {
    _deleteIfExists(File(p.join(_releaseDir.path, name)));
  }
  if (!_releaseDir.existsSync()) return;
  for (final entity in _releaseDir.listSync()) {
    if (entity is Directory && p.basename(entity.path).startsWith('NarrChat')) {
      _deleteDirIfExists(entity);
    }
  }
}

/// 递归复制目录内容（不含顶层目录本身）。
void _copyDirContents(Directory from, Directory to) {
  to.createSync(recursive: true);
  for (final entity in from.listSync(recursive: false)) {
    final name = p.basename(entity.path);
    if (entity is Directory) {
      _copyDirContents(entity, Directory(p.join(to.path, name)));
    } else if (entity is File) {
      entity.copySync(p.join(to.path, name));
    }
  }
}

/// 用 archive 包把目录打成 ZIP（顶层包含目录名，流式写盘不占内存）。
Future<void> _zipDir(Directory dir, String zipPath) async {
  final encoder = ZipFileEncoder();
  encoder.create(zipPath);
  await encoder.addDirectory(dir, includeDirName: true);
  encoder.closeSync();
}

// ---------------------------------------------------------------------------
// Inno Setup 安装包
// ---------------------------------------------------------------------------

/// 查找 ISCC.exe（Inno Setup 编译器）。
String? _findIscc() {
  final which = Process.runSync(Platform.isWindows ? 'where' : 'which', ['ISCC']);
  if (which.exitCode == 0) {
    final line = (which.stdout as String).trim().split('\n').first.trim();
    if (line.isNotEmpty && !line.toLowerCase().contains('could not find')) {
      return line;
    }
  }
  const candidates = [
    r'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    r'C:\Program Files\Inno Setup 6\ISCC.exe',
  ];
  for (final c in candidates) {
    if (File(c).existsSync()) return c;
  }
  return null;
}

/// 生成并写入 Inno Setup 脚本（.iss，UTF-8 BOM 保证中文正常）。
String _writeIss(ReleaseConfig config, {required Directory appDir}) {
  final issDir = Directory(p.join(_releaseDir.path, 'iss_tmp'))
    ..createSync(recursive: true);
  final issFile = File(p.join(issDir.path, 'installer.iss'));
  final content = _buildIssContent(config, appDir: appDir);
  issFile.writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode(content)]);
  return issFile.path;
}

/// 把普通文本转成 Inno [Code] 可用的 Pascal 字符串表达式。
///
/// 转义单引号（`'` → `''`），换行转为 `' + #13#10 + '`。
String pascalString(String s) {
  final escaped = s.replaceAll("'", "''").replaceAll('\r', '');
  return escaped.replaceAll('\n', "' + #13#10 + '");
}

/// 读取更新说明：优先 `UPDATE_NOTES.md`，其次 `CHANGELOG.md`，否则返回默认文案。
String _loadUpdateNotes(ReleaseConfig config) {
  for (final name in ['UPDATE_NOTES.md', 'CHANGELOG.md']) {
    final file = File(p.join(_root.path, name));
    if (file.existsSync()) {
      final text = file.readAsStringSync().trim();
      if (text.isNotEmpty) return text;
    }
  }
  return 'NarrChat v${config.version}（build ${config.build}）\n\n'
      '【安装 / 更新说明】\n'
      '• 默认安装到当前用户目录，无需管理员权限\n'
      '• 可选择创建桌面 / 开始菜单快捷方式\n'
      '• 升级安装：直接覆盖旧版本即可，数据不受影响';
}

/// 生成 Inno Setup 脚本内容：
/// - 全中文向导（ChineseSimplified.isl + 微软雅黑字体）
/// - 标准向导式，默认装到用户目录（{localappdata}\Programs\NarrChat，免 UAC）
/// - 可勾选桌面 / 开始菜单快捷方式
/// - 「更新说明」页面（内容来自 UPDATE_NOTES.md / CHANGELOG.md）
/// - 已安装时跳过「选择安装目录」页面，直接进入快捷方式（任务）页面
/// - 自动注册卸载；升级 = 安装到同一目录覆盖
String buildIssContent({
  required ReleaseConfig config,
  required String appDirPath,
  required String iconPath,
  required String outputDirPath,
  required String updateNotes,
  required String languageFilePath,
}) {
  final notesExpr = pascalString(updateNotes);
  return '''
; NarrChat 安装脚本（由 tool/build_release.dart 自动生成，请勿手动修改）

[Setup]
AppId={{8F2E1A3C-5B6D-4E7F-9A8B-0C1D2E3F4A5B}
AppName=NarrChat
AppVersion=${config.version}
AppPublisher=NarrChat
DefaultDirName={code:GetDefaultDir}
UsePreviousAppDir=yes
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir=$outputDirPath
OutputBaseFilename=NarrChat_${config.version}-${config.build}_windows_x64-setup
Compression=lzma2
SolidCompression=yes
SetupIconFile=$iconPath
UninstallDisplayIcon={app}\\narrchat.exe
UninstallDisplayName=NarrChat
; 仅内置中文，不弹语言选择框
ShowLanguageDialog=no

[Languages]
Name: "chinesesimp"; MessagesFile: "$languageFilePath"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"; Flags: unchecked
Name: "startmenuicon"; Description: "创建开始菜单快捷方式"; GroupDescription: "附加图标:"

[Files]
Source: "$appDirPath\\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\\NarrChat"; Filename: "{app}\\narrchat.exe"; Tasks: startmenuicon
Name: "{autodesktop}\\NarrChat"; Filename: "{app}\\narrchat.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\\narrchat.exe"; Description: "立即运行 NarrChat"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
const
  UninstallKey = 'Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\{8F2E1A3C-5B6D-4E7F-9A8B-0C1D2E3F4A5B}_is1';

var
  UpdateNotesPage: TOutputMsgMemoWizardPage;

// 是否已安装（Inno 卸载信息固定存于 HKCU\\...\\Uninstall\\{AppId}_is1）
function IsAppInstalled(): Boolean;
begin
  Result := RegKeyExists(HKCU, UninstallKey);
end;

// 已安装时返回旧安装目录，否则返回用户目录默认值
function GetDefaultDir(Param: String): String;
var
  InstalledDir: String;
begin
  if RegQueryStringValue(HKCU, UninstallKey, 'Inno Setup: App Path', InstalledDir) then
    Result := InstalledDir
  else
    Result := ExpandConstant('{localappdata}\\Programs\\NarrChat');
end;

// 已安装时跳过「选择安装目录」页面，直接进入快捷方式（任务）页面
function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if PageID = wpSelectDir then
    Result := IsAppInstalled();
end;

procedure InitializeWizard;
begin
  // 中文字体无需显式指定：Windows 字体回退（Segoe UI → 微软雅黑）已能正常渲染中文。
  if IsAppInstalled() then
    UpdateNotesPage := CreateOutputMsgMemoPage(wpWelcome, '更新说明', '您正在升级到新版本', '', '$notesExpr')
  else
    UpdateNotesPage := CreateOutputMsgMemoPage(wpWelcome, '更新说明', '感谢选择 NarrChat', '', '$notesExpr');
end;
''';
}

/// 组装当前构建的 Inno Setup 脚本（注入项目实际路径与更新说明）。
String _buildIssContent(ReleaseConfig config, {required Directory appDir}) {
  final iconPath =
      p.join(_root.path, 'windows', 'runner', 'resources', 'app_icon.ico');
  return buildIssContent(
    config: config,
    appDirPath: appDir.path,
    iconPath: iconPath,
    outputDirPath: _releaseDir.path,
    updateNotes: _loadUpdateNotes(config),
    // 中文语言文件随项目一起管理（来自 jrsoftware/issrc，Inno Setup License），
    // 避免依赖本机 Inno Setup 是否随附 ChineseSimplified.isl。
    languageFilePath:
        p.join(_root.path, 'tool', 'inno', 'ChineseSimplified.isl'),
  );
}

// ---------------------------------------------------------------------------
// 汇总
// ---------------------------------------------------------------------------

void _printSummary() {
  _print('');
  _step('构建完成，产物清单：');
  for (final path in _artifacts) {
    final f = File(path);
    final size = f.existsSync() ? f.lengthSync() : 0;
    _success('  ${p.basename(path)}  (${_formatSize(size)})');
    _dim('    $path');
  }
}

String _formatSize(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}
