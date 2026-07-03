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

## cleanup

致敬 KKKKhazix `neat-freak` 的核心思想：
https://github.com/KKKKhazix/khazix-skills/tree/main/neat-freak

MIT License · Copyright (c) 2026 数字生命卡兹克 (Digital Life Khazix)

继承了以下设计理念：
- 你是知识编辑，不是记录员
- 长期知识要保持准确、简洁、可复用
- 清理动作要优先考虑删旧、合并和纠偏，而不是一味追加
- 规则层也会过期，规范执行审计要区分安全自动修复和需要用户拍板的破坏性动作

当前实现围绕 GitHub Copilot 做了本地化改造，重点解决 handoff 与长期沉淀之间的职责边界。

---

## grilling / codebase-design / domain-modeling / grill-with-docs / improve-codebase-architecture

致敬 mattpocock/skills 的同名 skill：

- grilling: https://github.com/mattpocock/skills/tree/main/skills/productivity/grilling/
- codebase-design: https://github.com/mattpocock/skills/tree/main/skills/engineering/codebase-design/
- domain-modeling: https://github.com/mattpocock/skills/tree/main/skills/engineering/domain-modeling/
- grill-with-docs: https://github.com/mattpocock/skills/tree/main/skills/engineering/grill-with-docs/
- improve-codebase-architecture: https://github.com/mattpocock/skills/tree/main/skills/engineering/improve-codebase-architecture/

MIT License · Copyright (c) 2026 Matt Pocock

这五个 skill 由本目录的 `update.sh` 从 mattpocock/skills 上游原样同步（英文、标准 SKILL.md），保留上游格式、不做中文化适配——Claude Code 与 GitHub Copilot 均直接加载 `.claude/skills` 下标准 SKILL.md，英文原版两个 runtime 均可用。

---

## 许可证全文

### MIT License (obra/superpowers, mattpocock/skills, KKKKhazix/khazix-skills)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

### Sustainable Use License v1.0 (code-yeongyu/oh-my-openagent)

该仓库采用 Sustainable Use License (SUL) v1.0，允许个人、非商业或内部业务使用，禁止转授权。
修改后的副本必须包含显著通知，声明已对软件进行了修改。
完整许可证文本见：https://github.com/code-yeongyu/oh-my-openagent/blob/dev/LICENSE