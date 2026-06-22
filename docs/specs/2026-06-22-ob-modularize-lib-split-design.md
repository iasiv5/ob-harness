# ob 单文件深化为分区 sourced 模块 设计文档

> 状态：🔴 待审批 v2.1（已吸收一审 7 条 + 二审 2 条反馈，待最终批准进 writing-plans）
> 日期：2026-06-22
> 关联：`CONTEXT.md`（function semantic layer / test layer）、ADR-0003（ob-first）、`contexts/memory/OBSERVATIONS.md`（06-16 exit 纪律重构）

---

## 修订记录（v1 → v2，对应审核反馈）

| # | 审核项 | 修订内容 | 落点 |
|---|---|---|---|
| 🔴1 | `detect_harness_root` 的 `${BASH_SOURCE[0]}` | 入口 ob 在 source lib 前算 `OB_ENTRY_DIR`；`detect_harness_root` 改用它而非自己的 `${BASH_SOURCE[0]}`；删除文档里错误的 `source "$(dirname "$0")/lib/..."` | 关键边界、数据流、错误处理 |
| 🔴2 | integration 测试只 cp ob | integration harness 必须成套复制 `ob + lib`，列为硬验收 | 测试策略、错误处理 |
| 🟡1 | ob_check 多文件验收 | 新增 `OB_SOURCES` 契约段：定义扫描源、shellcheck 多文件、baseline multiset、extract_funcs per-file GAPS、**lib 零顶层语句规则** | 测试策略 |
| 🟡2 | exit_contract Y-c 单测 fixture | Y 按 basename(`util.sh`) 判定；单测改迷你目录树（`$TMP/lib/util.sh` + ob 桩） | 测试策略 |
| 🟡3 | source 顺序拓扑依据 | 删除"source 顺序有拓扑依据"的错误表述；改为"顺序刻意不承载依赖语义，靠 ob_check 保证 lib 纯函数定义"；**拒绝编号前缀**（YAGNI + 破坏文件名语义） | 数据流 |
| 🟢1 | 不自动 commit | 每步是"可独立验证的逻辑单元"，commit 由用户决定，agent 不自动 commit | 实施路径 |
| 🟢2 | reorder 归档 + 清理引用 | 归档 `tools/archive/`，从 ob_check/tests/WORKSPACE/rules 移除现役门禁引用 | 实施路径、未决事项 |
| 🟡1′（二审）| footer 顶层语句漏检 | lib 零顶层语句规则改为**三段闭环**（header/函数间/footer），堵上"末尾追加顶层语句、source 时执行"的漏检口子 | 测试策略 OB_SOURCES 契约 |
| 🟢1′（二审）| OB_SOURCES 等价注释不严谨 | "等价"改为"同一文件集合，顺序不承载语义"（ob+lib 与 lib+ob 不承载语义） | 测试策略 OB_SOURCES 契约 |
| 🔴（三审）| per-file shellcheck SC2034 假阳 + 文件感知 baseline 搬迁误报 | shellcheck 改合成 flat 输入；baseline 纯文本 multiset（非文件感知）；文件路径/行列号不参与 baseline key | 测试策略 OB_SOURCES 契约 |

---

## 背景与目标

### 现状

`ob` 是一个 **4251 行 / 93 函数 / 5 命令 + menu** 的单文件 shell 脚本（仓库根 `ob`）。它内部已有 §1–§7 概念分区（靠 `# === §n ...` 注释锚点标识），但这些分区**只是注释，不是结构边界**。

维持这些分区"连续、可重排、exit 归属正确"的全部重量，压在 `tools/` 下三个外部 Python 工具上：

