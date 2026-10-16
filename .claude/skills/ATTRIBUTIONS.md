# Attributions

本插件下所有 skill 的来源致谢与许可证信息。

---

## brainstorming

致敬 obra/superpowers 的 brainstorming skill：
https://github.com/obra/superpowers/tree/main/skills/brainstorming/

MIT License · Copyright (c) 2025 Jesse Vincent

当前实现不是逐字搬运，而是面向 GitHub Copilot 的中文化、manual-first、artifact-backed 适配版。

---

## writing-plans

致敬 obra/superpowers 的 writing-plans skill：
https://github.com/obra/superpowers/tree/main/skills/writing-plans/

MIT License · Copyright (c) 2025 Jesse Vincent

当前实现不是逐字搬运，而是面向常见 skills-compatible 编码 runtime 的中文化、manual-first、artifact-backed 适配版。

---

## handoff

致敬以下两个原始来源：

- code-yeongyu/oh-my-openagent 的 handoff command 模板：
  https://github.com/code-yeongyu/oh-my-openagent/blob/dev/src/features/builtin-commands/templates/handoff.ts
  Sustainable Use License (SUL) v1.0 · 显著修改声明：本插件已完成本地化适配，代码结构和行为与原版存在实质差异。
- mattpocock/skills 的 handoff skill：
  https://github.com/mattpocock/skills/blob/main/skills/productivity/handoff/SKILL.md
  MIT License · Copyright (c) 2026 Matt Pocock

当前实现结合两者思路后，做了面向 GitHub Copilot 的中文优先、证据驱动 handoff 适配。

---

## 上游同步 skills（mattpocock/skills）

致敬 mattpocock/skills 的同名 skill：

- grilling: https://github.com/mattpocock/skills/tree/main/skills/productivity/grilling/
- codebase-design: https://github.com/mattpocock/skills/tree/main/skills/engineering/codebase-design/
- domain-modeling: https://github.com/mattpocock/skills/tree/main/skills/engineering/domain-modeling/
- grill-with-docs: https://github.com/mattpocock/skills/tree/main/skills/engineering/grill-with-docs/
- improve-codebase-architecture: https://github.com/mattpocock/skills/tree/main/skills/engineering/improve-codebase-architecture/
- retro: https://github.com/mattpocock/skills/tree/main/skills/engineering/retro/
- writing-for-agents: https://github.com/mattpocock/skills/tree/main/skills/productivity/writing-for-agents/

MIT License · Copyright (c) 2026 Matt Pocock

这七个 skills 由本目录的 `update.sh` 从 mattpocock/skills 上游原样同步（英文、标准 SKILL.md），保留上游格式、不做中文化适配——Claude Code 与 GitHub Copilot 均直接加载 `.claude/skills` 下标准 SKILL.md，英文原版两个 runtime 均可用。

---

## 许可证全文

### MIT License (obra/superpowers, mattpocock/skills)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### Sustainable Use License v1.0 (code-yeongyu/oh-my-openagent)

该仓库采用 Sustainable Use License (SUL) v1.0，允许个人、非商业或内部业务使用，禁止转授权。
修改后的副本必须包含显著通知，声明已对软件进行了修改。
完整许可证文本见：https://github.com/code-yeongyu/oh-my-openagent/blob/dev/LICENSE