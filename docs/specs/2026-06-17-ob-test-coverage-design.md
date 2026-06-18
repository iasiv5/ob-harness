# ob 测试覆盖体系 设计文档

> 状态：设计（2026-06-17），已批准，实施中（见配套实施计划）。经三轮评审修订冻结；退出码 status/stop-qemu 空值按第五轮评审实测修正为 0。
> 术语：测试体系采用**语义名分层** `protocol` / `unit` / `orchestration` / `integration`（曾用 L0–L3，为脱离与 `ob` function semantic layer 的 L1/L2/L3 撞名而改，详见 [CONTEXT.md](../../CONTEXT.md)）。`ob` 源码注释里的 function semantic layer（`# L3 — never exits` 等）是 ob 真实属性，不在本设计改动范围。
> 依据：本文由 `/grill-with-docs` 对齐、按 `/brainstorming` 标准重写、经三轮评审修订。配套实施计划见 [`docs/plans/2026-06-17-ob-test-system-implementation-plan.md`](../plans/2026-06-17-ob-test-system-implementation-plan.md)。

## 背景与目标

`ob` 是 OpenBMC 开发环境的一键初始化/源码管理/编译/QEMU 仿真工具（4104 行、92 函数、5 子命令 + menu）。当前改动后**几乎没有自动化回归保护**——现有测试全部压在退出码协议这一窄切面。本设计的目标是建立**分层测试体系**，支撑"每次改完功能随手回归，确认没破坏已有行为"。

**成功标准（"覆盖率 100%"在 `ob` 上的精确定义）**：不追求单一行覆盖率指标，而是分层各司其职——
- **unit 层**（确定性逻辑：纯逻辑/文件IO/exit + 交互叶子函数 stdin 喂入，范围 ~40 函数）冲高覆盖，**函数级覆盖率 ≥ 95%（分母=unit 范围 ~40 函数，非全 92）**；
- **protocol 层**覆盖所有子命令 × 分支的退出码 0/1/2/3；
- **orchestration 层**覆盖高价值编排子集（调用顺序/参数/错误处理）；
- **integration 层**兜端到端真实验证（init→build→QEMU 全流程 + TTY 真交互）；
- **覆盖度**用两核心层交叉校验：checklist（语义，自顶向下、人声明）× xtrace 雷达（结构，自底向上、运行时实测）；kcov 行级报告降为可选附录。
- **盲区透明化**：按五档列出全 92 函数的自动化归属（见"零自动化覆盖函数"），不制造覆盖率虚高。

### 覆盖现状评估（决策的事实依据）

**被测对象规模**

| 维度 | 值 |
|---|---|
| 代码量 | 4104 行单 bash 脚本 |
| 函数数 | 92（`tools/extract_funcs.py` 可枚举，GAPS=0） |
| 子命令 | `init` `build` `status` `start-qemu` `stop-qemu` `menu` |
| 退出码协议 | 0=成功 / 1=硬错误 / 2=用户取消 / 3=前提不满足 |
| 外部命令调用 | `git`/`bitbake`/`curl` 等**全裸名调用，无 `command <cmd>` 调用形式、无绝对路径**（计数因 grep 模式含注释/字符串字面量而浮动，约 git≈22/bitbake≈19/curl≈8；定性结论=全裸名、PATH 注入可行，成立）。另有 5 处 `command -v` 工具存在性检查（line 373/474/2228/2271/2279）。 |

**现有测试（17 case，去重约 13 个独立行为点）**

| 脚本 | 层 | 覆盖 |
|---|---|---|
| `tests/smoke_ob.sh` | protocol | `parse_args` --help(0)/unknown opt(1)/missing val(1) + build 空工作区(3) |
| `tests/manual_matrix.exp` | protocol/交互 | --help/unknown/build空/init非TTY(3) + 菜单 Q/status + 取消(2) |
| `tests/manual_matrix_qemu.exp` | integration | start-qemu --no-wait(0) + kill-restart(2) + stop取消(2) + stop正常(0) |

