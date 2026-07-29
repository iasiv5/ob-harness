# CLI 交互 prompt 卡壳：读逃生路径，别逐行回答

## TL;DR

遇到 CLI（含 `ob`）交互菜单 / 选择 prompt 卡壳时，**第一反应是"这个 prompt 怎么绕过"而非"怎么回答"**——用 `--flag` / ENV_VAR 一步跳过，不要用 `send_to_terminal` 逐行喂答案。两条最该先知道的：(1) 先逐字重读 prompt 文本 / 上一条报错——设计良好的 CLI 会在里面直接写逃生路径（ob 的惯例：非交互遭 prompt 时 exit 3 并打印带字面 flag 的 remedy line）；(2) `ob` 的 prompt 几乎总有 flag / ENV_VAR 绕过（`--url` / `OB_OPENBMC_URL` / `--force`），无 TTY 时裸跑 `ob init` 直接 exit 3、**不会**替你选菜单——两种场景都要显式给 flag。决策顺序见 §通用决策框架。

## 元数据

- **类型**: BestPractice
- **适用场景**: agent 调用 `ob` 或其他 CLI 时遇到交互式菜单 / 选择 prompt 卡住，想用 `send_to_terminal` 逐行喂答案时
- **创建日期**: 2026-07-28
- **来源**: `ob init gb200nvl-obmc` 卡在 `Choose [1/2/Q]` 源码选择菜单，agent 反复想着怎么回答菜单而非一步跳过

---

## 核心盲点

**遇到 CLI 交互 prompt 卡壳时，第一反应是"我怎么把这个菜单的回答喂进去"（逐行 send_to_terminal、甚至纠结选 1 还是 2），而不是"这个 prompt 自己有没有告诉我怎么绕过它"。**

几乎所有设计良好的 CLI（包括 `ob`）在检测到无法交互 / 非交互场景时，**会在 prompt 文本或报错信息里直接给出逃生路径**——通常是 `--flag` 或环境变量。agent 要做的不是当一个人肉菜单选择器，而是读这条提示，用参数一步跳过整个交互环节。

---

## 具体案例：ob init 源码选择菜单

### 现象

`ob init gb200nvl-obmc` 在还没有克隆社区仓库时弹出：

```raw
Select the OpenBMC source repository:
  1) Community (https://github.com/openbmc/openbmc.git)
  2) Custom repository URL
  Q) Quit source selection (q/Q)
ob-harness> Choose [1/2/Q]:
```

### 逃生路径（prompt 自身已经告诉你）

`/bmc/iasi/ob-harness-community/lib/repo.sh` 中，当 stdin 不可读时 `ob` 自己打印的提示：

```raw
Use --url <url> or set OB_OPENBMC_URL in non-interactive mode.
```

### 正确做法

- **⚠️ `ob` 不会在无 stdin 时自动选社区**：`lib/repo.sh:select_openbmc_repo_url` 在 stdin 不可读时直接 `exit 3`。两种真实场景分开处理：非交互（CI/无 TTY）→ ob 打印 `Use --url <url> or set OB_OPENBMC_URL in non-interactive mode.` 后 exit 3，不会替你选菜单；有 TTY（集成终端/人工）→ 菜单正常弹出等待。两种场景想稳定跳过都要显式给 flag（见下）。

- **需要走通非交互**（确保不被任何 prompt 卡住）→ 两条等效路径，任选其一：

```bash
# 路径 A：--url flag（最直接）
ob init gb200nvl-obmc --url https://github.com/openbmc/openbmc.git

# 路径 B：环境变量（适合脚本 / CI）
OB_OPENBMC_URL=https://github.com/openbmc/openbmc.git ob init gb200nvl-obmc
```

### 错误做法

- ❌ 用 `send_to_terminal` 逐行发送 "1\n" 去回答菜单——这是把 agent 当人肉选择器，脆弱、慢、且偏离 ob 设计意图。
- ❌ 卡在菜单前反复思考"选 1 还是 2"而不去读 prompt 自带的逃生提示。
- ❌ 把交互 prompt 当成"必须回答的问题"，而不是"可以一步绕过的环节"。

---

## 通用决策框架

遇到**任何** CLI 交互 prompt 卡壳时，按此顺序：