| 工具 | 维持的纪律 | 机制 |
|---|---|---|
| `extract_funcs.py` | `GAPS=0`（函数间不夹顶层语句，是重排等价的前提） | 扫单文件函数边界 |
| `reorder.py` | §2–§7 物理分区连续 | **93 个函数手写 `sections` dict** + `assert set(order)==classified` |
| `exit_contract.py` | exit 纪律 X/Y/Z | X=字面 exit∈{0,1,2,3}；Y=§2 函数绝不 exit（靠 §2 注释锚点定位）；Z=exit-3 remedy |

`ob_check.sh` 聚合三者 + shellcheck baseline + `run_all`，是这套工具矩阵的统一入口。

### 问题（deletion test 三连过）

对三个工具逐一做 deletion test——"删掉它，复杂度是集中还是只是挪走"：

- 删 `reorder.py` → 93 个函数的 § 归类靠人眼维持，加函数忘归位就漂移。**复杂度集中**。
- 删 `extract_funcs.py` → `GAPS=0`（重排前提）无法机器校验。**复杂度集中**。
- 删 `exit_contract.py` → exit 纪律靠人肉遵守。**复杂度集中**。

三个工具全是对抗 **ob 单文件过大** 这个根因的**症状治疗**，不是治愈。`ob_check.sh` 本身就是症状之一——OBSERVATIONS 记录它起源于"06-20 加 host key 双轨检测**漏同步 CI 配套**，被用户指出后才补"。漏同步已经发生过一次。

### 目标

把**模块化的载体**从 `reorder.py` 的 `sections` dict（易腐、要手动同步、要工具矩阵校验）挪到**文件系统结构**（自描述、零同步成本、文件名即归类）。这是 deep module 深化的标准动作：让本应由结构边界承担的纪律，回归到结构边界。

### 成功标准

1. `ob` 退化为入口（§1 全局变量 + `OB_ENTRY_DIR` + §7 `parse_args`/`usage`/`main` + `source lib/*.sh`）。
2. §2–§6 物化为 `lib/{util,repo,qemu,init_pipeline,commands}.sh`，函数体一字不动（`detect_harness_root` 除外：改用 `OB_ENTRY_DIR`，见 🔴1）。
3. `reorder.py` 归档退役（使命由文件边界接管）。
4. `exit_contract.py` 多文件化，Y 规则从"§2 注释段"落到"`util.sh` 文件 basename 归属"。
5. `ob` 行为完全不变：`./ob` 执行、agent 调用、exit-code 契约、remedy line、init-done marker 全部不变。
6. 全套测试（protocol/unit/orchestration/integration）绿，含 integration harness 成套复制 `ob + lib`。
7. §3→§5 反向耦合消除，依赖收敛为单向链 `§6 cmd → §5 init → §3 repo → §2 util`。

---

## 范围

- 把 `ob` 拆为入口 + `lib/*.sh`（6 个文件，§2–§7 一一对应）。
- 消除 §3→§5 反向耦合（`require_openbmc_repo` 调 `clone_openbmc`）。
- `exit_contract.py` / `ob_check.sh` / `extract_funcs.py` 适配多文件。
- `reorder.py` 归档到 `tools/archive/`，并从现役门禁引用中移除。
- `tests/lib/ob_loader.sh` 适配（前提：source 路径用入口文件位置，见数据流）。

## 非范围

- **§4 QEMU 二次切分**：1200 行仍偏大，但内聚（binary/firmware/ports/SoC/pid/hostkey），留作后续独立决策。
- **`clone_openbmc` 幂等检查清理**：内部 `[ob:2343-2347]` 与 `require_openbmc_repo` 重复的"已存在跳过"分支，在当前路径下是事实死代码，**保留**为防御性。
- **`require_path` 归属调整**：留 `lib/util.sh`。
- **ob 功能变更**：纯结构物理搬迁，零行为变化。
- **新增子命令**。

---

## 方案比较

本设计有六个独立决策点，逐一比较。每个都已和用户 grilling 确认。

### 决策 1 · 切分粒度：A1 vs A2

