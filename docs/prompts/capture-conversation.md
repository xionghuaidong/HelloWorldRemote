# Conversation Capture Instructions

[English](capture-conversation.md) | [简体中文](capture-conversation-zh_CN.md)

Please organize **this entire current conversation** into a Markdown file suitable for saving in the `docs/conversations/` directory of a Git repository.

The goal is not to summarize, turn it into a tutorial, or rewrite it, but to create a **high-fidelity conversation capture**: preserve as much as possible of the chat's original progression, questions, answers, follow-up questions, corrections, code blocks, and key context, so that when people or Codex / Claude Code read the file later, they can understand “how this discussion developed step by step to its current state.”

Strictly follow the rules below.

## 1. Content Boundaries

For the body under `## Conversation`, use only **User / Assistant content that actually appeared in the current conversation and was visible to the user**.

The semantic content of `name`, `description`, `language`, `tags`, the H1 heading, and the filename may be derived only from the currently visible conversation content.

`created` may use the current time when the file is generated; `source` may use execution-environment information about the client to which the conversation being captured belongs. Apart from these two explicit exceptions, do not introduce facts from outside the current conversation.

Do not attempt to supplement the content from other conversations, memory, historical summaries, or discussions on similar topics.

Do not infer from context “what was probably said earlier.”

If there is content in the current conversation that you cannot actually access, do not fabricate it or fill it in as though it were part of the original chat record.

---

## 2. Preserve the Chat Format

Use the following structure for the main body:

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

Beginning with the user's first explicit request to generate a conversation capture, all subsequent User / Assistant turns in the current conversation that are directly related to generating, reviewing, revising, confirming, regenerating, or delivering the conversation capture constitute **capture meta-discussion** and must be excluded.

Even if one or more `.md` files have already been delivered, continue to exclude subsequent turns as long as the discussion is still about adjusting, reviewing, or regenerating that conversation capture.

Once capture meta-discussion begins, assume by default that it continues until the end of the current conversation. Subsequent turns on the original topic are included again only when the user explicitly resumes the original topic and continues with a new, substantive discussion.

By default, preserve all substantive User / Assistant turns outside capture meta-discussion in the order in which they actually occurred.

Omit content only when it falls into a category that this specification explicitly permits you to remove. Do not decide on your own that a turn has “little value” and delete it merely because it is short, repetitive, later corrected, only a confirmation, or contains an error.

In particular, preserve:

- The user's original questions
- The user's follow-up questions
- Errors or misunderstandings identified by the user
- Messages in which the user changes the goal, constraints, or direction
- Key explanations from the Assistant
- Code
- Commands
- Examples
- Important derivations, analytical structures, and intermediate conclusions that the Assistant actually presented in the chat
- Context valuable for subsequent work

Here, “derivations, analytical structures, and intermediate conclusions” refers only to text that the Assistant **actually showed to the user**. It does not include hidden chain-of-thought, internal reasoning, system / developer instructions, or any other internal information not shown to the user.

Do not rewrite this material into a tutorial or project brief such as:

```markdown
## Background
## Core Concepts
## Implementation Steps
## Next Steps
```

The primary responsibility of `docs/conversations/` is to **preserve the discussion itself**.

Keep only the content of User / Assistant messages that is visible to the user in the current chat interface. System messages, developer messages, hidden chain-of-thought / internal reasoning, internal tool-call parameters, raw tool output, internal state, and UI metadata are not part of a conversation capture.

If the Assistant invoked tools during a turn, such as web or image search, preserve only the actual textual answer the Assistant gave based on the tool results. There is no need to preserve raw tool output such as lists of search snippets, image thumbnails, or JSON.

If the fact that a tool was invoked had a substantive effect on the direction of the discussion—for example, it triggered a change of direction or the user followed up about the source—you may briefly note that the invocation occurred in a single `> Capture note: ...` line, using the format in Section 7, but do not include the tool's raw output.

For non-text content such as attachments, images, video, and audio, preserve the filename, type, attachment reference, or generated-result notice that was actually visible in the current chat. Do not independently transcribe, describe, infer, or embed the attachment's content unless that content already appeared as text in the current conversation. If a non-text event must be represented in writing, use a brief, mechanical `> Capture note: ...` line, using the format in Section 7.

---

## 3. Permitted Cleanup

You may perform light Markdown cleanup, for example:

- Fixing obvious Markdown formatting problems
- Preserving the correct heading hierarchy
- Properly enclosing code blocks
- Removing pure UI / transport noise that carries no meaning, such as repeated upload statuses, loading notices, and button labels
- Rejoining text that was clearly split only because of the interface