```text
CLI 弹出交互菜单 / 等待输入
    │
    ├─ 第一反应：不要逐行回答！打开第二个视角——"这个 prompt 怎么绕过"
    │
    ├─ Step 1：重读 prompt 文本 / 上一条报错信息
    │           设计良好的 CLI 会在文本里直接写逃生路径
    │           （ob 的惯例：Non-interactive 遭遇 prompt 时 exit 3 并打印 remedy line，
    │            line 里就有字面的下一条命令 / 需要的 flag）
    │     │
    │     └─ 找到 --flag 或 ENV_VAR → 直接用，一步跳过
    │
    ├─ Step 2：查 --help / 子命令 --help
    │           看 Global Options / 子命令 Options 里有没有非交互参数
    │           （ob init 的 --url、OB_OPENBMC_URL 就是这里来的）
    │
    ├─ Step 3：读源码中 prompt 前后的 if 分支
    │           看它在什么条件下走交互 / 什么条件下自动跳过
    │           （lib/repo.sh 里 `if [[ -n $OB_OPENBMC_URL ]]` 就是非交互逃生分支）
    │
    └─ 只有以上都找不到逃生路径，才考虑 send_to_terminal 逐行回答
        （此时是 CLI 设计缺陷，值得记录为 ob 待补项）
```

---

## ob 的交互 prompt 设计惯例（帮助快速判断）

`ob` 的 prompt 不是随机出现的，它遵循固定模式：

| prompt 出现条件 | 逃生路径 | 典型场景 |
|----------------|---------|---------|
| 缺前置（无 machine / 未 init / 未 build）| exit 3 + remedy line，字面给下一条 `ob` 命令 | 跑 `ob build` 但没 init 过 |
| 需要选择 / 确认且有 TTY | `--force` / `--url` / 显式参数绕过 | `ob start-qemu` 问是否杀现有实例 |
| stdin 不可读（无 TTY、非交互）| `ob` 自己打印 `Use --flag or set ENV_VAR` 然后 exit 3 | CI / agent 调用场景 |

**判断要点**：`ob` 的 prompt 几乎总有 flag 或 ENV_VAR 可以一步绕过。找不到时，读 `lib/*.sh` 里 prompt 文本前后的 `if` 分支，逃生分支就在旁边。

---

## 验收标准

- 遇到 CLI 交互 prompt 时，**第一反应**是"怎么绕过"而非"怎么回答"。
- 在考虑 `send_to_terminal` 逐行喂答案之前，已经至少检查过：prompt 文本 / 报错信息中的逃生提示、`--help` 的非交互选项、源码中 prompt 附近的条件分支。
- `ob` 的 prompt 卡壳时，优先用 `--url` / `OB_OPENBMC_URL` / `--force` 等参数跳过，而非逐行交互。
- 每次绕过 `ob` 的 prompt 后，确认绕过方式是 `ob` **自己文档化的逃生路径**（flag / ENV_VAR），不是外部 hack；若是后者，记录为 `ob` 待补项。

## 已知陷阱

| 陷阱 | 表现 | 应对 |
|------|------|------|
| 把 prompt 当"必须回答的问题" | agent 卡在菜单前，反复想选 1 还是 2，不去找逃生路径 | 视角转换：prompt 是可绕过的障碍，不是必答题 |
| 逐行 send_to_terminal 喂菜单答案 | 脆弱、慢、需要精确时序、偏离 CLI 设计意图 | 先找 --flag / ENV_VAR 一步跳过；只有 CLI 确无逃生路径时才逐行喂 |
| 忽略 prompt / 报错文本里的逃生提示 | `ob` 自己写了 `Use --url or set OB_OPENBMC_URL`，agent 却没读进去 | 遇到 prompt 时**先逐字重读 prompt 和上一条报错**，再决定下一步 |
| 裸跑 `ob init` 期望它自动选社区 | 无 TTY 时 `ob` 直接 exit 3（不替你选菜单），有 TTY 时卡在 `Choose [1/2/Q]` | 两种场景都要显式给 `--url` / `OB_OPENBMC_URL` 才能稳定跳过 |

## 与现有 know-how 的关系

- **[ob 优先](bestpractice_06-ob_first.md)**：本文件是 ob_first 的补充——ob_first 解决"该不该手动兜底"，本文件解决"遇到 ob 的交互 prompt 怎么高效跳过而不是卡壳"。两者配合：ob 优先走 `ob`，遇到 prompt 用 flag 绕过，而不是转手动。
- **[AI 辅助调试诊断](bestpractice_03-ai_debugging_diagnosis.md)**：本文件的根因分析思路（"问题不在 CLI，在 agent 的工作盲点"）与其一致。