**方案 A1（推荐）**：§2–§7 一一对应，6 个文件。
- 优点：与 `reorder.py` 的 `sections` dict 一一对应，迁移是"把 dict 每个 section 落成同名文件"，零新判断。
- 缺点：§4（1200 行）未二次切，单文件仍偏大。

**方案 A2**：本轮就把 §4 再切。
- 否决：引入新切分判断，叠加在机制切换风险上；§4 内聚，硬切可能割断。

### 决策 2 · §3→§5 耦合处理：方案 1 vs 改归属

事实：`require_openbmc_repo`（§3，[ob:948-958]）混合了"检查 repo 存在"和"不存在就 clone（§5 `clone_openbmc`）"两个职责。

**方案 1（推荐）· 检查与执行分离**：
```bash
# §3 lib/repo.sh —— require_openbmc_repo 退回纯检查 + 信号
require_openbmc_repo() {
    if [[ -d "$OPENBMC_DIR/.git" ]]; then ...; verify_source; return 0; fi
    info "..."; return 3   # repo 未就绪 → 信号交给调用方
}
# §6 lib/commands.sh, cmd_init —— 编排
require_openbmc_repo || clone_openbmc
```
- 优点：修了职责混合；依赖收敛为单向 `§6→§5→§3→§2`。
- **行为等价已论证**：`clone_openbmc` 失败靠显式 `exit 1`（[ob:2360]），不依赖 `set -e`，故 `|| clone_openbmc` 吞不掉它的失败。

**方案 2/3（改归属）**：否决——会混淆"解析"与"执行"的层级。

### 决策 3 · 纪律迁移形态：B1 vs B3

**方案 B1（推荐）**：`exit_contract.py` 内部一次吃下 `ob + lib/*.sh`，建全函数表，X/Y/Z 在全表跑。

**方案 B3**（外层 per-file 循环）：否决——Z 规则要扫 `require_path` 调用点，实测跨 4 文件（repo/qemu/init_pipeline/commands），定义在 util.sh；`direct exit 3` 同跨 4 文件。per-file 循环切碎 Z 的全局上下文。

### 决策 4 · 文件发现：glob vs 硬编码

**glob（推荐）**：`sorted(glob('lib/*.sh')) + ['ob']`。新 lib 文件自动纳入，零同步。

**硬编码**：否决——= `sections` dict 转世。

### 决策 5 · Y 规则"§2"定义：Y-c vs Y-b

**Y-c（推荐）· 文件 basename 归属**：Y 语义为"basename 为 `util.sh` 的文件里所有函数（除 EXIT_EXCEPTIONS）不 exit"，`find_section_range` 退役。
- 优点：文件名是结构事实不漂移；符合深化命题。
- 连带：报错文案"§2"→"`util.sh`"；`EXIT_EXCEPTIONS` 逻辑不变。

**Y-b（保留注释锚点）**：否决——被工具依赖的注释锚点是负债。

### 决策 6 · 迁移路径：D2 vs D1

**D2（推荐）· 渐进搬迁**：分阶段，每阶段全绿、每步是一个可独立验证的逻辑单元。
- 优点：可精确回退；每步验证；高风险集中第 1 步、之后纯机械。

**D1（大爆炸）**：否决——6 个 § 同时动 + 机制切换叠加，错误难定位。

---

## 推荐方案

**A1 + 方案 1 + B1/glob/Y-c + D2**。

主要 trade-offs：本轮接受 §4 仍为单文件（1200 行），换取"机制切换风险集中、可逐步验证"；§4 二次切作为后续独立决策。

---

## 关键边界与组件职责

拆分后的文件清单（函数数/行数实测自 `ob` §1–§7 物理分区）：

