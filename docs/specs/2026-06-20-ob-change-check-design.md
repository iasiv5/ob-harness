# ob 改动配套自检机制 设计文档

> 状态：待审批（v2，吸收评审 6 条）· 2026-06-20

## 背景与目标

### 为什么要做

2026-06-20 给 ob 加双轨 host key 检测时，漏同步了 CI 配套机制（[coverage_matrix.md](../../tools/coverage_matrix.md) 登记 / [reorder.py](../../tools/reorder.py) §dict / [tests/.shellcheck-baseline](../../tests/.shellcheck-baseline)），用户指出后才补齐。根因：ob 脚本改动后，配套的 CI/测试维护动作分散在多个文件和工具里，没有统一入口，agent 容易漏。而且各项的 CI 兜底强度不均——baseline/run_all 有 CI 硬门禁兜底，reorder/extract_funcs/matrix 完全没有。

### 这次要解决什么问题

把"改 ob 后必须做的配套自检"收敛成一条命令 `tools/ob_check.sh`，让 agent 改完 ob 一键完成全部验证，显著降低漏率。

### 成功标准

- agent 改 ob 后跑 `tools/ob_check.sh`，一条命令覆盖全部配套检查。
- baseline 的**纯行号平移/告警减少**自动修复；**新增告警**机器报错、不静默吸收（不架空 CI 硬门禁）。
- 规则里有明确钩子，agent 改 ob 时能被触发去跑。

## 范围

- 新增 `tools/ob_check.sh`：聚合 4 项检查（extract_funcs GAPS / reorder.py mismatch / shellcheck baseline / run_all），支持 `OB_CHECK_SKIP_TESTS=1` 跳过 run_all 项。
- baseline 判定式重生成（仅良性变化自动改，新增告警报错）。
- 规则更新：AGENTS.md `## Working Mode` 加 ob 钩子；WORKSPACE.md tools 路由登记 ob_check.sh，并**顺手修正过时的 tests 路由**（当前仍写 smoke_ob.sh/manual_matrix.exp，未反映 run_all 分层）。
- 新增 `tests/protocol/ob_check_smoke.sh`：对当前 ob 跑 ob_check.sh（skip tests）断言 exit 0，防脚本腐烂。

## 非范围

- 不把 reorder/extract_funcs/matrix 加进 CI 硬门禁（"重"方案，本次明确不做）。
- 不解决 matrix 漏登记的自动检测（语义层声明，不可靠自动）。
- 不新建 skill、不加 hooks / git pre-commit。
- 不改 CI workflow ob-tests.yml：baseline/run_all 硬门禁保持原样作为兜底；smoke 放 protocol 层被 run_all 自动覆盖，不需要新增 CI step。

## 方案比较

### 方案 A：精准补盲（最小）

- 核心思路：ob_check.sh 只跑 CI 盲区里可靠可判定的（reorder mismatch + extract_funcs GAPS），baseline/run_all 交给 CI 不重复，matrix 靠规则。
- 优点：零误报、不重复 CI。
- 缺点：matrix 仍裸奔；baseline 本地不查（要等 CI 反馈）。

### 方案 B：一站式本地自检（推荐，已选）

- 核心思路：ob_check.sh 聚合全部 4 项可靠检查（含 baseline 本地 diff + run_all），baseline 判定式重生成，其余报告不改；matrix 靠规则。
- 优点：一条命令全知道、即时反馈不等 CI、baseline 良性变化自愈省心。
- 缺点：与 CI 部分重复（但本地即时值得）；matrix cross-check 不纳入（exit 函数良性噪音）。

### 方案 C：规则清单为主（最轻）

- 核心思路：不写脚本，规则里列改 ob 后检查清单（逐条命令），agent 照跑。
- 优点：零新代码、透明。
- 缺点：分散易漏某条、无聚合入口。

## 推荐方案

方案 B。理由：用户选定的保障强度是"中"（脚本 + 规则），要"显著降低漏率"。B 把分散的检查收敛成一条命令，且 baseline 判定式重生成解决了最频繁的维护痛点。matrix 因语义层本质不可自动，任何方案都只能规则提醒——这是统一的天花板，不构成 B 的额外劣势。

主要 trade-off：与 CI 重复（baseline/run_all 本地 + CI 各跑一次），但本地即时反馈的价值大于重复成本，CI 保留为兜底。

## 关键边界与组件职责

### tools/ob_check.sh（新增）

一站式自检入口。聚合 4 项，逐项输出 ✓/✗，末尾汇总，exit 0（全绿）/ 非 0（有问题）。任一项失败不中断后续项（跑完全部再汇总，一次看全）。**执行顺序固定：extract_funcs → reorder → baseline → run_all**（extract_funcs 的 GAPS=0 是 reorder 的前提，否则 reorder 内部 `max([])` 在边界异常时会崩溃）。

