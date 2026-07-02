# BitBake Environment One-Shot Support Module 实施计划

## 目标

本次一次落定 BitBake environment one-shot 进入路径收敛：新增 `lib/bitbake_env.sh`，只接管天然隔离的 `repo.sh:list_available_machines` 和 `qemu.sh:resolve_qemu_launch_profile` fallback 查询；不替换 `init_bitbake_env`、`generate_dep_graph`、`cmd_build` 三处 current-shell `source setup` 路径。

完成标准：

- 五处现有 BitBake environment 进入路径的关键差异被 characterization 测试锁住。
- `lib/bitbake_env.sh` 是 leaf-pure/no-exit support module，并被 `exit_contract.py` 的 Y 规则守住。
- `repo.sh` 改为调用 one-shot helper 且行为不变；`qemu.sh` 改为调用 one-shot helper 后保持既有成功路径与调用次数，并显式收窄 helper 非零返回为失败。
- ADR-0002 的 QB 来源真实性不变；ADR-0007 的 qemuboot fast path 0 次 bitbake、fallback 1 次 bitbake 调用次数锁不变。
- `CONTEXT.md` 和 `rules/03_WORKSPACE.md` 的 `lib/` 文件边界描述同步到新 module。

## 架构快照

`bitbake_env` 只表达 BitBake environment 的 one-shot 查询能力，不承担命令编排层的 exit/remedy 责任，也不下沉 QEMU launch profile 的 QB 解析、SoC 证据、AST2700 bootloader 校验等领域判断。

第一版 interface：

两个 helper 都依赖 caller 已设置的全局 `OPENBMC_DIR`，并在自身内部 `cd "$OPENBMC_DIR"` 后、执行 `source setup` 前先 `set +u`；这与现有各处 source setup 对 oe-init-build-env 引用 unset 变量的兼容方式保持一致。

- `bitbake_env_list_available_machines`
  - 在内部 `set +u` 后捕获无参 `source setup` 的 stdout/stderr（`2>&1`），并解析 `Use one of:` 后的 machine 列表。
  - 保留当前 `|| true` 语义：无参 setup 退出不让 ob 主流程退出。
  - stdout 只输出解析后的 machine names；解析不到时输出为空。
  - 不 `exit`，不打印 remedy。
- `bitbake_env_query_vars <machine> <build_dir>`
  - 运行 `set +u; source setup <machine> <build_dir> 2>/dev/null && bitbake -e 2>/dev/null`。
  - stdout 输出原始 `bitbake -e` 文本。
  - setup 或 bitbake 失败时返回非零。
  - stderr 不向 caller 泄漏。
  - 不判断空输出，不解析 `QB_*`，不 `exit`，不打印 remedy。

Current-shell 三处保持原状并只加测试锁：

- `init_bitbake_env`
- `generate_dep_graph`
- `cmd_build`

原因：这三处依赖 `source setup` 的副作用留在当前 shell；setup 内部 `exit` 会穿透 ob 主进程，leaf-pure/no-exit helper 无法可靠把它改造成返回码。它们的 dry-run、`nounset` 恢复、source 后副作用检查继续由 caller 拥有。

## 输入工件

- 本会话 `/grill-with-docs` 批准口径：one-shot 两处接管，current-shell 三处不接管；helper no-exit；caller 保留 exit/remedy；不写 ADR。
- 现有代码锚点：
  - `lib/init_pipeline.sh`：`init_bitbake_env`、`generate_dep_graph`
  - `lib/commands.sh`：`cmd_build`
  - `lib/qemu.sh`：`resolve_qemu_launch_profile`
  - `lib/repo.sh`：`list_available_machines`
  - `tools/exit_contract.py`：`LEAF_EXIT_EXCEPTIONS_BY_BASENAME`
  - `tests/protocol/qemu_launch_profile_structure.sh`
  - `tests/orchestration/qemu_launch_profile.sh`

## 文件结构与职责

- Create: `lib/bitbake_env.sh`
  - Leaf-pure/no-exit support module。
  - 提供 `bitbake_env_list_available_machines` 和 `bitbake_env_query_vars`。
