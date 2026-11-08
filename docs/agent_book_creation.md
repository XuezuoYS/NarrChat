# 一句话创建新书（Agent 创建新书）

主页加号的【Agent 创建新书】用一句自然语言创意，按固定顺序逐项生成一本书的标题、
分类、Mod、基础设定、世界书、前后置词、文笔要求与角色类别，落库后进入书籍设置页。
本功能与「实验性 Agent 模式」无关，使用独立提示词与独立流程。

## 入口与页面

- 首页右上角加号 → 菜单【创建新书】【Agent 创建新书】；前者仍是原来的新建书籍页。
- **输入态**：满宽、可自然滚动的 Markdown 高亮输入框（`MarkdownEditingController`）；
  灰字明确提示「输入内容不会被保存」；可单独选择本次使用的生成模型。
- **创建态**：按步骤展示 5 个内容阶段 + 可能出现的补充轮 + 程序检查；每步有状态、
  流式输出、完成摘要、可展开的生成内容与分步 Token。生成期间可取消。
- 输入态与创建态在**同一条路由**里切换：失败 / 取消只切回输入态，输入框控制器不销毁，
  内容天然保留；成功后整条路由被聊天页替换，不残留半路页面。

## 模型与请求

- 生成模型只作用于本次创建，**不写回**全局选中模型、不写本地配置。
- 协议跟随平台：`openai-responses` 走 `instructions + input`；OpenAI Chat 兼容走
  `system + user` 消息。请求体用 `AiRequestBodyBuilder` 按平台规则构建。
- 思考 / 流式 = 模型能力与用户在 Chat 页记忆偏好的交集；不注入工具、不联网。
- 不自动重试：网络 / API / 超时失败直接弹失败框并回到输入态。

## 五个阶段与标签协议

所有阶段共用同一份系统提示词（只输出当前步骤的标签内容、简体中文、禁止 `#` / `##`、
内容自洽、不复制 Mod 内容）。每步一次 AI 请求。

| 阶段 | 输出标签 | 要点 |
|---|---|---|
| 标题与类别 | `<title>`、`<category>` | 均非空、单行 |
| 选择 Mod | `<mods><mod>ref</mod></mods>` | 只能填目录里的 `preset:<key>` / `user:<uuid>`；最多 8 个；可为空 |
| 基础设定与世界书 | `<baseSetting>`、`<worldBook><entry><keyword>…</keyword><content>…</content></entry></worldBook>` | 世界书 1~8 条，**每条关键词必填**（命中才注入），内容非空 |
| 前后置词与文笔要求 | `<prePrompt>`、`<postPrompt>`、`<writingRequirements>` | 均非空；文笔要求只写规则，不写范文 |
| 角色类别与格式 | `<roleCategories><category><name>…</name><format>…</format></category></roleCategories>` | 名称唯一非空、格式非空；顺序即角色层级顺序 |

- 阶段 2 的目录来自 `ModProvider.allMods`（预置 + 用户自定义），带 ref、名称、简介、
  作用区域与截断预览；模型选到目录外的引用会被忽略并显示提醒。
- 阶段 3 起把已选 Mod 的名称 / 简介带给模型，避免与 Mod 内容重复。
- 解析器（`book_creation_parser.dart`）逐块独立解析：剥围栏、标签名大小写 / 空白容忍；
  坏块只丢自己并记提醒，不抛异常。字段缺失交给完整性检查。
- 文笔参考段落、封面、历史轮数、记忆总结档位不由 AI 生成，落库时保持空 / 默认值。

## 完整性检查与补充轮

落库**之前**先做内容完整性检查（`BookCreationVerifier.completenessProblems`）：

- 书名 / 分类 / 基础设定 / 前后置词 / 文笔要求非空；
- 世界书至少 1 条，每条关键词与内容非空；
- 角色类别至少 1 个，名称唯一、格式非空。

不完整时发起**最多 2 次补充轮**（每次一次 AI 请求）：提示词带当前草稿与问题清单，
只要求输出需要补充 / 修正的标签。仍不完整时弹【内容不完整】对话框：

- **返回重新编辑**：回输入态，不建书；
- **保留此书**：以现有内容建书（标题为空用「未命名书籍」，角色类别为空 / 无效回退
  默认类别），进入书籍设置页，并在对话框里列出仍不完整的项。

## 落库与程序检查