| 文件 | 来源 § | 行数 | 函数数 | 职责 |
|---|---|---|---|---|
| `ob`（入口） | §1 + §7 | ~250 | 3 | 全局变量 + `OB_ENTRY_DIR`（source lib 前算） + `parse_args`/`usage`/`main` + `source "$OB_ENTRY_DIR"/lib/*.sh` |
| `lib/util.sh` | §2 | ~560 | 28 | 通用工具 L3。**注意 `detect_harness_root` 改用 `OB_ENTRY_DIR`**（不再用自己的 `${BASH_SOURCE[0]}`，见 🔴1） |
| `lib/repo.sh` | §3 | ~473 | 13 | 仓库与 machine 解析（含解耦后的 `require_openbmc_repo`） |
| `lib/qemu.sh` | §4 | ~1200 | 29 | QEMU binary/firmware/ports/SoC/pid/hostkey |
| `lib/init_pipeline.sh` | §5 | ~617 | 9 | init 流水线（`clone_openbmc`/`generate_lockfile`/...） |
| `lib/commands.sh` | §6 | ~1145 | 10 | `cmd_*` 编排（exit seam） |

**`lib/*.sh` 文件头部约定**：`#!/usr/bin/env bash` + 一行"本文件是 ob 的 §X 分区，被 ob source"注释。**不写 `set -euo pipefail`**（被 ob source 时 ob 第 4 行已 set；被测试单独 source 时测试自控 errexit）。

**🔴1 · `detect_harness_root` 的 BASH_SOURCE 陷阱**：现状 [ob:332] `script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`。`${BASH_SOURCE[0]}` 在函数内指向**定义该函数的文件**——一旦 `detect_harness_root` 定义在 `lib/util.sh`，它会算成 `.../ob-harness/lib`，导致 `HARNESS_ROOT`/`WORKSPACE_DIR`/`OPENBMC_DIR`/`CONFIGS_DIR` 全盘偏移。修订：入口 ob 在 source lib **之前**算 `OB_ENTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`（入口顶层的 `${BASH_SOURCE[0]}` 在 `./ob` 执行和 `source "$OB"` 两种路径下都指向 ob 自己）；`detect_harness_root` 改 `HARNESS_ROOT="$OB_ENTRY_DIR"`。

---

## 数据流 / 控制流

### source 链

```
./ob 执行
  → ob 第 4 行 set -euo pipefail
  → §1 全局变量 + OB_ENTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"   # source lib 前算好
  → for f in "$OB_ENTRY_DIR"/lib/*.sh; do source "$f"; done                       # 绝对路径,不靠 $0/HARNESS_ROOT
  → §7 main "$@"（OB_NO_MAIN 守卫）
```

**不用 `$0` 或 `$HARNESS_ROOT` 定位 lib**（审核 🔴1 指出）：`$0` 在 `source "$OB"` 测试路径下是调用者不是 ob；`$HARNESS_ROOT` 在 source lib 时（`detect_harness_root` 未跑）尚未初始化。两者都不可靠，统一用 `OB_ENTRY_DIR`。

### 顺序无关性的保证（关键）

bash 函数物理顺序不影响执行（调用都在 `main` 里）。`extract_funcs.py` 当前测出 `GAPS=0`。每个 `lib/*.sh` 只贡献**函数定义**、source 时不执行任何东西、无副作用。source 顺序只影响"定义是否齐了"，不影响执行语义。**这与 `reorder.py` 已三重验证（`bash -n` / `declare -f` diff / 冒烟）的"重排即等价"是同一性质**，只是从"块内换序"升级到"块间分文件"。

**🟡3 · source 顺序刻意不承载依赖语义**：`sorted(glob('lib/*.sh'))` 字母序是 `commands→init_pipeline→qemu→repo→util`，**不是**依赖拓扑序。这是**故意的**，不是缺陷——靠 ob_check 强制保证 lib 纯函数定义（GAPS=0 + 零顶层语句，见 OB_SOURCES 契约），故 source 顺序与执行语义无关，字母序足够。**不采用编号前缀**（`02_util.sh` 等）：顺序既然不承载语义，用文件名编码一个不存在的约束是 YAGNI 违反，且破坏文件名纯语义、降 AI-navigability（本次深化的核心目标之一）。拓扑只用于"搬迁顺序"和"阅读理解"，不用文件名编码。