- Create: `tests/protocol/bitbake_env_entry_contract.sh`
  - Characterization 测试，只锁当前五处入口的可观察契约。
  - 放在 protocol 层，因为它锁 dry-run、`nounset`、exit、stderr 和调用次数这些入口协议契约。
  - 不依赖未来 helper 名字，不要求 `lib/bitbake_env.sh` 存在。
- Create: `tests/protocol/bitbake_env_structure.sh`
  - 结构锁，验证目标 module、exit_contract 登记、调用点迁移和 current-shell 三处未误替换。
- Modify: `lib/repo.sh`
  - `list_available_machines` 改为调用 `bitbake_env_list_available_machines`。
- Modify: `lib/qemu.sh`
  - `resolve_qemu_launch_profile` fallback 改为调用 `bitbake_env_query_vars`。
  - 保留空输出/失败诊断、exit 1、QB 解析和 QEMU launch profile 决策。
- Modify: `tools/exit_contract.py`
  - 在 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 中登记 `'bitbake_env.sh': set()`。
- Modify: `CONTEXT.md`
  - 更新 `function semantic layer` 的 `lib/` 文件边界描述，加入 `bitbake_env`。
  - 补充 BitBake environment support module 的术语说明。
- Modify: `rules/03_WORKSPACE.md`
  - 更新 `lib/` 路由说明，加入 `bitbake_env.sh` 职责。

## 任务清单

### Task 1: 添加 BitBake environment 入口 characterization 测试

- 目标：先锁住现有五处入口的可观察行为，不改变生产代码。
- 涉及文件：`tests/protocol/bitbake_env_entry_contract.sh`
- 验证范围：current-shell 三处 dry-run / `nounset` / 副作用检查，one-shot 两处 setup exit 隔离和 bitbake 调用语义。

- [ ] Step 1: 创建 `tests/protocol/bitbake_env_entry_contract.sh`
- Change:
  - 使用 `tests/lib/ob_loader.sh`、`tests/lib/assert.sh`、`tests/lib/stub.sh`。
  - 为每个 case 使用 `mktemp -d` 隔离 `OPENBMC_DIR`、`BUILD_DIR`、`CONFIGS_DIR`。
  - 用 fake `setup` 写 marker 文件、向 stderr 输出 `Use one of:`、引用 unset 变量或故意 `exit`；用 fake `bitbake` 记录调用次数。所有需要 source setup 的 case 显式在 `set -u` 环境下运行，以暴露漏掉 `set +u` 的实现。
  - 对会触发 current-shell `exit` 的 case 使用 `assert_rc` 或显式 subshell 隔离，避免终止整个测试脚本。
  - `cmd_build` dry-run case 必须在临时工作区准备 `OPENBMC_DIR/.git`、source manifest 和 `<machine>.init-done` marker，确保能到达 dry-run 分支。
  - `init_bitbake_env` nounset 恢复 case 必须将 `HOME` 指向 `mktemp -d` 或 stub 掉 `ensure_bootstrap_local_conf`，避免 `git config --global` 污染真实用户环境。
- Expected coverage:
  - `init_bitbake_env` 在 `DRY_RUN=1` 时不 source setup。
  - `generate_dep_graph` 在 `DRY_RUN=1` 时不 source setup、不调用 bitbake。
  - `cmd_build` 在 `DRY_RUN=1` 时不 source setup、不调用 bitbake。
  - `init_bitbake_env` 可在 `set -u` 环境下 source 一个引用 unset 变量的 setup，并在函数返回后恢复 `nounset`。
  - `init_bitbake_env` source 后缺少 `conf/local.conf` 时 exit 1。
  - `resolve_qemu_launch_profile` bitbake fallback 恰好调用一次 bitbake。
  - `resolve_qemu_launch_profile` / `list_available_machines` 的现状 one-shot 入口在 `set -u` 环境下也能 source 引用 unset 变量的 setup。
  - `resolve_qemu_launch_profile` fake bitbake 输出为空时仍由 QEMU caller exit 1。
  - `resolve_qemu_launch_profile` 的 setup / bitbake stderr 不泄漏到 caller 输出。
  - `list_available_machines` 可解析从 stderr 输出的无参 setup `Use one of:` 列表，即使 setup 以非零退出。
  - helper 非零且 stdout 非空也失败的收窄行为在 Task 5 实现后验证。
