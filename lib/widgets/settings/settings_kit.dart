/// 设置页统一组件套件（Settings Kit）。
///
/// 页面只需 `import '../widgets/settings/settings_kit.dart';` 一个文件：
/// - 版式：`SettingsPageHeader / SettingsSection / SettingsCard /
///   SettingsCardHeader / SettingsExpandableCard`；
/// - 控件：`SettingsRow / SettingsLinkRow / SettingsSwitchRow /
///   SettingsCheckboxRow / SettingsSelectRow / SettingsSegmented /
///   SettingsSegmentedRow / SettingsToggleChip`；
/// - 输入：`SettingsTextField / SettingsSecretField / SettingsSearchField /
///   SettingsDropdownField / SettingsReadonlyField`。
///
/// 圆角与动效常量统一在 `NarrChatTheme`，页面不要再手写圆角。
library;

export 'settings_controls.dart';
export 'settings_fields.dart';
export 'settings_layout.dart';