### 依赖方向（方案 1 后，单向链）

```
§6 cmd ──► §5 init ──► §3 repo ──► §2 util
   │            │
   └────────────┴──► §4 qemu ──► §2 util
```

实测干净（grep 跨层调用）：§2 util 不调任何上层；§4 qemu 不调 §5/§6；方案 1 消除 §3→§5 后整条链单向。

### `ob_loader` 适配

`tests/lib/ob_loader.sh` 第 9 行 `OB_NO_MAIN=1 source "$OB"`——它 source 的是 `ob` 入口，入口自己 `source "$OB_ENTRY_DIR"/lib/*.sh` 把函数拉进来。拆分后 `ob_loader` 的加载路径**不变**（前提：source 用 `OB_ENTRY_DIR` 即入口文件位置，不是 `$0` 或未初始化的 `HARNESS_ROOT`——已在上文保证）。

---

## 错误处理与回退

### 迁移风险与对应策略

| 风险 | 策略 |
|---|---|
| 🔴1 `detect_harness_root` 搬 lib 后 `${BASH_SOURCE[0]}` 算错根 | 入口算 `OB_ENTRY_DIR`，`detect_harness_root` 改用它；第 1 步 `bash -n` + 冒烟 + integration 验证 `HARNESS_ROOT` 正确 |
| 🔴2 integration harness 只 cp ob，source 链断 | integration 测试改 `cp -a "$ROOT/lib" "$TMPROOT/lib"`，列为硬验收 |
| source 链断裂（lib 路径解析错） | 入口用 `OB_ENTRY_DIR` 绝对路径 source；第 1 步 `bash -n` + 冒烟验证 |
| `reorder.py` 搬第一个 § 后 mismatch | 第 1 步即归档 reorder.py + 从 ob_check/tests/WORKSPACE/rules 移除现役引用 |
| `exit_contract` 多文件化改错 | 第 1 步改完跑 `--seed-y` + X/Y/Z 全绿；保留单/多文件参数能力便于 debug |
| `clone_openbmc` 失败语义变 | 已论证：它靠显式 `exit 1`，`||` 吞不掉（方案 1 行为等价） |

### 回退

D2 每步是一个可独立验证的逻辑单元（改动 + `ob_check` 全绿）。**commit 由用户决定，实施 agent 不自动 commit**（🟢1）。需要回退时：未 commit 用 `git restore`/stash；已 commit 用 `git revert`。最坏情况回退到第 0 步前（单文件 ob，零影响）。

---

## 测试策略

### 每步验证（D2）

每个搬迁步骤后必跑：
1. `bash tools/ob_check.sh`（聚合 extract_funcs GAPS / shellcheck baseline / exit-contract / run_all）。
2. 改了交互/退出码的步骤额外 `bash tests/run_all.sh --full`（含 `.exp` 交互矩阵）。

### 🟡1 · OB_SOURCES 契约（ob_check 多文件化的统一基础）

定义 ob 的全部源文件契约，作为 ob_check / exit_contract / shellcheck 的**统一扫描源**：

```bash
OB_SOURCES=(ob)              # 入口
OB_SOURCES+=(lib/*.sh)       # 分区(glob 展开)
# 与 sorted(glob('lib/*.sh'))+['ob'] 是同一文件集合;顺序不承载语义(ob+lib 与 lib+ob 等价)
```

ob_check 各项如何消费：