| 检查项 | 命令 | 检测到问题时 |
|---|---|---|
| ob 结构 | `python3 tools/extract_funcs.py ob`（解析末尾 `GAPS N`） | GAPS>0 → 报告，提示清理函数间顶层语句（不自动改） |
| 函数登记 | `python3 tools/reorder.py ob` | 退出非 0 → 解析 stderr：`AssertionError`/`missing=` = 漏登记（报告 missing 函数名 + 提示加进对应 §dict，不自动改怕归错 §）；其它异常（如 reorder 自身崩溃）= 单独报告。**注意**：assert 是函数名集合比较，**只保"不漏"、不保"归对 §"**；会产生 `/tmp/ob_new` 副作用 |
| shellcheck baseline | `shellcheck -f gcc ob` 与 `tests/.shellcheck-baseline` 做**多重集（计数）比对** | 见下"baseline 判定式重生成" |
| 测试 | `bash tests/run_all.sh` | 非 0 → 报告失败层/文件。**默认只跑快速子集**（protocol/unit/orchestration 的 .sh），不跑 .exp/integration |

`OB_CHECK_SKIP_TESTS=1` 环境变量：跳过 run_all 项。用途是让被 run_all 递归调用的 smoke 避免自调用（见测试策略）。

matrix 登记：ob_check 不管（不可自动），靠规则提醒。

### baseline 判定式重生成（关键——避免架空 CI 硬门禁）

把 baseline 文件与 `shellcheck -f gcc ob` 新输出都解析成 `(SCxxxx 代码, 去掉行号列的消息)` 的**多重集（计数，非 set）**比对。

**为何不用 set**：baseline 实测有大量同 key 多实例——SC2012×4、SC2016×4、SC2002×3（去行号后消息完全相同），set 会去重成 1 条；而 ls/`cat file |`/find 恰是 agent 写 bash 最高频手滑引入的告警。set 比对下"新增同类型实例"会被判良性静默吸收，双层保障对这个子场景不成立。

判定规则（**当且仅当 new 是 base 的子多重集**，即 ∀key `new[key] ≤ base[key]`，才自动重生成）：

| 场景 | new[key] vs base[key] | 判定 |
|---|---|---|
| 纯行号平移 | 每个 key 次数不变 | 良性 → 自动重生成 |
| 修掉旧告警 | 某 key 次数下降/消失 | 良性 → 自动重生成 |
| 新增同类型实例 | 某 key 次数 +1（如第 5 处 SC2012） | **报错**（set 版漏放，multiset 挡住） |
| 新增全新类型 | 出现 base 没有的 key | **报错**（两版都挡） |

实现：`Counter(new) - Counter(base)` 为空 ⟺ 子多重集 ⟺ 良性自动重生成；非空则报错、不自动改，交回 agent 显式决定（agent 必须先修告警，或显式手动 `shellcheck -f gcc ob > tests/.shellcheck-baseline` 并 `git diff` 确认后再 commit）。

**已知 trade-off（偏安全侧，可接受）**：key 含消息文本，而 SC2034 类告警消息内嵌变量名（`PIDFILE_USER appears unused` 等）。agent 仅重命名一个未用变量时，旧 key 消失、新 key 出现 → 被判"新告警"报错（宁可拦不可漏的误报）。不能用 (SCxxxx) 单值做 key，否则又退回 set 的同类型去重问题。

