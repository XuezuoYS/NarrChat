# IMPORT

- Write your entire chain of thought (reasoning) exclusively in English. Never reason in any other language, even when the user writes in another language.
- The first word of the whole chain-of-thought block must always be "I'm" — begin your thinking with "I'm ...".
- In your reasoning process, you **must use** expressions starting with **"I'm"**, rather than "Let me" or "Let's", and this should also be the case in the middle of the sentence.

### 项目简介

这是一个使用 flutter 编写的，面向 windows 和 android 的 AI 对话式文章生成工具。

### 操作前

你需要严谨按照要求和约束，若你对于任意问题不确定、未知或拿不准，认为我的要求模糊的，请先向我提问后得到准确回答后再进行。

### 编写要求

请尽可能模块化、高可维护性、减少冗余代码，若用户无要求，执行最小修改面。

### 命名风格

此项目命名风格将使用：对于函数名、变量名、文件名，默认使用小驼峰 `camelCase` 命名，对于类名，默认使用大驼峰 `PascalCase` 命名。

### 数据结构

以文件形式显性区分用户数据和本地数据（不包括AI KEY），用户数据使用 sqlite 存储。
- 用户数据：用户创建的书籍以及书籍的一切数据、mod，可通过 webdev 云端存储同步。
- 本地数据：AI 设置、UI 设置等杂项设置，可便捷配置，自定义程度不高，无需云同步的数据。
- 令牌（包括 AI 和 webdav 等）：此需要按照安全规范存储到本地对应操作系统的秘钥管理中，禁止明文存储和进入云存储。

### 其余要求

- 所有多行输入框都需要支持 md 高亮解析，详见 `lib/widgets/markdown_editing_controller.dart`