| 检查项 | 多文件化形态 |
|---|---|
| **shellcheck** | **不 per-file 扫**（跨文件变量可见性丢失会产生 SC2034 假阳：ob §1 定义的 `CYAN`/`VERBOSE` 等被 lib 使用 → 扫 ob 报 unused）；改**合成 flat 输入**（`cat ob + lib/*.sh` → 临时文件，扫 flat，保留单文件可见性，三审实验验证搬 §2 后 excess 0）。baseline 纯文本 multiset：`re.sub(r'^[^:]+:\d+:\d+:\s*','',line)`（去路径+行列号）；搬迁告警文本不变→CLEAN，真新增→NEW_ALERT |
| **extract_funcs 纯函数定义** | per-file 检查每个 `lib/*.sh` 三段（见下"lib 零顶层语句规则"），任一段有非注释顶层语句即报 |
| **exit-contract** | 见下"exit_contract 多文件后" |

**lib 零顶层语句规则（关键，三段闭环）**——source 顺序无关语义（🟡3）的前提保证：

- **首个函数前（header）**：只允许 shebang、空行、注释。
- **函数之间**：`GAPS=0`（沿用 extract_funcs 现有逻辑）。
- **最后一个函数后（footer）**：只允许空行、注释，**不允许任何顶层执行语句**——堵上二审指出的"末尾追加顶层语句、source 时被执行"的漏检口子。

入口 ob 允许 `source` loop（入口职责）；lib 违反任一段即 ob_check 报错。连 `declare -A X=()` 变量初始化也归 §1 入口（不放 lib header）。

### exit_contract 多文件后的 X/Y/Z

- **X**：跨 `OB_SOURCES` 所有函数，字面 exit ∈ {0,1,2,3}；非字面/bare 仅 `require_path` 体内（函数名级，不受多文件影响）。
- **Y（Y-c）**：basename 为 `util.sh` 的文件里 exit 的函数集 == `EXIT_EXCEPTIONS`（对偶式：多了报 unexpected，少了报 stale）。
- **Z**：`require_path` 调用点（跨 4 文件）+ direct exit 3（跨 4 文件）的 remedy 覆盖。
- **接口**：接受多文件路径参数（`exit_contract.py ob lib/util.sh ...`）；不传参时默认扫仓库根 `OB_SOURCES`；保留单文件参数能力便于 debug。

### 🟡2 · exit_contract 单测 fixture 修订

现状 `tests/unit/exit_contract.sh` case 3 用单文件 `# === §2 util ===` marker fixture。Y-c 绑 basename(`util.sh`) 后失效。修订：
- **X/Z 的假阳/真阳 fixture（case 1/2/4/5/6）**：仍传单文件，不依赖 §2 归属，**不用改**。
- **Y 测试（case 3）**：改成**迷你目录树**——构造 `$TMP/lib/util.sh`（含 exit 的 helper）+ `$TMP/ob`（桩），调 `python3 "$EXIT_CONTRACT" "$TMP/ob" "$TMP/lib/util.sh"`，断言 Y 捕获 `util.sh` 的 unexpected exit。Y 只有一套逻辑（basename 归属），不留 marker 兼容债。
- **ob 裁决（case 7）**：传单 `$OB` 仍输出 `X:`/`Y:`/`Z:` 三行 verdict（可观察性只断言行存在、不依赖具体裁决值），**不用改**。

### 🔴2 · integration harness 成套复制

`tests/integration/init_dryrun_sanity.sh` 现状 [行 16] `cp "$ROOT/ob" "$TMPROOT/ob"`。拆分后加：
```bash
cp "$ROOT/ob" "$TMPROOT/ob"
cp -a "$ROOT/lib" "$TMPROOT/lib"   # ← 新增:成套复制,否则 source 链断
```
联动 🔴1：`$TMPROOT/ob` 执行时 `OB_ENTRY_DIR=$TMPROOT`，source `$TMPROOT/lib/*.sh` 成立。列为 integration 硬验收。

### 行为等价验证

- protocol 层 `usage_dispatch_sync.sh`（`ob --help` 与 dispatch 一致）、`exit_codes.sh`（退出码协议）必须绿——保证 ob-first 契约不破。
- orchestration 层覆盖 cmd_* 编排；integration 层 `init_dryrun_sanity.sh` 兜端到端（含成套 lib 复制）。