写入器（`book_creation_writer.dart`）直接走仓储（不经过 Provider），顺序：

1. `BookRepository.createBook` 建书（此时已带全部设置）；
2. `WorldBookRepository.replaceAll` 写世界书（只写有效条目，全部启用）；
3. `ModRepository.setUseModUuids` 写启用 Mod（按模型给出的顺序，预置用 `preset::<key>`）；
4. 重新读库，做 **回读 + 提示词生效校验**（`BookCreationVerifier.verifyPersisted`）：
   - 字段 / 世界书（多重集合，回读顺序由 `created_at, uuid` 决定）/ 启用 Mod 顺序一致；
   - 用回读出的书、世界书、Mod 束重新拼装一次叙事提示词，确认每个非空字段、
     角色格式、世界书内容（用关键词探测输入触发扫描）、所选 Mod 的前置 / 后置 /
     系统 / 世界书内容都真实出现在拼装结果里。
5. 任一步数据库异常或校验不通过：用 `BookRepository.purgeBook` **物理删除**刚建的书
   （书库文件 + 目录行 + 缓存，不写墓碑），弹【创建失败】并回到输入态；
6. 成功：`BookProvider.loadBooks()` 刷新并选中新书，触发**一次**云同步。

成功 / 保留此书后展示成功对话框（总消耗 + 分步消耗），确认后进入书籍设置页。
设置页保存或直接返回后，都进入新书的聊天页（设置页有改动时走现有的「未保存」拦截）。

## 数据与安全

- 输入的创意只在页面内存里，不落库、不写本地配置、不存 RAW；失败草稿不保存。
- 新建的书是正常的书：可编辑、可同步、出现在首页；文笔参考段落与封面为空，
  历史轮数 = 1、记忆总结档位 = 0。
- 创建成功前不主动触发云同步；失败 / 取消不会留下书或墓碑。

## 代码地图

| 文件 | 作用 |
|---|---|
| `lib/models/book_creation_draft.dart` | 草稿模型、有效世界书 / 角色类别、`toBook` |
| `lib/services/book_creation/book_creation_step.dart` | 阶段 / 步骤状态 / 用量 / 事件 |
| `lib/services/book_creation/book_creation_prompts.dart` | 系统提示词、各阶段与补充轮提示词 |
| `lib/services/book_creation/book_creation_parser.dart` | 标签解析、可见文本 |
| `lib/services/book_creation/book_creation_runner.dart` | 分步调用、补充轮、取消、用量 |
| `lib/services/book_creation/book_creation_verifier.dart` | 完整性 + 回读 + 提示词生效校验 |
| `lib/services/book_creation/book_creation_writer.dart` | 写库与物理回滚 |
| `lib/screens/agent_book_creation_page.dart` | 输入态 / 创建态、对话框、导航 |
| `lib/widgets/book_creation/` | 输入表单与步骤卡片 |
| `lib/services/mods_bundle_builder.dart` | Mod 四段内容拼接（与 `ModProvider` 共用） |

## 测试

- `test/book_creation_parser_test.dart`：标签解析 / 容错 / Mod 映射 / 可见文本；
- `test/book_creation_prompts_test.dart`：阶段契约、上下文、Mod 目录、补充轮；
- `test/book_creation_runner_test.dart`：顺序、双线路、补充轮、失败 / 截断 / 取消、用量；
- `test/book_creation_verifier_test.dart`：完整性、回读比对、提示词生效校验；
- `test/book_creation_writer_test.dart`：成功落库、保留不完整书、数据库错误物理回滚；
- `test/book_creation_step_card_test.dart`：步骤卡片的运行态流式文本、完成态摘要 / Token、
  展开生成内容、失败原因；
- `test/agent_book_creation_page_test.dart`：输入契约、成功 / 失败 / 不完整 / 取消 /
  数据库错误、成功后的设置页与聊天页导航；
- `test/home_layout_test.dart`：加号菜单两个入口。

## 已知限制

- 创建中途若被外部入口触发云同步，可能留下一次半成品快照；本流程成功前不主动同步。
- 失败不自动重试；回到输入态后重新开始会重新生成全部步骤。
- 补充轮不合并部分世界书：需要模型重新输出完整的 `<worldBook>` / `<roleCategories>`
  块，提示词里已明确要求。
- 本功能不读写「实验性 Agent 模式」档位。