- [ ] Step 2: 运行 characterization 测试
- Run: `bash tests/protocol/bitbake_env_entry_contract.sh`
- Expected: 输出 `ALL GREEN` 或该仓库 assert 框架的全通过汇总；不要求 `lib/bitbake_env.sh` 存在。

### Task 2: 添加目标结构锁测试

- 目标：把本次目标结构写成机器可验证的失败检查，先确认当前代码会失败。
- 涉及文件：`tests/protocol/bitbake_env_structure.sh`
- 验证范围：目标 module 存在、leaf-pure 登记、helper 调用点、current-shell 三处不误替换。

- [ ] Step 1: 创建 `tests/protocol/bitbake_env_structure.sh`
- Change:
  - 复用 `tests/protocol/qemu_launch_profile_structure.sh` 中的 shell function extraction 模式，或在本测试内提供同等的 `extract_shell_function` helper。
  - 检查 `lib/bitbake_env.sh` 存在。
  - 检查 `tools/exit_contract.py` 包含 `'bitbake_env.sh': set()`。
  - 检查 `lib/bitbake_env.sh` 中没有真实 bash `exit` 命令；最终 no-exit 以 `exit_contract.py` 为权威，本测试给出更窄的失败定位。
  - 检查 `repo.sh:list_available_machines` 调用 `bitbake_env_list_available_machines`。
  - 检查 `qemu.sh:resolve_qemu_launch_profile` 调用 `bitbake_env_query_vars`。
  - 检查 `init_pipeline.sh:init_bitbake_env`、`init_pipeline.sh:generate_dep_graph`、`commands.sh:cmd_build` 不调用 `bitbake_env_` helper。
- [ ] Step 2: 运行结构锁，确认当前失败
- Run: `bash tests/protocol/bitbake_env_structure.sh`
- Expected: 失败原因至少包含缺少 `lib/bitbake_env.sh` 或缺少 `bitbake_env.sh` leaf-pure 登记；不得因为 shell 语法错误失败。

### Task 3: 创建 leaf-pure `bitbake_env` support module 并登记 no-exit 不变量

- 目标：落地 `lib/bitbake_env.sh` 的两个 helper，并把 no-exit 设计意图纳入 `exit_contract.py` Y 规则。
- 涉及文件：`lib/bitbake_env.sh`、`tools/exit_contract.py`
- 验证范围：新 module 结构干净、无 exit、leaf-pure 登记生效。

- [ ] Step 1: 新增 `lib/bitbake_env.sh`
- Change:
  - 文件保持 lib 三段纯函数定义结构：shebang + 注释 header，随后只定义函数。
  - 实现 `bitbake_env_list_available_machines`：依赖全局 `OPENBMC_DIR`，在隔离命令中运行无参 `set +u; source setup 2>&1 || true`，解析 machine list，并且 stdout 只输出解析后的 machine names。
  - 实现 `bitbake_env_query_vars <machine> <build_dir>`：依赖全局 `OPENBMC_DIR`，在隔离命令中运行 `set +u; source setup "$machine" "$build_dir" 2>/dev/null && bitbake -e 2>/dev/null`，返回命令退出码，stdout 仅输出 `bitbake -e` 原文。
  - 函数不打印 remedy，不调用 `exit`，不解析 `QB_*`，不把 query helper 的 stderr 泄漏给 caller。