这样 CI 硬门禁（[ob-tests.yml:18-25](../../.github/workflows/ob-tests.yml#L18-L25) 的 baseline diff）不被架空：任何新增告警（含同类型实例）都不会被 ob_check 静默吸收。原 v1"无条件重生成"已废弃；v2 初版 set 比对漏放同类型，本版改 multiset 修正。

### AGENTS.md `## Working Mode`（更新）

"实现和调试"项补 ob 钩子：改动 ob 脚本后，跑 `tools/ob_check.sh` 做配套自检（详见 WORKSPACE.md）。这是行为触发点（AGENTS.md 是 Every Session 必读根入口）。

### rules/03_WORKSPACE.md（更新）

- tools 路由：登记 ob_check.sh（是什么、聚合哪些检查、baseline 判定式重生成、OB_CHECK_SKIP_TESTS、何时用），和 extract_funcs/reorder 并列。
- tests 路由：**修正过时描述**——当前写 smoke_ob.sh/manual_matrix.exp，改为反映 run_all.sh 分层体系（protocol/unit/orchestration .sh 默认跑；.exp 需 --full；integration 需 --integration）。

### tests/protocol/ob_check_smoke.sh（新增）

对当前 ob 跑 `OB_CHECK_SKIP_TESTS=1 tools/ob_check.sh` 断言 exit 0。防 ob_check 脚本本身腐烂（路径写错/工具移位）。**必须用 skip 开关**，否则 run_all→smoke→ob_check→run_all 无限递归。

## 数据流 / 控制流

1. agent 改 ob（working tree 内）。
2. agent 跑 `tools/ob_check.sh`。
3. 脚本按固定顺序逐项：extract_funcs → reorder → shellcheck baseline（判定式重生成）→ run_all。
4. baseline 良性变化自动重生成；新增告警/其余问题只报告。
5. 全绿 exit 0，agent 交付；非 0 则 agent 按提示修。
6. CI（ob-tests.yml）作为兜底：即使 agent 漏跑 ob_check，baseline diff / run_all 硬门禁仍会拦。

### 各项保障强度（设计前提）

| 项 | 第一层 ob_check（agent 自觉） | 第二层 CI 兜底 | 综合 |
|---|---|---|---|
| shellcheck baseline | multiset 判定式重生成（新告警 / 同类型新增实例都机器报错，不吸收） | ✅ 硬门禁 | **双层成立**（含新增同类型实例） |
| run_all 测试 | ob_check 跑（快速子集） | ✅ 硬门禁 | 双层（注：.exp/integration 两层都默认不跑） |
| reorder §dict 登记 | ✅ mismatch 检测（只保不漏） | ❌ | 单层，靠自觉 |
| extract_funcs GAPS | ✅ | ❌ | 单层，靠自觉 |
| matrix 登记 | ❌ ob_check 管不了 | ❌ | 纯规则提醒，最弱 |

## 错误处理与回退

- baseline 良性变化（行号平移/告警减少，即 new 是 base 子多重集）：自动重生成，并**输出一行提示**「已更新 tests/.shellcheck-baseline（行号平移/告警减少），请 `git diff` 确认后一并 commit」——改文件要透明，别让 agent 不知情带上改动。
- baseline 新增告警（含同类型新增实例，即 new 非 base 子多重集）：**报错、不自动改**。agent 必须先修告警，或显式手动重生成 + `git diff` 确认。绝不静默吸收。
- reorder mismatch（AssertionError/missing=）：只报告 missing 函数，不自动加 §dict（自动归类可能归错 §，需人工判断归属）。
- reorder 其它异常（非 AssertionError，如 GAPS>0 触发的 max([]) 崩溃）：单独报告，提示先看 extract_funcs 项；不误报成"漏登记"。
- extract_funcs GAPS>0：只报告，不自动清理（涉及代码结构调整）。
- run_all 失败：报告，不自动修。
- 任一项失败 ob_check exit 非 0，但不中断后续项（跑完全部再汇总）。

## 测试策略

- **smoke**：`tests/protocol/ob_check_smoke.sh` 对当前 ob 跑 `OB_CHECK_SKIP_TESTS=1 tools/ob_check.sh` 断言 exit 0。放 protocol 层被 run_all 自动覆盖（防脚本腐烂），用 skip 开关避免递归。**覆盖边界**：smoke 走 skip，ob_check 里"调用 run_all.sh 那段"在 smoke 下不执行——若该路径写错，smoke 检测不到，靠 CI 直接 `bash tests/run_all.sh` 兜底；smoke 实际只覆盖 ob_check 的 extract_funcs/reorder/baseline 三段。
- **不做的**：完整破坏场景测试（构造各失败项、各 baseline 判定分支）YAGNI 先不做，靠手动验证 + CI 兜底。
- ob_check 输出末尾**显式注明覆盖范围**："本次跑 run_all 快速子集（.sh），未跑 .exp/integration；若改了交互/退出码协议，请手动 `tests/run_all.sh --full`。"——避免 exit 0 被误读成全覆盖。

## 未决事项

1. **触发强度**：先上线观察 agent 漏率。若 AGENTS.md 钩子不够强，再升级成触发词 skill（"改 ob" / "ob_check"）。
2. **matrix 登记仍裸奔**（规则提醒是唯一保障）。未来若漏率仍高，可升级到"重"方案：把 reorder/extract_funcs 加进 CI 硬门禁（matrix 仍无解）。
3. ~~smoke 递归~~ / ~~baseline 自动重生成架空 CI~~ / ~~ob_check 纳入 CI~~：评审指出后已定（见上，smoke 用 skip 开关、baseline 判定式重生成、ob_check 不纳入 CI 靠 smoke 防腐烂）。