**核心缺口**：92 函数里承载核心业务逻辑的——init 8 步流水线、依赖解析、源码克隆、lockfile/build_config 生成、QEMU binary 下载与 manifest、port/PID 管理、status 报告——**几乎零自动化覆盖**。已知脆弱点：`tests/smoke_ob.sh:56` 硬编码 `source /bmc/iasi/ob-harness/ob` 绝对路径（同文件 :29 已用 `SCRIPT_DIR` 相对推导），仓库挪位置该 case 即挂。

## 范围

- 建 test layer 四层（protocol/unit/orchestration/integration），protocol/unit/orchestration 零依赖、每次回归可跑，integration 定期/手动。
- 按语义名重组 `tests/` 目录（lib/fixtures/protocol/unit/orchestration/integration + `run_all.sh`）。
- 迁移现有 3 个测试脚本到对应层，修硬编码路径。
- 建两核心层覆盖度视图：功能点 checklist + xtrace 函数级覆盖雷达（`tools/coverage_radar.py`）；kcov 行级报告降为可选附录。
- `shellcheck ob` 静态检查。
- 回归触发机制：pre-commit 自动提醒点（protocol+unit，秒级）；CI 骨架（`.github/workflows/`）PR 跑 protocol–orchestration，integration 定期门禁。

## 非范围

- **不改 `ob` 源码**加 mock seam（最小改动；隔离靠 PATH 注入 + 函数 override，已验证可行）。
- **不 orchestration 全量 mock**：顶层薄编排（cmd_*）mock 价值低；中层有真实逻辑的编排（download_qemu_binary_core/clone_openbmc/ensure_qemu_binary_* 等）仅靠 integration 兜底，标为"deferred-to-integration"而非"价值低"（见零自动化表）。
- **不 integration 每次 CI 跑**（init→build 分钟~小时级 + 联网，定位定期门禁/手动）。
- 不引入 bats 等测试框架（沿用现有 bash harness）。
- 不把 kcov 列为核心交付（降为可选行级附录，见决策 2）。

## 方案比较

### 决策 1：覆盖率定义（最根本，决定其余一切）

**方案 A：行/分支覆盖率（kcov 单一指标）**——优点：可量化、CI 友好。缺点：`ob` 编排逻辑里调 git/bitbake 的行不跑真实命令难以覆盖，易"为凑覆盖率而 mock 到失真"；行覆盖 ≠ 功能覆盖，回答不了"哪些子功能没测"。

**方案 B：功能点矩阵（checklist 单一指标）**——优点：贴语义、直观判断功能点遗漏。缺点：依赖人把功能点列全，边界/错误路径易漏，单独用会"覆盖率虚高"；无代码行细节。

**方案 C：分层覆盖 + 两核心层交叉（推荐）**——核心思路：protocol/unit/orchestration/integration 各司其职；覆盖度用 checklist（语义，自顶向下）与 xtrace 雷达（结构，自底向上运行时实测）两独立方向交叉，任一盲区被另一暴露。优点：兼顾"快速回归"（unit/orchestration 零依赖）与"覆盖逻辑"（integration 兜底）；两独立方向对冲单一指标失真。缺点：体系比单一指标复杂，前期搭骨架有成本。

### 决策 2：覆盖度可视化方案（如何直观判断每个版本的子功能覆盖度）

**方案 A：单一 kcov 行覆盖**——成熟但回答不了"哪些子功能没测"。

**方案 B：三者全上（checklist + 雷达 + kcov 并列核心）**——覆盖最广，但 kcov 在 bash 上精度有限、且必装，与零依赖哲学冲突；雷达数据源若依赖 kcov 函数命中，则 kcov 无法降级。

**方案 C：两核心层交叉 + kcov 可选附录（推荐）**——checklist（语义，人声明，自顶向下）× xtrace 雷达（结构，运行时实测，自底向上）两个独立方向交叉校验；kcov 降为可选行级附录。对冲价值来自两个**独立方向**的交叉（人声明 vs 机器实测），kcov 是边际增量，去掉不破坏双向交叉校验。