---

## 实施路径（D2 分阶段）

> 详细 step-by-step 计划由后续 `/writing-plans` 落盘；此处只给阶段骨架供审核。每步是"可独立验证的逻辑单元"（改动 + `ob_check` 全绿）；**commit 由用户决定，实施 agent 不自动 commit**（🟢1）。

### 第 0 步 · 解耦（纯逻辑，单文件内）

在单文件 `ob` 上做方案 1：`require_openbmc_repo` 改 `return 3`、`cmd_init` 改 `|| clone_openbmc`。跑 `ob_check` 全绿。先把 §3→§5 耦合拔掉。

### 第 1 步 · 机制切换（高风险一次性投入）

1. 入口 ob 在 §1 加 `OB_ENTRY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`（🔴1，source lib 前算）。
2. 建 `lib/`，搬 §2 → `lib/util.sh`；`detect_harness_root` 改用 `OB_ENTRY_DIR`。
3. 入口加 `for f in "$OB_ENTRY_DIR"/lib/*.sh; do source "$f"; done`。
4. `exit_contract.py` 多文件化（B1 + glob + Y-c basename）。
5. `ob_check.sh`：定义 `OB_SOURCES` 契约 + shellcheck/baseline/extract_funcs 多文件化 + 移除 reorder 检查项。
6. `reorder.py` 归档到 `tools/archive/`，从 `ob_check.sh`/`tests/`/`rules/03_WORKSPACE.md` 移除现役门禁引用（🟢2）。`extract_funcs.py` 保留为可选体检。
7. `bash tools/ob_check.sh` + `run_all --full`（含 integration 成套 lib 复制）全绿。

### 第 2 步起 · 机械搬迁（拓扑序）

按依赖方向逐个搬：`§3 repo → §4 qemu → §5 init → §6 commands`。每步：挪函数到对应 `lib/*.sh` + 删 `ob` 里那段 + `ob_check` 全绿。ob 入口（glob）与 exit_contract/ob_check 无需再改。

### 收尾

`ob` 只剩 §1 + §7。全文 `grep` 确认无残留 §2–§6 函数。跑 `--full` + `--integration`。

---

## 未决事项

1. **§4 二次切分**：`lib/qemu.sh` 1200 行是否切为 `qemu_binary.sh` + `qemu_launch.sh`？留作本设计落地、手里有"分区文件能跑"证据后的独立决策。
2. **`clone_openbmc` 幂等检查**：`[ob:2343-2347]` 重复分支保留（防御）还是清理？本轮保留。
3. **`CONTEXT.md` 同步**（实施时 side effect）：`function semantic layer` 条目需从"概念性、非强制结构边界"更新为"已物化为 `lib/*.sh` 文件边界"；`exit-code 契约` 不变。审批后、实施时一并更新。
4. **`reorder.py` 处置（已定，🟢2）**：归档到 `tools/archive/`（保留 §1-§7 物理重构的历史工具）。归档后从 `ob_check.sh`、`tests/`、`rules/03_WORKSPACE.md` 移除对它的**现役门禁引用**（文档作历史提及可保留）。

---

## ADR 关系

- **不冲突 ADR-0003（ob-first）**：该 ADR 约束的是**调用层**，与 ob 内部是否单文件无关。拆分后 `ob` 仍是唯一 CLI 前门，`ob --help` / exit-code 契约 / remedy line / init-done marker 全不变。
- **不冲突 ADR-0001/0002/0004/0005**：均与 init-done marker / QB 变量 / PREMIRRORS / local.conf 判定相关，不涉及 ob 文件结构。
- **`function semantic layer` 物化**：CONTEXT.md 该条目本就标注"不是代码强制遵守的结构边界"——本设计把它物化为 `lib/*.sh` 文件边界，是该术语的自然演进。
