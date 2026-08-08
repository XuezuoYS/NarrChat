/// 可被外部（如侧边栏模块标题栏的【编辑】/【保存】按钮）驱动的编辑组件状态接口。
///
/// 各编辑器（[MarkdownField] / [MemorySummaryEditor] / [MarkdownCollapsibleEditor]）
/// 的 State 实现该接口，侧边栏通过 `GlobalKey` 拿到 State 后调用 [enterEdit] / [save]，
/// 使吸顶标题栏成为该模块唯一的「编辑 / 保存」控制点。
abstract class EditableFieldState {
  /// 进入原始文本编辑模式。
  void enterEdit();

  /// 保存当前编辑内容（退出编辑模式并触发 `onSave` 回调）。
  void save();

  /// 是否处于编辑模式。
  bool get isEditing;
}