## 推荐方案

**选方案 C（分层覆盖 + 两核心层交叉）。** 根本原因：`ob` 是重编排脚本，"快速回归"与"覆盖逻辑"天然冲突，分层是唯一兼顾解；单一指标都有盲区，两独立方向（checklist × 雷达）交叉对冲失真。

**主要 trade-offs**：体系复杂度 ↑，换来回归保护完整性与指标可信度。前期骨架成本由分阶段实施计划摊薄。

**其余已对齐决策（方案 C 内部的选择）**：

| 决策 | 选择 | 依据 |
|---|---|---|
| unit 载体 | 沿用 bash harness（`OB_NO_MAIN=1 source ob` + 自写 assert） | 零依赖、贴合 ob 可 source 结构、smoke 已验证；bats/kcov 环境未装 |
| unit 范围 | 纯逻辑 + 文件IO + exit + 交互叶子函数（stdin 喂入） | 见下"unit 范围明细"；表现层归 transitive、TTY 真交互归 integration |
| orchestration 隔离 | PATH 注入 stub（加法）+ 减法 PATH（`command -v` 缺失分支）+ 函数 override | ob 全裸名调命令、无 `command <cmd>`/绝对路径，PATH 注入可行；`command -v` 缺失分支需减法 PATH |
| orchestration 范围 | 聚焦高价值子集（~8-10 编排函数）；中层编排 deferred-to-integration | 见零自动化表，区分 mock-covered 与 deferred |
| integration 定位 | 分级（现有 expect 手动 + init→build E2E 定期门禁） | init→build 重资源，不在每次 CI |

## 关键边界与组件职责

### test layer 分层职责

| 层 | 测什么 | 载体/隔离 | 依赖 | 频率 |
|---|---|---|---|---|
| **protocol** | 每子命令 × 前提/参数的退出码 0/1/2/3 | `OB_NO_MAIN=1 source ob` + `assert_exit` | 零 | 每次 |
| **unit** | 确定性逻辑（纯逻辑/文件IO/exit + 交互叶子函数） | source ob + assert + tmpdir fixture + stdin 喂入 | 零 | 每次 |
| **orchestration** | 高价值编排子集（调用顺序/参数/错误处理） | PATH stub 加法 + 减法 PATH + 函数 override | 零 | 每次 |
| **integration** | init→build→QEMU 全流程、TTY 真交互 | 真实 workspace + 真命令 | workspace/QEMU/网络 | 定期/手动 |

### unit 层范围明细

| 类别 | 数量 | 代表函数（行号） | 测法 |
|---|---|---|---|
| 纯逻辑 | ~12 | `normalize_repo_url`(637) `is_valid_repo_url`(632) `derive_source_label`(686) `calc_parallelism`(349) `derive_bitbake_git_mirror_path`(300) `parse_hostkey_offending`(2173) `trim_whitespace`(84) `detect_wsl`(345) `derive_qemu_url_config_path`(1102) | 直接调，`assert_eq`/`assert_match` |
| 文件 IO | ~15 | `read_kv_field`(512) `read_source_label`(620) `write_source_lock`(697) `write_qemu_url_config`(1117) `write_qemu_binary_manifest`(1145) `is_private_url`(200) `detect_harness_root`(330) | tmpdir/tmpfile fixture，断言文件内容 |
| exit 函数 | ~7 | `require_path`(604) `fn_quit`(145) `check_ports_available`(1975) `validate_pid`(2150) `parse_args`(3925) | 子进程捕获退出码 |
| 交互叶子函数（stdin 喂入） | ~6 | `select_from_list`(532) `confirm_action`(553) `prompt_for_absolute_path`(573) `prompt_for_available_port`(2023) | `printf 'n\n' \| func`，见 caution |