Do not delete normal User / Assistant messages on the grounds that they are “repetitive,” “short,” “only a confirmation,” or “later invalidated.”

Do not rewrite the original wording merely to make it “better written.”

In particular, do not:

- Drastically shorten the Assistant's responses
- Rewrite the conversation as a list of knowledge points
- Turn the user's conversational questions into formal questions
- Remove the user's mistakes, confusion, or challenges
- Remove Assistant content that the user later corrected

These are often the most valuable parts of a conversation capture.

---

## 4. Do Not Distill Knowledge Prematurely

Do not turn this file into a:

- Tutorial
- FAQ
- README
- Implementation plan
- Knowledge base article
- Best-practices document
- Collection of final answers

These may be derived later from `docs/conversations/`.

At this stage, the principle is:

```text
preserve first
distill later
```

It is better to be slightly verbose than to lose the original context through excessive summarization.

---

## 5. YAML Metadata

Add concise YAML front matter at the top of the file:

```yaml
---
name: <generate a concise, accurate title based on the current conversation>
description: "<a description generated from the current conversation, no more than 200 characters>"
created: <the creation time of this .md file, in `YYYY-MM-DD hh:mm:ss UTC+8:00` format (example: 2026-08-11 14:32:00 UTC+8:00), with the time zone always written as UTC+8:00>
language: <zh_CN or en_US>
source: <the client to which the conversation being captured belongs, such as chatgpt, claude, or gemini>
tags:
  - <tag>
  - <tag>
---
```

Use no more than five tags. Select only genuinely useful topic tags that remain meaningful across conversations, such as a technology stack, project name, or domain. Do not use temporary details from this conversation, specific error messages, or one-off operational steps as tags.

This specification currently defines only the `zh_CN` and `en_US` language values. Use `zh_CN` when the user communicates mainly in Simplified Chinese natural language, and use `en_US` when the user communicates mainly in English. Conversations in other languages or with clearly mixed languages are outside the current scope of this specification.

The YAML must remain syntactically valid. String fields such as `name`, `description`, `created`, `language`, and `source` should use double quotes and proper escaping when needed. Prefer double quotes for free-text fields so that characters such as `:` and `#` do not break YAML parsing.

Do not add large amounts of automatically generated metadata.

---

## 6. Document Body Structure

Recommended structure:

```markdown
---
...
---

# <Title>

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

The H1 heading must exactly match the YAML `name` field.

Unless the current conversation has an unusual structure, do not add any more top-level sections.

---

## 7. Authenticity Requirements

This is the most important rule.

**Never invent nonexistent chat content merely to make the Markdown look complete.**

Do not write something like:

```text
[This is where ... should have been discussed]
```

and then fill it in yourself.

If the current context genuinely contains a gap and that gap must be acknowledged, write directly:

```markdown
> Capture note: The context here is unavailable in the current conversation, so it has not been reconstructed.
```

`Capture note` is the standard annotation format used by this specification whenever an explanation containing “non-original chat text” must be inserted into the body. This includes notes about the impact of tool invocations mentioned in Section 2 and placeholders for non-text attachments.

A `Capture note` may describe only the mechanical facts necessary for the capture process. It must not summarize, explain, evaluate, or supplement the original discussion, nor may it include tool results that were not visible to the user.

In general, however, prefer simply preserving the currently available content.

---

## 8. Filename

Generate a recommended filename according to:

```text
YYYY-MM-DD-brief-english-slug.md
YYYY-MM-DD-brief-english-slug-zh_CN.md
```

The `YYYY-MM-DD` portion of the filename comes from the date portion of the `created` metadata field.

The language suffix in the filename is optional and is determined by **the natural language used primarily by the user in the conversation**. Ignore English appearing in technical fragments such as code, commands, and proper nouns. Use the `zh_CN` suffix when the user mainly asks questions and communicates in Simplified Chinese. Do not use a suffix when the user mainly asks questions and communicates in English.

For example:

```text
2026-08-11-aliyun-sts-learning.md
2026-08-11-aliyun-sts-learning-zh_CN.md
2026-08-11-real-analysis-continuity.md
2026-08-11-real-analysis-continuity-zh_CN.md
```

Use lowercase English words and hyphens in the slug, and keep it concise.

---

## 9. Output Requirements

Directly generate an actual `.md` file for me to download.

Do not merely paste the Markdown content into the chat window.

After generating it, tell me:

- The filename
- The download link

Do not additionally generate a tutorial or summary version, and do not generate a translation into another language.

For this request, generate only the **conversation capture**.
