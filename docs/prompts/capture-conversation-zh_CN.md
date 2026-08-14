# 会话捕获说明

[English](capture-conversation.md) | [简体中文](capture-conversation-zh_CN.md)

请把**当前这整个会话**整理成一个适合保存到 Git 仓库 `docs/conversations/` 目录中的 Markdown 文件。

目标不是总结、教程化或重写，而是制作一份**高保真的 conversation capture**：尽量保留这次聊天本来的推进过程、问题、回答、追问、纠正、代码块和关键上下文，使以后的人或 Codex / Claude Code 阅读这个文件时，能够理解“这场讨论是怎样一步步发展到现在的”。

请严格遵守以下规则。

## 1. 内容边界

对于 `## Conversation` 正文，只使用**当前会话中真实出现过、且对用户可见的 User / Assistant 内容**。

`name`、`description`、`language`、`tags`、H1 标题和文件名中的语义内容，只能根据当前可见会话内容派生。

`created` 可以使用生成文件时的当前时间；`source` 可以使用当前被 capture 的会话所属客户端这一执行环境信息。除这两个明确例外外，不得引入当前会话之外的事实。

不要尝试从其他会话、记忆、历史摘要或类似主题的讨论中补充内容。

不要根据上下文猜测“之前大概说过什么”。

如果当前会话中某些内容你实际上无法访问，就不要伪造，也不要补写成看似原始的聊天记录。

---

## 2. 保留聊天形态

主体使用：

```markdown
## Conversation

### User

...

### Assistant

...

### User

...

### Assistant

...
```

从用户第一次明确提出生成 conversation capture 开始，此后当前会话中所有与 conversation capture 的生成、review、修改、确认、重新生成或交付直接相关的 User / Assistant 回合，均属于 **capture meta-discussion**，应排除。

即使已经交付过一个或多个 `.md` 文件，只要后续讨论仍是在调整、review 或重新生成该 conversation capture，这些后续回合也继续排除。

capture meta-discussion 一旦开始，默认持续到当前会话结束；只有当用户明确恢复原始主题并继续进行新的、有实质内容的讨论时，后续原始主题回合才重新纳入 capture。

按照真实发生顺序，默认保留 capture meta-discussion 之外所有有实质内容的 User / Assistant 回合。

只有符合本规范明确允许删除的类别时才可以省略；不要仅因为某个回合很短、重复、后来被纠正、只是确认或包含错误，就自行判断它“价值不高”而删除。

重点保留：

- 用户原始问题
- 用户的追问
- 用户指出的错误或误解
- 用户修改目标、约束或方向的消息
- Assistant 的关键解释
- 代码
- 命令
- 示例
- Assistant 在聊天中实际展示出来的重要推导、分析结构和中间结论
- 对后续工作有价值的上下文

这里的“推导、分析结构和中间结论”仅指 Assistant **实际展示给用户的文本**，不包括隐藏的 chain-of-thought、internal reasoning、system / developer instructions 或其他未展示给用户的内部信息。

不要把这些重新改写成：

```markdown
## 背景
## 核心概念
## 实现步骤
## 下一步
```

之类的教程或 project brief。

`docs/conversations/` 的首要职责是**保存讨论本身**。

只保留当前聊天界面中对用户可见的 User / Assistant 消息内容。system message、developer message、隐藏的 chain-of-thought / internal reasoning、内部工具调用参数、工具原始返回内容、内部状态和 UI metadata 均不属于 conversation capture。

如果某个 Assistant 回合中调用了工具（网页搜索、图片检索等），只保留 Assistant 基于工具结果给出的实际文本回答，不需要保留工具调用的原始返回内容（搜索片段列表、图片缩略图、JSON 等）。

如果工具调用这件事本身对讨论走向有实质影响（例如触发了方向调整、用户对此追问来源），可以用一句 `> Capture note: ...`（格式见第7节）简要说明发生过这次调用，但不展开工具的原始输出。

对于附件、图片、视频、音频等非文本内容：保留当前聊天中实际可见的文件名、类型、附件引用或生成结果提示；不要自行转录、描述、猜测或嵌入附件内容，除非这些内容本身已经以文本形式出现在当前会话中。若必须用文字表示某个非文本事件，使用简短、机械性的 `> Capture note: ...`（格式见第7节）。

---

## 3. 可以做的清理

可以进行轻量 Markdown 清理，例如：

- 修复明显的 Markdown 格式问题
- 保留正确的标题层级
- 正确围住代码块
- 去掉不承载语义的纯 UI / transport 噪音，例如重复的上传状态、加载提示、按钮文本等
- 合并明显因为界面原因而断开的同一段文字