> unit 合计 ~40（求和为约，边界模糊属正常）。
> **交互叶子函数可进 unit 的依据**：这些函数本身只 `read` stdin、不自检 TTY；TTY gate 在调用方 `cmd_*`（12 处 `[[ -t 0 ]]`）。故非 TTY 下管道喂 stdin 即可驱动其分支逻辑。**caution**：管道须喂足输入行 + 末尾 `< /dev/null` 兜底，防 `read` 撞 EOF 挂起。
> unit 边界判定标准：**允许**读/写文件系统、调 grep/awk/sed/date/python3 等确定性命令、stdin 喂入；**不允许**调 `git/bitbake/qemu-system/curl/wget`（归 orchestration）、真实 TTY 交互（归 integration）。

### 零自动化覆盖函数（盲区透明化，五档覆盖全 92）

| 档 | 数量 | 代表函数 | 自动化情况 | 兜底 |
|---|---|---|---|---|
| **unit-covered** | ~40 | 见上 unit 明细 | unit 层显式测，目标函数级覆盖 ≥95% | — |
| **orchestration-mock-covered** | ~8-10 | `generate_lockfile` `generate_build_config` `clone_sub_repos` `resolve_qb_vars` `generate_dep_graph` `prerequisites_check` `init_bitbake_env` | orchestration 层 PATH stub mock | mock 绿≠产物有效（见错误处理表） |
| **orchestration-deferred-to-integration** | ~10 | `download_qemu_binary_core`(1201) `clone_openbmc`(2302) `ensure_qemu_firmware`(1715) `ensure_qemu_binary_community`(1380) `ensure_qemu_binary_custom`(1483) `download_and_replace_community_qemu`(1246) `check_jenkins_update`(1324) `run_repo_init_script`(2330) | **有真实逻辑和失败模式，非薄编排**；被"不全量 mock"排除，仅 integration 兜底 | integration E2E + 真实使用 |
| **presentation+logging（雷达 transitive，无显式 target）** | ~17 | `log/info/warn/error/verbose`(59-67) `step_header`(114) `show_logo`(122) `show_brand_line`(141) `print_confirm_banner`(71) `format_timestamp`(95) `print_report`(2764) `status_section_*`(2822/2880/2993) `print_available_machines`(932) `print_previously_initialized`(963) `usage`(4013) | 被 xtrace 雷达 transitive 命中（cmd_* 调用链经过），但无 checklist 功能点认领——**雷达绿/checklist 无主，预期良性**（见采集流） | 可选 unit 显式测，否则靠 transitive |
| **top-level cmd_\*+main+TTY 真路径** | ~8-13 | `cmd_init`(3728) `cmd_build`(3083) `cmd_status`(3014) `cmd_start_qemu`(3276) `cmd_stop_qemu`(3579) `cmd_menu`(3829) `_qemu_post_launch`(3490) `main`(4066) | 顶层编排 + TTY 真交互路径 | integration 手动 + 真实使用 |

五档求和 ≈ 92（数字为约，边界模糊属正常）。这是"覆盖率 100%"在 `ob` 上的诚实边界：自动化覆盖集中在 unit(~40) + orchestration-mock(~9)，其余靠 integration + 真实使用 + transitive 命中兜底，不制造虚高。

### 目录骨架

```
tests/
  lib/{ob_loader.sh, assert.sh, stub.sh}     # 公共加载/断言/PATH stub 生成器
  fixtures/{source_lock.sample, local.conf.sample, bitbake-e.<machine>.txt, deps.json.sample}
  protocol/{smoke_ob.sh, exit_codes.sh, manual_matrix.exp}
  unit/{url.sh, paths.sh, source_lock.sh, qemu_manifest.sh, ports.sh, parse_args.sh, require_path.sh, interact.sh}
  orchestration/{clone_sub_repos.sh, generate_lockfile.sh, generate_build_config.sh, resolve_qb_vars.sh, prerequisites_check.sh}
  integration/{manual_matrix_qemu.exp, init_build_e2e.sh}
  run_all.sh                                  # 默认 protocol+unit+orchestration；collect-all；--integration 跑 integration
tools/{coverage_radar.py, coverage_matrix.md} # xtrace 函数级雷达 / 功能点 checklist
```

