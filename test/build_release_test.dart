// tool/build_release.dart 纯函数的单元测试（版本解析 / 自增 / pubspec 同步）。
import 'package:flutter_test/flutter_test.dart';

import '../tool/build_release.dart';

void main() {
  group('parseReleaseYaml', () {
    test('解析正常文件（含注释）', () {
      const raw = '''
# 注释行
version: 1.1.3
build: 7
''';
      final cfg = parseReleaseYaml(raw);
      expect(cfg.version, '1.1.3');
      expect(cfg.build, 7);
    });

    test('缺失字段回退默认值', () {
      final cfg = parseReleaseYaml('# 只有注释\n');
      expect(cfg.version, '1.0.0');
      expect(cfg.build, 1);
    });

    test('字段顺序无关、容忍缩进', () {
      final cfg = parseReleaseYaml('build: 12\nversion: 2.0.0\n');
      expect(cfg.version, '2.0.0');
      expect(cfg.build, 12);
    });

    test('build 非数字回退默认', () {
      final cfg = parseReleaseYaml('version: 1.0.0\nbuild: abc\n');
      expect(cfg.build, 1);
    });

    test('version 带内联注释只取字段值', () {
      final cfg = parseReleaseYaml('version: 1.2.3 # 注释\nbuild: 4\n');
      expect(cfg.version, '1.2.3');
      expect(cfg.build, 4);
    });
  });

  group('setVersionInYaml', () {
    test('更新版本号并保留 build', () {
      const raw = 'version: 1.1.3\nbuild: 7\n';
      final out = setVersionInYaml(raw, '2.0.0');
      expect(out, contains('version: 2.0.0'));
      expect(out, contains('build: 7'));
    });

    test('未找到 version 行时原样返回', () {
      const raw = 'build: 7\n';
      expect(setVersionInYaml(raw, '2.0.0'), raw);
    });
  });

  group('bumpBuildInYaml', () {
    test('自增并保留注释与 version', () {
      const raw = '# 版本\nversion: 1.1.3\nbuild: 7\n';
      final out = bumpBuildInYaml(raw);
      expect(out, startsWith('# 版本'));
      expect(out, contains('version: 1.1.3'));
      expect(out, contains('build: 8'));
    });

    test('指定 newBuild', () {
      const raw = 'version: 1.1.3\nbuild: 7\n';
      expect(bumpBuildInYaml(raw, newBuild: 100), contains('build: 100'));
    });

    test('缺失 build 行时追加到末尾', () {
      const raw = 'version: 1.0.0\n';
      final out = bumpBuildInYaml(raw);
      expect(out, endsWith('build: 2\n'));
    });

    test('build 行带缩进也能更新', () {
      const raw = 'version: 1.0.0\n  build: 3\n';
      expect(bumpBuildInYaml(raw), contains('  build: 4'));
    });
  });

  group('pubspec 版本同步', () {
    test('buildPubspecVersion 拼装格式', () {
      expect(buildPubspecVersion('1.1.3', 8), '1.1.3+8');
    });

    test('syncPubspecVersion 更新 version 行', () {
      const raw = 'name: narrchat\nversion: 1.0.0+1\nenvironment:\n  sdk: ^3.12.2\n';
      final out = syncPubspecVersion(raw, '1.1.3', 8);
      expect(out, contains('name: narrchat'));
      expect(out, contains('version: 1.1.3+8'));
      expect(out, contains('sdk: ^3.12.2'));
    });

    test('syncPubspecVersion 不误伤注释行', () {
      const raw = '# The following defines the version and build number\n'
          'version: 1.0.0+1\n';
      final out = syncPubspecVersion(raw, '2.0.0', 3);
      expect(out, contains('# The following defines the version and build number'));
      expect(out, contains('version: 2.0.0+3'));
    });

    test('无 version 行时原样返回', () {
      const raw = 'name: narrchat\n';
      expect(syncPubspecVersion(raw, '1.1.3', 8), raw);
    });
  });

  group('artifactBaseName（产物命名）', () {
    const config = ReleaseConfig(version: '1.2.3', build: 57);

    test('Windows x64 命名', () {
      expect(artifactBaseName(config, device: 'windows', arch: 'x64'),
          'NarrChat_1.2.3-57_windows_x64');
    });

    test('Android arm64 命名', () {
      expect(artifactBaseName(config, device: 'android', arch: 'arm64'),
          'NarrChat_1.2.3-57_android_arm64');
    });
  });

  group('pascalString', () {
    test('普通文本原样返回', () {
      expect(pascalString('abc'), 'abc');
    });

    test('转义单引号', () {
      expect(pascalString("it's"), "it''s");
    });

    test('换行转为 Pascal 拼接', () {
      expect(pascalString('a\nb'), "a' + #13#10 + 'b");
    });

    test('CRLF 只保留换行拼接', () {
      expect(pascalString('a\r\nb'), "a' + #13#10 + 'b");
    });

    test('空字符串返回空', () {
      expect(pascalString(''), '');
    });
  });

  group('buildIssContent（Inno 安装脚本）', () {
    const config = ReleaseConfig(version: '1.1.3', build: 8);
    const notes = 'NarrChat v1.1.3\n【更新】\n- 修复若干问题';

    String build() => buildIssContent(
          config: config,
          appDirPath: r'C:\build\Release',
          iconPath: r'C:\project\app_icon.ico',
          outputDirPath: r'C:\project\build\release',
          updateNotes: notes,
          languageFilePath: r'C:\project\tool\inno\ChineseSimplified.isl',
        );

    test('包含中文语言配置', () {
      final out = build();
      expect(out, contains('[Languages]'));
      expect(out, contains('ChineseSimplified.isl'));
      expect(out, contains('ShowLanguageDialog=no'));
    });

    test('包含已安装跳过目录选择逻辑', () {
      final out = build();
      expect(out, contains('DefaultDirName={code:GetDefaultDir}'));
      expect(out, contains('function ShouldSkipPage'));
      expect(out, contains('wpSelectDir'));
      expect(out, contains('IsAppInstalled()'));
    });

    test('包含「更新说明」页面与内嵌内容', () {
      final out = build();
      expect(out, contains('更新说明'));
      expect(out, contains('您正在升级到新版本'));
      expect(out, contains('感谢选择 NarrChat'));
      // 更新说明多行文本以 Pascal 表达式内嵌
      expect(out, contains("'NarrChat v1.1.3' + #13#10 + '【更新】' + #13#10 + '- 修复若干问题'"));
    });

    test('产物命名与快捷方式任务', () {
      final out = build();
      expect(out, contains('OutputBaseFilename=NarrChat_1.1.3-8_windows_x64-setup'));
      expect(out, contains('创建桌面快捷方式'));
      expect(out, contains('创建开始菜单快捷方式'));
      expect(out, contains('{autoprograms}'));
      expect(out, contains('{autodesktop}'));
    });

    test('AppId 与卸载注册键一致', () {
      final out = build();
      expect(out, contains('AppId={{8F2E1A3C-5B6D-4E7F-9A8B-0C1D2E3F4A5B}'));
      expect(out,
          contains(r"'Software\Microsoft\Windows\CurrentVersion\Uninstall\{8F2E1A3C-5B6D-4E7F-9A8B-0C1D2E3F4A5B}_is1'"));
    });
  });
}