不得以“重复”“简短”“只是确认”“后来失效”等理由删除正常 User / Assistant 消息。

但不要为了“写得更好”而改写原句。

尤其不要：

- 大幅缩写 Assistant 的回答
- 把会话改写成知识点列表
- 把用户的口语问题改成正式问题
- 删除用户犯错、困惑、反问的过程
- 删除 Assistant 后来被用户纠正的内容

这些往往正是 conversation capture 最有价值的部分。

---

## 4. 不要提前知识蒸馏

不要把这份文件变成：

- 教程
- FAQ
- README
- implementation plan
- knowledge base article
- 最佳实践文档
- 最终答案合集

这些可以以后从 `docs/conversations/` 派生。

当前阶段原则是：

```text
preserve first
distill later
```

宁可稍微冗长，也不要因为过度总结而失去原始上下文。

---

## 5. YAML metadata

文件顶部加入简洁的 YAML front matter：

```yaml
---
name: <根据当前会话生成一个简洁准确的标题>
description: "<根据当前会话生成的描述，不超过 200 字>"
created: <此 .md 文件的创建时间，格式 `YYYY-MM-DD hh:mm:ss UTC+8:00`（示例：2026-08-11 14:32:00 UTC+8:00），时区固定写 UTC+8:00>
language: <zh_CN 或 en_US>
source: <当前被 capture 的会话所属客户端，例如 chatgpt、claude、gemini>
tags:
  - <tag>
  - <tag>
---
```

tags 最多 5 个，只选择真正有用、跨会话仍然成立的主题标签（例如涉及的技术栈、项目名、领域），不要把这次会话里的临时细节、具体报错信息、一次性操作步骤当作标签。

当前规范只定义 `zh_CN` 和 `en_US` 两种语言值。若用户在会话中主要使用简体中文自然语言交流，则使用 `zh_CN`；若主要使用英文，则使用 `en_US`。其他语言或明显混合语言会话不在本规范当前定义范围内。

YAML 必须保持语法合法。`name`、`description`、`created`、`language`、`source` 等字符串字段应在需要时使用双引号并正确转义；自由文本字段优先使用双引号，避免 `:`、`#` 等字符破坏 YAML 解析。

不要加入大量自动生成的 metadata。

---

## 6. 文件正文结构

推荐结构：

```markdown
---
...
---

# <标题>

## Conversation

### User

...

### Assistant

...

### User

...

### Assistant

...
```

H1 标题必须与 YAML `name` 字段完全一致。

除非当前会话结构特殊，否则不要增加更多顶层章节。

---

## 7. 对真实性的要求

这是最重要的一条。

**绝对不要为了让 Markdown 看起来完整而创造不存在的聊天内容。**

不要出现类似：

```text
[这里应该讨论过……]
```

之后再自己补写。

如果当前上下文确实存在缺口，而且这个缺口必须说明，可以直接写：

```markdown
> Capture note: 此处上下文在当前会话中不可用，因此未补写。
```

`Capture note` 是本规范统一使用的标注格式，用于所有需要在正文中插入“非原始聊天文本”说明的情况（包括第2节提到的工具调用影响说明、非文本附件占位）。

`Capture note` 只能描述捕获过程中必要的机械性事实，不得总结、解释、评价或补充原始讨论内容，也不得写入用户不可见的工具结果。

但通常优先只保存当前实际可见内容即可。

---

## 8. 文件名

根据：

```text
YYYY-MM-DD-brief-english-slug.md
YYYY-MM-DD-brief-english-slug-zh_CN.md
```

生成推荐文件名。

文件名中的 `YYYY-MM-DD` 取自 metadata 中 `created` 字段的日期部分。

文件名中语言后缀是可选的，判断依据是**用户在会话中主要使用的自然语言**（不考虑代码、命令、专有名词等技术片段中出现的英文）：用户主要用简体中文提问和交流的会话使用 `zh_CN` 后缀，用户主要用英文提问和交流的会话不使用后缀。

例如：

```text
2026-08-11-aliyun-sts-learning.md
2026-08-11-aliyun-sts-learning-zh_CN.md
2026-08-11-real-analysis-continuity.md
2026-08-11-real-analysis-continuity-zh_CN.md
```

slug 使用小写英文和连字符，保持简洁。

---

## 9. 输出要求

直接生成一个真正的 `.md` 文件供我下载。

不要只把 Markdown 内容贴在聊天窗口里。

生成后告诉我：

- 文件名
- 下载链接

不要额外生成教程版或总结版，也不要生成其他语言的翻译版。

这一次只生成 **conversation capture**。