### protocol 层退出码协议（全子命令 × 分支）

| 子命令 | 场景 | 预期退出码 |
|---|---|---|
| 全局 | `--help`/`-h` / unknown command / unknown option / missing value | 0 / 1 / 1 / 1 |
| `init` | 非 TTY 无 workspace / 用户取消 | 3 / 2 |
| `build` | 空 workspace / 用户取消 | 3 / 2 |
| `status` | 空 workspace | 0（cmd_status 无 exit，评审实测） |
| `start-qemu` | 缺 init-done / 缺 build 产物 / 用户取消 | 3 / 3 / 2 |
| `stop-qemu` | 无运行实例 / 用户取消 | 0（cmd_stop_qemu 无实例无 exit，评审实测）/ 2 |

## 数据流 / 控制流

**1. 测试加载流**：`tests/lib/ob_loader.sh` 设 `OB_NO_MAIN=1` 后 `source ob` → ob 函数全部可调、main 不触发；处理 ob 顶部 `set -euo pipefail` 泄漏（保留 nounset/pipefail、关 errexit，smoke 已验证）。

**2. 执行调度流**：`run_all.sh` 按 protocol→unit→orchestration 顺序调用各层脚本，**collect-all 语义**（遇错不 fail-fast，跑完全部再汇总所有失败）；`--integration` 追加 integration 层。

**3. orchestration 隔离流**：
- **加法 stub**：`stub.sh mkfake <tmpbin>` 生成 fake `git`/`bitbake`/`curl`（bash 脚本，按参数记录调用 + 输出预设）；`with_stub <tmpbin> -- <cmd>` 临时前置 `PATH="$tmpbin:$PATH"`；ob 裸名调用被拦截到 fake。`bitbake -e` 用 `fixtures/bitbake-e.<machine>.txt` 喂预设输出。
- **减法 PATH**：`command -v` 工具存在性检查的失败分支（`prerequisites_check` line 2270-2274 等）用 `PATH=<空dir>` 制造"工具缺失"，加法 stub 做不到。
- **函数 override**：source 后重定义个别 helper 测编排顺序/参数。

**4. fixture 流**：unit 文件 IO 函数用 `mktemp -d` 建 tmpdir + 复制 `fixtures/*.sample` → 断言读出/写出文件内容 → 测试结束清理。**bitbake-e fixture 陈旧检测**：每个 fixture 带版本戳（来源 machine + ob commit + bitbake 版本），定期与真实 workspace 比对，失真则告警。

**5. 覆盖度采集流（两核心层）**：
- **xtrace 雷达（结构，自底向上运行时实测）**：跑测试时开 `set -o xtrace`，用 `BASH_XTRACEFD` 导独立 fd + `PS4='@@${FUNCNAME[0]:-main}@@ '`，从 trace 取唯一被调用函数集，与 `extract_funcs.py` 的 92 函数求交 → "函数 × 被测? × test 来源"矩阵 + 未覆盖清单 + 覆盖率%。
- **"transitive 无主"识别（关键）**：presentation+logging 档（~17 个）会被 cmd_* 调用链 transitive 命中（雷达绿），但没有显式 checklist 功能点认领。雷达输出须**区分两类**：(a) 显式 target（test 直接断言的函数）= 真覆盖；(b) transitive 命中无 checklist 主 = 预期良性，单独标注不报漏测。否则跑出 ~17 个"无主"会被误判漏测。
- **checklist（语义，自顶向下人声明）**：`tools/coverage_matrix.md` 按子命令 × 行为列功能点，每条声明涉及函数 + 覆盖它的 test。
- **交叉校验**：checklist 标"已覆盖"但 xtrace 雷达无函数命中即报警（人声明 vs 机器实测互相暴露盲区）。
- **kcov（可选附录）**：按需装，包裹 `run_all.sh` 产 HTML 行/分支报告，作边际增量补充，不作核心指标。
- **spike 前置**：xtrace 方案必须先 spike 验证子 shell `(...)` / 命令替换 `$(...)` 边界的 transitive 调用是否被捕获（避免"transitive 漏计"在子 shell 复发）；不稳则退人工声明矩阵（主观但零解析）。

