# QEMU 命令簇切出实施计划

## 目标

把 `lib/commands.sh` 里的 QEMU 命令簇（`cmd_start_qemu` / `cmd_stop_qemu` / `cmd_deploy_to_qemu`，约 404 行）**原样**切出到新建 `lib/qemu_commands.sh`，建立"QEMU 命令编排"L1 exit-seam 深模块。commands.sh 从 1207 行瘦到约 803 行（-1/3），未来 QEMU 相关改动落进单一文件边界。

本次是**纯物理切出**：函数名、函数体逻辑、exit-code 契约、调用方零变更；不借机深化（QEMU 全局收口留作独立后续）。

## 架构快照

- `lib/commands.sh` 当前是 lib/ 最大文件（1207 行 / 48 KB），把 6 个正交命令簇的 L1 编排同居一室，是最近 30 次提交的改动热点（13 次）。
- QEMU 命令簇（commands.sh:422-825）高内聚：共享 `qemu_instance_*` / `derive_qemu_paths` / `qemu_prepare_launch` / `qemu_execute_launch` / 端口复用 / confirm banner；与其余命令簇仅共享通用 helper（`exit_on_user_cancel` / `pick_machine` / `confirm_action`）。
- 切出形态对照（grilling Q5 共识）：`qemu_commands.sh` 是 **L1 exit-seam**（顶层命令直接字面 `exit`，无 dispatcher 收口），区别于 `lib/devtool_subcmd.sh` 的 **L3 leaf-pure handler**（子命令 `return` exit-code，由 `cmd_dev` 收口 exit）。前者不进 `exit_contract` 的 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`，后者进。
- `ob` 主入口用 `for f in "$OB_ENTRY_DIR"/lib/*.sh; do source "$f"; done`（[ob:73](ob#L73)）全量 source，新增 `lib/qemu_commands.sh` 自动包含；dispatch（[ob:286-297](ob#L286-L297)）按函数名调用 `cmd_start_qemu` 等，跨文件调用成立。

## 全局约束

- **纯物理切出**：三函数体逐字搬迁，不改函数名、不改逻辑、不改 exit-code 契约、不改调用方、不改测试。
- **命名规则**：`lib/*.sh` snake_case；新文件名 `qemu_commands.sh`（与 `commands.sh` 对称，`cmd_*` 前缀直指 L1 命令层）。
- **文件级 exit 契约**：`qemu_commands.sh` 是 exit seam（直接字面 `exit N`），**不进** `LEAF_EXIT_EXCEPTIONS_BY_BASENAME`（[exit_contract.py:53-72](tools/exit_contract.py#L53-L72)）。机理（已核实源码，非直觉）：`check_X`（[exit_contract.py:143-164](tools/exit_contract.py#L143-L164)）遍历 `all_funcs`（默认扫描集 = `ob` + `sorted(lib/*.sh)`，[collect_files:133-140](tools/exit_contract.py#L133-L140)）**无 basename 过滤**，校验每个函数字面 exit ∈ {0,1,2,3}、bare/dynamic exit 仅允许 `require_path`；`check_Y`（[:191-218](tools/exit_contract.py#L191-L218)）只遍历 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 的**键**，新 basename 不在键 → `leaf_exiters` 返回 None → `continue` 跳过。因此 `qemu_commands.sh` 不登记 = Y 不校验它，三函数全字面 exit 0/1/2/3 → X 已合规。`exit_contract.py` 零改动。**切勿**误把 `qemu_commands.sh` 登记进 LEAF 字典——空例外集 + 函数体有 exit 会触发 Y FAIL（"unexpectedly exits"）。
- **配套自检**：改 `ob` / `lib/*.sh` 后必跑 `tools/ob_check.sh`（AGENTS.md 工作模式）。
- **共享 helper 归属**：`exit_on_user_cancel`（定义于 commands.sh:200，内部 `exit 2`/`exit 1`，exit-seam 性质，不能进 leaf-pure 的 util.sh）**留 commands.sh**，`qemu_commands.sh` 跨文件调用；`qemu_commands.sh` 文件头注释显式注明此依赖。

## 输入工件

- 架构候选分析：`/tmp/architecture-review-20260722-212823.html`（deletion test、热点证据、before/after）。
- grilling 共识（Q1-Q5，本会话 inline 决策，未落独立 design spec——Q5 决定不立 ADR、不动 CONTEXT.md）：
  - Q1 scope = 纯物理切出
  - Q2 归属 = 新建 `lib/qemu_commands.sh`（不并入 `qemu.sh`，L1⇎L3 层级正交）
  - Q3 helper = `exit_on_user_cancel` 留 commands.sh + 跨文件调用
  - Q4 测试 = 现有测试作回归锁，不补 unit
  - Q5 沉淀 = 文件头注释（含形态对照）+ WORKSPACE 登记；不动 CONTEXT.md、不立 ADR

## 文件结构与职责

- **Create**: `lib/qemu_commands.sh` — QEMU 命令簇 L1 exit-seam 模块，含 `cmd_start_qemu` / `cmd_stop_qemu` / `cmd_deploy_to_qemu`（从 commands.sh:422-825 逐字迁入）+ exit-seam 文件头注释（形态对照句 + `exit_on_user_cancel` 依赖注记）。
- **Modify**: `lib/commands.sh` — 删除 422-825（三命令），文件头第 2 行命令清单改为 `status/build/init/dev/menu`。
- **Modify**: `rules/03_WORKSPACE.md` — `lib/` 模块化主体路由条目登记 `qemu_commands.sh`。
- **Test（不改，作回归锁）**: `tests/orchestration/{start_qemu_force_restart,start_qemu_stale_pid,stop_qemu_stale_pid,deploy_to_qemu}.sh` + `tests/protocol/{exit_codes,usage_dispatch_sync}.sh` + `tests/integration/ob_deploy_to_qemu.sh` + `tests/integration/manual_matrix_qemu.exp`。函数名不变 → 原样通过。
- **不改**: `ob`（自动 source）、`tools/exit_contract.py`（exit seam 不进 LEAF 字典）、任何测试文件。

## 任务清单

### Task 1: 新建 lib/qemu_commands.sh 迁入 QEMU 三命令

- 目标：新建 `lib/qemu_commands.sh`，把 commands.sh:422-825 的三个函数逐字迁入，附 exit-seam 文件头注释。
- Files
  - Create: `lib/qemu_commands.sh`
- 接口契约
  - Consumes: `lib/commands.sh:422-825`（三函数源码，迁移源——逐字复制，不改一字）。
  - Produces: `lib/qemu_commands.sh`，含 `cmd_start_qemu` / `cmd_stop_qemu` / `cmd_deploy_to_qemu` 三个 L1 exit-seam 函数；后续 Task 2/3/4 依赖此文件存在。
- 验证范围: 文件存在 + 含恰好 3 个目标函数定义 + bash 语法正确。

- [ ] Step 1: 改动前检查——目标文件尚不存在
  - Run: `test ! -e lib/qemu_commands.sh && echo absent`
  - Expected: 输出 `absent`（test 成功即文件不存在，退出码 0）。

- [ ] Step 2: 写最小实现——新建 `lib/qemu_commands.sh`
  - Change: 新建文件。文件头"描述行 + `# Exit:` 行"对齐 `commands.sh` 同族风格（qemu_commands.sh 与 commands.sh 同为 L1 exit-seam 命令编排，非 `qemu.sh` 那种 L3 direct-exit runtime，故不套用 qemu.sh 的单行 Exit 格式）；形态对照 + 依赖为 grilling Q5 共识要求的防误读注释。随后把 `lib/commands.sh:422-825`（从 `cmd_start_qemu() {` 到 `cmd_deploy_to_qemu` 的闭合 `}`，含三函数完整体）**逐字**复制到文件头下方：

    ```bash
    #!/usr/bin/env bash
    # lib/qemu_commands.sh — QEMU 命令簇 L1 编排(cmd_start_qemu/cmd_stop_qemu/cmd_deploy_to_qemu). 术语见 CONTEXT.md function semantic layer / exit-code 契约 / ob deploy-to-qemu.
    # Exit: exit seam（L1 cmd_* 顶层编排, 使用 exit-code 契约值 0/1/2/3）.
    # 形态对照: L1 exit-seam 命令族(顶层命令直接 exit, 无 dispatcher 收口), 区别于 lib/devtool_subcmd.sh 的 L3 leaf-pure handler(return exit-code, 由 cmd_dev 收口 exit)。
    # 依赖: exit_on_user_cancel 定义于 lib/commands.sh, 跨文件调用; ob 用 for f in lib/*.sh 全量 source 后可见。
    ```

- [ ] Step 3: 运行并确认通过
  - Run: `bash -n lib/qemu_commands.sh`
  - Expected: 无输出，退出码 0（语法正确）。
  - Run: `grep -cE '^cmd_(start_qemu|stop_qemu|deploy_to_qemu)\(\)' lib/qemu_commands.sh`
  - Expected: `3`。

- [ ] Step 4: 可选 checkpoint commit
  - Run: `git add lib/qemu_commands.sh && git commit -m "feat(qemu): extract qemu_commands.sh L1 exit-seam module (cmd_start/stop/deploy_to_qemu)"`
  - Expected: commit 成功。

### Task 2: 从 lib/commands.sh 移除 QEMU 三命令并更新文件头

- 目标：commands.sh 删除 422-825（三命令），文件头第 2 行命令清单改为剩余命令。
- Files
  - Modify: `lib/commands.sh`（符号锚点：`cmd_start_qemu` 至 `cmd_deploy_to_qemu` 函数体；文件头第 2 行注释）。
- 接口契约
  - Consumes: Task 1 产出的 `lib/qemu_commands.sh`（已含三函数，保证删除后函数不丢、ob dispatch 仍可解析）。
  - Produces: `lib/commands.sh` 仅剩 `cmd_status` / `cmd_build` / `cmd_init` / `cmd_dev` / `cmd_menu` + `status_section_*` + `exit_on_user_cancel`。
- 验证范围: commands.sh 不再含三函数定义 + bash 语法正确 + 文件头命令清单已更新。

- [ ] Step 1: 改动前检查——commands.sh 当前含三函数
  - Run: `grep -cE '^cmd_(start_qemu|stop_qemu|deploy_to_qemu)\(\)' lib/commands.sh`
  - Expected: `3`（当前存在）。

- [ ] Step 2: 确认当前状态
  - Run: `grep -nE '^cmd_(start_qemu|stop_qemu|deploy_to_qemu)\(\)' lib/commands.sh`
  - Expected: 三行命中（422 / 563 / 686 附近）。

- [ ] Step 3: 写最小实现
  - Change:
    1. 删除 `cmd_start_qemu() {` 到 `cmd_deploy_to_qemu` 闭合 `}` 的整段（原 422-825），保留删除处前后各一个空行作分隔（上接 cmd_build 的 `}`，下接 `cmd_init`）。
    2. 文件头第 2 行由：
       `# lib/commands.sh — cmd_* 命令编排(status/init/build/start-qemu/stop-qemu/menu). 术语见 CONTEXT.md function semantic layer / exit-code 契约.`
       改为：
       `# lib/commands.sh — cmd_* 命令编排(status/build/init/dev/menu). 术语见 CONTEXT.md function semantic layer / exit-code 契约.`
       措辞依据（一次性整理，非逐字保留原序）：
       - 新顺序 `status/build/init/dev/menu` 按**切出后函数在文件中的物理定义顺序**（`cmd_status`:210 → `cmd_build`:259 → `cmd_init`:827 → `cmd_dev`:968 → `cmd_menu`:1115），顺手修正原注释 `init/build` 的乱序（原 `status/init/build` 与物理顺序「build 在 init 前」不一致，属历史遗漏）。
       - `start-qemu/stop-qemu` 随 QEMU 簇切走，移除。
       - `deploy-to-qemu` 本就**未在**原 line 2 注释中（历史遗漏），切走后亦无需提及。
       - `dev` 一直在文件内但旧注释漏列，补上。
       - `exit_on_user_cancel` 是 helper 不计入命令清单。

- [ ] Step 4: 运行并确认通过
  - Run: `bash -n lib/commands.sh`
  - Expected: 无输出，退出码 0。
  - Run: `grep -cE '^cmd_(start_qemu|stop_qemu|deploy_to_qemu)\(\)' lib/commands.sh`
  - Expected: `0`（已移除）。
  - Run: `sed -n '2p' lib/commands.sh`
  - Expected: 行内含 `status/build/init/dev/menu`，不含 `start-qemu` 或 `stop-qemu`。

- [ ] Step 5: 可选 checkpoint commit
  - Run: `git add lib/commands.sh && git commit -m "refactor(qemu): remove QEMU command cluster from commands.sh (moved to qemu_commands.sh)"`
  - Expected: commit 成功。

### Task 3: rules/03_WORKSPACE.md 路由表登记 qemu_commands.sh

- 目标：WORKSPACE 的 `lib/` 模块化主体路由条目登记 `qemu_commands.sh`，让后续 session 能定位。
- Files
  - Modify: `rules/03_WORKSPACE.md`（章节锚点："项目与代码" → "`ob` 模块化主体：`lib/`" 那一条）。
- 接口契约
  - Consumes: Task 1 产出的 `lib/qemu_commands.sh`（登记对象）。
  - Produces: WORKSPACE 路由表含 `qemu_commands.sh` 条目。
- 验证范围: WORKSPACE 含 `qemu_commands.sh` 命中。

- [ ] Step 1: 改动前检查——WORKSPACE 尚未登记
  - Run: `grep -c 'qemu_commands\.sh' rules/03_WORKSPACE.md`
  - Expected: `0`（grep -c 输出 0 = 未命中）。

- [ ] Step 2: 写最小实现
  - Change: 在 `rules/03_WORKSPACE.md` 的 `lib/` 模块化主体条目（当前以 `devtool_subcmd.sh` 收尾那一长行）末尾追加登记：
    ` / qemu_commands.sh QEMU 命令簇 L1 编排（cmd_start_qemu/cmd_stop_qemu/cmd_deploy_to_qemu，exit seam；形态对照 devtool_subcmd.sh 的 leaf-pure handler）`。
    措辞与同条目其他 `qemu_*.sh` 登记风格一致。

- [ ] Step 3: 运行并确认通过
  - Run: `grep -n 'qemu_commands\.sh' rules/03_WORKSPACE.md`
  - Expected: 至少一行命中，且所在行属 `lib/` 模块化主体条目。

- [ ] Step 4: 可选 checkpoint commit
  - Run: `git add rules/03_WORKSPACE.md && git commit -m "docs(workspace): register qemu_commands.sh in lib routing table"`
  - Expected: commit 成功。

### Task 4: 配套自检与回归测试

- 目标：跑 `tools/ob_check.sh` 四维自检 + `tests/run_all.sh --full` 回归锁，证明切出零回归。
- Files: 无（纯验证任务）。
- 接口契约
  - Consumes: Task 1-3 全部产出（`lib/qemu_commands.sh` 已建、`lib/commands.sh` 已删三命令、WORKSPACE 已登记）。
  - Produces: 无。
- 验证范围: ob_check.sh `ALL GREEN` + run_all --full 全绿。

- [ ] Step 1: 运行 ob_check.sh（extract_funcs / surface gates / shellcheck baseline / exit-contract / run_all 默认层）
  - Run: `tools/ob_check.sh`
  - Expected: 末行 `ALL GREEN (PASS=N)`，退出码 0。重点确认：
    - `extract_funcs lib 三段全清` 含新增 `qemu_commands.sh`（函数登记被识别）；
    - `exit-contract ok`（qemu_commands.sh 作为 exit seam 未引入 X 违规，未误进 leaf-pure 字典）；
    - shellcheck baseline 若报 `自动重生成(flat)`：执行 `git diff tests/.shellcheck-baseline`，确认仅行号平移/告警减少等良性差异（纯搬家不应新增告警类型），纳入本次 commit；若报 `新增告警` 则停下排查。

- [ ] Step 2: 运行 run_all.sh --full（加 .exp 交互矩阵，作 QEMU 命令簇回归锁）
  - Run: `tests/run_all.sh --full`
  - Expected: protocol + unit + orchestration 的 `.sh` 与 `.exp` 全绿；含 `start_qemu_*` / `stop_qemu_*` / `deploy_to_qemu` / `usage_dispatch_sync` 等在内的 QEMU 相关测试原样通过（函数名未变）。

- [ ] Step 3: 可选——integration 层按需
  - Run: `tests/run_all.sh --integration`
  - Expected: `ob_deploy_to_qemu.sh` 等真实 build + QEMU 集成测试通过。**前提**：环境具备已 init 的 machine 与可用 QEMU binary，耗时较长；CI 或手动按需执行，非本次必跑。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行（Task 1 必须先于 Task 2，保证删除前函数已落位新文件），不无声跳步、不合并步。
- 每完成一个任务，运行该任务 Step 4 的验证；不过则停下排查，不往下走。
- Task 4 若 ob_check 报 shellcheck `新增告警` 或 run_all 任一失败，立即停下说明，不猜原因。
- 若当前在 `main`/`master` 且用户未明确同意，开始实现前先确认分支策略。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `tools/ob_check.sh && tests/run_all.sh --full`
- Expected:
  - `ob_check.sh` 末行 `ALL GREEN (PASS=N)`，退出码 0；`tests/.shellcheck-baseline` 若被重生成，`git diff` 确认良性。
  - `run_all.sh --full` 全绿（protocol/unit/orchestration 的 `.sh` + `.exp`）。
- 修改摘要应包含：新建 `lib/qemu_commands.sh`（~404 行）；`lib/commands.sh` 1207 → ~803 行；`rules/03_WORKSPACE.md` 登记；`tests/.shellcheck-baseline`（若重生成）；零接口/零门禁配置/零测试改写。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-07-22-qemu-commands-extraction-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
