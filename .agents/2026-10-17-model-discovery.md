# 模型列表发现（「获取可用模型」）实现备忘

## 参考

DeepSeek Harness 的模型发现实现（从 `DeepSeek Harness\resources\app.asar` 产物中
导出阅读，临时导出文件已清理）：

- `@deepseek-ai/dsh-llm-pi-ai/lib/index.js` 的 `discovery` 段：可列出模型的协议为
  `anthropic-messages` / `openai-completions` / `openai-responses`；OpenAI 系在
  `{baseURL}/models` 用 `Authorization: Bearer <key>`；成功响应读 `data` 数组，
  兼容网关增强的 `models` 对象（键即模型名）；缺模型名的条目跳过；
  非 2xx / 非 JSON / 形态不符都带上地址与状态码报错。
- `@deepseek-ai/dsh-client-ui-settings-models/lib/client.js`：按钮 + 多选导入框，
  默认只勾新模型，全选只作用于当前可见项，导入按模型名合并（DSH 保留旧值，
  本项目按用户要求改为整体覆盖）。

asar 解包思路（临时脚本已删）：文件前 16 字节是三个长度字段，JSON 头从第 16 字节
开始，文件数据从 `8 + 第二个长度字段` 开始。

## NarrChat 实现

- `lib/models/api_type.dart`：新增 `ApiType.supportsModelListing`（两个 OpenAI 协议为 true）。
- `lib/services/model_discovery_service.dart`：`fetchModels`（地址拼接、Bearer、
  30 秒超时、4MB 上限、UTF-8 解码）、`parseModelListing`（data 数组 / models 映射、
  能力字段读取）、`ModelDiscoveryException.describe()`（失败码 + 响应体，供悬浮通知）。
- `lib/widgets/ai_settings_form.dart`：自定义平台「添加模型」旁的「获取可用模型」
  按钮、`_ImportModelsDialog`（多选、全选 / 全不选、默认只勾新模型、「将覆盖」标记）。
- `lib/widgets/settings_form_state.dart`：`importModels`（同名整体覆盖、新名追加、
  自增 `resetRevision` 让模型编辑器按新值重建）。
- 测试：`test/model_discovery_service_test.dart`，以及
  `test/ai_settings_form_test.dart` 里的「获取可用模型」组。

## 约定

- 导入是**整体替换**同名模型（已与用户确认）：接口没给的能力字段回落
  `AiModel` 默认值（思考开、识图关、空档位即内置 `low/high/max`）。
- 只有自定义平台显示入口；内置预置平台的模型列表由软件维护。
- 请求用设置页的草稿值（Base URL 取工作副本，API Key 取输入框），不必先保存。