- [ ] Step 2: 更新 `tools/exit_contract.py`
- Change: 在 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME` 中加入 `'bitbake_env.sh': set()`。
- [ ] Step 3: 验证新 module 与 exit contract
- Run: `python3 tools/extract_funcs.py lib/bitbake_env.sh && python3 tools/exit_contract.py`
- Expected:
  - `extract_funcs.py` 显示 `GAPS 0`，无 `HEADER_TOPLEVEL`、`GAP`、`FOOTER_TOPLEVEL`。
  - `exit_contract.py` 退出码为 0，Y 规则包含 leaf-pure 检查且无 `bitbake_env.sh` exit 违规。

### Task 4: 迁移 repo machine list one-shot 入口

- 目标：让 `repo.sh:list_available_machines` 通过 `bitbake_env_list_available_machines` 获取 machine list，保持无参 setup exit 隔离语义。
- 涉及文件：`lib/repo.sh`
- 验证范围：repo one-shot 行为和现有 characterization 测试保持通过。

- [ ] Step 1: 修改 `lib/repo.sh:list_available_machines`
- Change:
  - 保留 `[[ -d "$OPENBMC_DIR/.git" ]] || return 0` 这类 caller 前置。
  - 将 inline `cd "$OPENBMC_DIR" && set +u; source setup 2>&1 || true` 逻辑替换为 `bitbake_env_list_available_machines`。
  - 保持 stdout 仍为排序去重后的 machine names。
- [ ] Step 2: 验证 repo one-shot 行为
- Run: `bash tests/protocol/bitbake_env_entry_contract.sh`
- Expected: `list_available_machines` 相关 case 通过；current-shell 三处 characterization case 仍通过。

### Task 5: 迁移 QEMU launch profile bitbake fallback 查询

- 目标：让 `resolve_qemu_launch_profile` 使用 `bitbake_env_query_vars`，同时保持 QEMU caller 自己拥有失败诊断、空输出判断、QB 解析和调用次数锁。
- 涉及文件：`lib/qemu.sh`、`tests/orchestration/qemu_launch_profile.sh`
- 验证范围：ADR-0002 / ADR-0007 的成功路径和调用次数不变；helper 非零返回被显式视为失败。

- [ ] Step 1: 修改 `lib/qemu.sh:resolve_qemu_launch_profile`
- Change:
  - 将 inline `cd "$OPENBMC_DIR" && set +u; source setup "$MACHINE" "$BUILD_DIR" && bitbake -e` 替换为 `bitbake_env_query_vars "$MACHINE" "$BUILD_DIR"`。
  - 保留 `if [[ -z "$bitbake_output" ]]` 的 QEMU caller 诊断和 `exit 1`。
  - 若 helper 返回非零，caller 必须走与空输出一致的失败语义，即使 helper stdout 非空也不得 silent fallback。
  - 在 `tests/orchestration/qemu_launch_profile.sh` 增加 fake bitbake 返回非零且 stdout 非空的 case，断言 QEMU caller exit 1，不 silent fallback。
  - 不改 `qemu_launch_profile_extract_bitbake_var`、SoC 证据、machine-name fallback、AST2700 bootloader 校验。
- [ ] Step 2: 验证 QEMU launch profile 结构和行为
- Run: `bash tests/protocol/bitbake_env_entry_contract.sh && bash tests/protocol/bitbake_env_structure.sh && bash tests/protocol/qemu_launch_profile_structure.sh && bash tests/orchestration/qemu_launch_profile.sh`
- Expected:
  - 新 entry contract 全通过。
  - 新 structure test 全通过。
  - qemuboot fast path 仍 0 次 bitbake。
  - fallback 仍 1 次 bitbake。
  - QEMU launch profile 行为测试全通过。
  - fake bitbake 返回非零且输出非空时，QEMU caller 仍 exit 1，并输出既有 `bitbake -e` 失败诊断。

### Task 6: 同步 glossary 和 workspace 路由文档

- 目标：把新 module 纳入仓库长期知识，消除 `lib/` 六文件边界描述漂移。
- 涉及文件：`CONTEXT.md`、`rules/03_WORKSPACE.md`
- 验证范围：文档中明确 `bitbake_env.sh` 职责，且不新增 ADR。

- [ ] Step 1: 更新 `CONTEXT.md`
- Change:
  - 在 `function semantic layer` 术语中把 `lib/{util,repo,qemu,machine_state,init_pipeline,commands}` 更新为包含 `bitbake_env`。
  - 增加或嵌入 `BitBake environment support module` 说明：封装 one-shot `source setup` / `bitbake -e` 查询，不承担 caller exit/remedy，不接管 current-shell setup。
- [ ] Step 2: 更新 `rules/03_WORKSPACE.md`
- Change:
  - 在 `lib/` 路由说明中加入 `bitbake_env.sh` 的职责。
  - 保持 `ob/lib` 改动后需要跑 `tools/ob_check.sh` 的说明不变。
- [ ] Step 3: 磁盘级验证文档落点
- Run: `grep -n "bitbake_env\|BitBake environment" CONTEXT.md rules/03_WORKSPACE.md`
- Expected: 两个文件均命中新 module 名称或术语；`docs/adr/` 未新增文件。

### Task 7: 全量收口验证

- 目标：确认本次代码、测试、文档和门禁全部一致。
- 涉及文件：本计划列出的全部文件。
- 验证范围：快速测试、QEMU 相关行为锁、exit/shellcheck/结构门禁。

- [ ] Step 1: 运行本次新增与相关窄测试
- Run: `bash tests/protocol/bitbake_env_entry_contract.sh && bash tests/protocol/bitbake_env_structure.sh && bash tests/protocol/qemu_launch_profile_structure.sh && bash tests/orchestration/qemu_launch_profile.sh`
- Expected: 全部通过。
- [ ] Step 2: 运行仓库快速测试
- Run: `bash tests/run_all.sh`
- Expected: 输出 `ALL GREEN`。
- [ ] Step 3: 运行 ob/lib 配套自检
- Run: `OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 bash tools/ob_check.sh`
- Expected: `extract_funcs`、machine-state public surface gate、shellcheck baseline、exit-contract 全部通过；命令以 0 退出。
- [ ] Step 4: 检查工作区 diff 范围
- Run: `git diff -- docs/plans/2026-07-02-bitbake-env-one-shot-implementation-plan.md lib/bitbake_env.sh lib/repo.sh lib/qemu.sh tools/exit_contract.py tests/protocol/bitbake_env_entry_contract.sh tests/protocol/bitbake_env_structure.sh CONTEXT.md rules/03_WORKSPACE.md`
- Expected: diff 只包含本计划范围内的文件和本次目标相关改动。

## 执行纪律

- 开始实现前，先批判性复查整份计划；如果发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 如果当前就在 `main` 或 `master`，且用户没有明确同意，开始实现前先确认。
- 按任务顺序执行，不要无声跳步、合并步或改变任务目标。
- 每完成一个任务，都运行该任务定义的验证。
- `lib/bitbake_env.sh` 必须保持 leaf-pure/no-exit；caller 负责 exit/remedy。
- 不替换 `init_bitbake_env`、`generate_dep_graph`、`cmd_build` 三处 current-shell `source setup`，除非先回到设计讨论并更新本计划。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下来说明，不要猜。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

Run:

```bash
bash tests/protocol/bitbake_env_entry_contract.sh && \
bash tests/protocol/bitbake_env_structure.sh && \
bash tests/protocol/qemu_launch_profile_structure.sh && \
bash tests/orchestration/qemu_launch_profile.sh && \
bash tests/run_all.sh && \
OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 bash tools/ob_check.sh
```

Expected:

- 新增 protocol 测试全通过。
- QEMU launch profile 结构锁和行为测试全通过。
- `tests/run_all.sh` 输出 `ALL GREEN`。
- `tools/ob_check.sh` 输出 `ALL GREEN` 或等价全通过汇总，且以 0 退出。

## Inline 自检结果

- 设计覆盖度：已覆盖 one-shot 两处接管、current-shell 三处不接管、helper no-exit、caller 保留 remedy、stderr 差异、`set +u`、git 全局配置隔离、QEMU helper 非零收窄、ADR-0007 调用次数锁、文档同步和不写 ADR。
- 占位符扫描：未使用空占位词，每个任务均有明确文件、动作、命令和预期结果。
- 命名一致性：统一使用 `bitbake_env.sh`、`bitbake_env_list_available_machines`、`bitbake_env_query_vars`、`BitBake environment support module`。
- 可执行性：任务按 characterization、结构锁、helper、调用点迁移、文档、最终验证拆分，单步可验证。
- 验证完整性：每个任务都有窄验证，末尾有全量收口验证。

## 审阅 Checkpoint

实施计划到此结束。审阅通过前，不进入实现。