## 错误处理与回退

| 失败模式 | 处理策略 |
|---|---|
| **orchestration 绿 ≠ 产物有效（残余风险）** | mock 掉 git/bitbake 后不验证产物可用性（如 local.conf 能否喂 bitbake、lockfile 是否被下游接受）。**这条无法靠 orchestration 层消除**，靠 integration E2E + 真实使用兜底。设计层面显式承认此残余风险。 |
| **中层编排 deferred-to-integration 的真实失败模式无自动化** | download_qemu_binary_core/clone_openbmc/ensure_qemu_binary_* 等有真实下载/克隆失败模式，仅 integration 兜底；改动这些函数后必须手动跑 integration，不能假设 orchestration-mock 绿即安全 |
| xtrace 在 eval/子 shell 边界不稳 → 雷达漏计 | spike 验证；不稳则退人工声明矩阵作 checklist 数据源 |
| ob 改了函数签名/调用方式 → orchestration fake 失效 | 雷达 + run_all 每次 CI 跑，快速暴露；fake 与 ob 同 PR 改 |
| `bitbake -e` fake 覆盖不全 → orchestration 漏分支 | 多 machine 样本 + fixture 陈旧检测；漏的标未决不阻断 |
| integration E2E 在 CI runner 跑不动 | integration 定位定期/手动，不阻断 protocol-orchestration CI |
| kcov 对 bash 行统计精度有限 | kcov 只作可选附录，核心指标是雷达函数级 + checklist 语义级 |
| `set -euo pipefail` 经 source 泄漏 | ob_loader 关 errexit、保 nounset/pipefail（smoke 已验证） |
| pre-commit 被绕过（`--no-verify`） | pre-commit 是"唯一自动提醒点"非硬门禁；无 CI 时诚实写明此局限，不制造假信心 |

## 测试策略（验证本测试体系自身设计正确）

**可行性已验证**：`OB_NO_MAIN=1 source ob` 机制 smoke 已跑通；PATH 注入经 grep 确认 ob 全裸名调命令、无 `command <cmd>`/绝对路径；extract_funcs.py 能枚举 92 函数（GAPS=0）。

**待 spike 验证（见未决事项 2）**：xtrace（BASH_XTRACEFD + PS4 FUNCNAME）对子 shell / 命令替换边界的 transitive 捕获。

**sensitivity 校验（mutation 抽查）**：测试策略不止证可行性，还须证敏感度。加一步 mutation 抽查——往 ob 注入代表性 bug（如改 `normalize_repo_url` 的 host 提取逻辑、改 `write_source_lock` 的输出字段），确认对应层 test 变红。若注入 bug 后测试仍绿，说明该测试空转，需补强。每层抽 1-2 个代表性函数做 mutation。

## 未决事项

1. ~~`cmd_status`/`cmd_stop_qemu` 空工作区退出码~~：**已实测核对（评审第五轮）**——`cmd_status` 空工作区无 exit（=0）、`cmd_stop_qemu` 无实例无 exit（=0），推翻原"暂定 3"。退出码表已更新为 0。
2. **xtrace 子 shell/transitive 捕获**：BASH_XTRACEFD + PS4 方案对 `(...)` / `$(...)` 边界的函数调用是否完整捕获，需 spike 验证；不稳则退人工声明矩阵。
3. **`bitbake -e` fake 覆盖度**：能否覆盖 `resolve_qb_vars` 全分支，需真实 workspace 抓样本后验证。
4. **pre-commit 基建是否存在**：ob-harness 仓库是否已有 pre-commit 机制（`.pre-commit-config.yaml` / husky / `.git/hooks`），决定"自动提醒点"落地方式；无则需新建或退 CI 门禁。此条与 CI runner 能力（能否跑 QEMU + 预置 workspace）挂钩，共同决定 integration 能否 CI 化。
