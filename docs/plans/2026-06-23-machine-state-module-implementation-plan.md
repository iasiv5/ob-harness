# Machine State Module 实施计划

## 目标

本计划实现已批准的 [docs/specs/2026-06-23-machine-state-module-design.md](../specs/2026-06-23-machine-state-module-design.md)：新增 `lib/machine_state.sh`，把 Machine lifecycle state 的存储规则和状态转换收敛到一个 deep module 后面，并让代码层完成 `<machine>.lock` 到 `<machine>.snapshot` 的硬切。

完成后必须满足：

- `machine snapshot`、`init-done marker`、deploy image / 顶层 build directory 查找由 `machine_state` module 拥有。
- `commands.sh` 和 `repo.sh::print_previously_initialized` 不直接 glob/解析 Machine lifecycle state 文件。
- 旧 `<machine>.lock` 不兼容、不提示，只在 `ob init <machine>` 过程中清理。
- QEMU PID file 仍归 `qemu.sh`。
- `machine_state.sh` 不直接 `exit`，并由 `exit_contract.py` 静态门禁守护。
- `ob init <machine> --dry-run` 不修改 configs 下任何 marker/snapshot/legacy lock 文件。
- `ob status` 保留当前 build 三态：succeeded / failed / never。

## 架构快照

新增 `lib/machine_state.sh` 作为 Machine lifecycle state module，职责覆盖 persistent state（`<machine>.snapshot`、`<machine>.init-done`）和 build artifact view（顶层 `$OPENBMC_DIR/build/<machine>`、deploy image）。`commands.sh` 继续作为 exit seam，聚合 `machine_state` 与 `qemu.sh`；`qemu.sh` 保留 QEMU runtime state；`repo.sh` 保留 machine selection UI，但 `print_previously_initialized` 读取 `machine_state` records。

`machine_state` list record 是内部 data interface，一行一个 machine，tab 分隔 `key=value`：

```text
machine=<name>\tinit=<none|partial|done>\tsnapshot=<yes|no>\trepos=<n|?>\tbuild=<never|failed|succeeded>\timage=<yes|no>\tinit_time=<UTC ISO or empty>
```

`build=failed` 的目录判定路径固定为顶层 `$OPENBMC_DIR/build/<machine>` 存在但无 `*.static.mtd`，用于保留当前 `ob status` 用户可见行为。

## 输入工件

- 设计文档：[docs/specs/2026-06-23-machine-state-module-design.md](../specs/2026-06-23-machine-state-module-design.md)
- 当前领域词表：[CONTEXT.md](../../CONTEXT.md)
- 已接受 ADR：[docs/adr/0001-init-done-marker.md](../adr/0001-init-done-marker.md)、[docs/adr/0003-ob-first-front-door.md](../adr/0003-ob-first-front-door.md)

## 文件结构与职责

Create:

- `lib/machine_state.sh`：Machine lifecycle state module。
- `tests/unit/machine_state.sh`：module 级读写、dry-run、image/build state 单测。
- `tests/protocol/status_machine_state.sh`：`ob status` 的 partial、legacy lock、build failed 行为测试。
- `tests/unit/repo_previously_initialized.sh`：`repo.sh::print_previously_initialized` 消费 machine_state records 的测试。

Modify:

- `tools/exit_contract.py`：Y 规则扩展为 leaf-pure basename 配置，纳入 `machine_state.sh`。
- `tests/unit/exit_contract.sh`：覆盖 `machine_state.sh` 中 `exit` 必须失败。
- `lib/init_pipeline.sh`：Step 6 从 lockfile 生成迁移为 snapshot 写入；report 文案改 snapshot。
- `lib/commands.sh`：`cmd_init`、`cmd_status`、`cmd_build`、`cmd_start_qemu` 迁移到 `machine_state` interface。
- `lib/repo.sh`：`print_previously_initialized` 迁移到 `machine_state` records。
- `CONTEXT.md`：`function semantic layer` 更新为六文件边界，并更新 `exit_contract` Y 规则描述。
- `tools/coverage_matrix.md`：`lockfile 生成` 行更新为 `machine snapshot 生成`。
- `tests/orchestration/generate_config.sh`：断言 `.snapshot` 输出与 dry-run 行为。
- `tests/protocol/build_noninteractive.sh`：确认缺 marker remedy 不变。
- `tests/protocol/start_qemu_remedy.sh`：确认缺 marker / 未 build remedy 不变。
- `tests/.shellcheck-baseline`：仅当 `tools/ob_check.sh` 自动重生成且 diff 确认合理时更新。

Stable boundaries:

- `lib/qemu.sh` 不迁出 PID file 读写/校验/清理。
- `repo.sh` 不把 machine selection / machine conf 解析交给 `machine_state`。
- `commands.sh` 保持 exit-code/remedy ownership。

## 任务清单

### Task 1: `exit_contract.py` 增加 leaf-pure basename 门禁

目标：让 `machine_state.sh` 中任何真实 `exit` 都导致 `tools/ob_check.sh` 失败。

Files:

- Modify: `tools/exit_contract.py` (`util_sh_exiters`, `check_Y`, `--seed-y` 输出)
- Modify: `tests/unit/exit_contract.sh`

验证范围：`bash tests/unit/exit_contract.sh` 和 `python3 tools/exit_contract.py`。

#### Step 1: 写失败测试

- Change: 参照 `tests/unit/exit_contract.sh` 现有 test 3 模式，在 `$TMP/lib/machine_state.sh` 创建含 `exit 1` 的 fixture，并显式传参运行 `python3 "$EXIT_CONTRACT" "$TMP/ob" "$TMP/lib/machine_state.sh"`；断言返回非零，输出包含 `machine_state.sh` 和函数名。不要在真实 `lib/` 下创建该 fixture。
- Run: `bash tests/unit/exit_contract.sh`
- Expected: 当前实现只检查 `util.sh`，`$TMP/lib/machine_state.sh` 的 `exit 1` 未被 leaf-pure Y 规则捕获，新断言失败。

#### Step 2: 实现 leaf-pure basename 配置

- Change: 在 `tools/exit_contract.py` 中引入 basename 配置，例如 `LEAF_EXIT_EXCEPTIONS_BY_BASENAME = {'util.sh': EXIT_EXCEPTIONS, 'machine_state.sh': set()}`；将 `util_sh_exiters` 泛化为按 basename 收集 exiters；`check_Y` 对每个配置文件执行对应 exception set；报错文案动态包含 basename，不再写死 `util.sh`。
- Run: `bash tests/unit/exit_contract.sh`
- Expected: exit-contract 单测通过，`machine_state.sh` fixture 中的 `exit 1` 被拒绝。

#### Step 3: 验证现有代码仍通过 exit contract

- Run: `python3 tools/exit_contract.py`
- Expected: X/Y/Z 均通过；Y 输出能表达 leaf-pure 检查已覆盖配置集合。

### Task 2: `machine_state.sh` 实现只读 records 和 image 查询

目标：新增 `machine_state` read interface，隐藏 snapshot / marker / build dir / deploy image 的路径规则。

Files:

- Create: `lib/machine_state.sh`
- Create: `tests/unit/machine_state.sh`

验证范围：`bash tests/unit/machine_state.sh`、`python3 tools/extract_funcs.py lib/machine_state.sh`。

#### Step 1: 写只读行为单测

- Change: 创建 `tests/unit/machine_state.sh`，用临时 `WORKSPACE_DIR`、`CONFIGS_DIR`、`OPENBMC_DIR` 构造以下 fixture：无状态、snapshot-only、marker-only、snapshot+marker、坏 JSON snapshot、顶层 build dir 无 image、deploy image、多个 image。
- Expected assertions:
  - 无 snapshot / 无 marker 时不列出 machine。
  - 有 snapshot / 无 marker 时 record 为 `init=partial`。
  - 有 marker 时 record 为 `init=done`。
  - marker 存在但 snapshot 不存在时 `repos=?`。
  - snapshot JSON 坏掉时 `repos=?` 且函数不失败。
  - 顶层 build dir 存在但无 image 时 `build=failed`。
  - 无顶层 build dir 时 `build=never`。
  - 多个 image 时 image path getter 返回排序后的第一个。
- Run: `bash tests/unit/machine_state.sh`
- Expected: 当前没有 `lib/machine_state.sh`，测试因 source 文件或函数缺失失败。

#### Step 2: 实现只读函数

- Change: 创建 `lib/machine_state.sh`，文件头说明 `machine_state` 是 Machine lifecycle state module。实现只读函数；函数名在 Task 2/3 定下后即为后续任务契约，Task 4-8 必须沿用同名，不得再改。必须覆盖：
  - snapshot path / marker path / deploy dir / top-level build dir derivation
  - `machine_state_list_records`
  - `machine_state_image_path <machine>`
  - `machine_state_has_init_done <machine>`
  - repo count JSON 容错，失败输出 `?`
  - `build=<never|failed|succeeded>` 三态
- Constraints: 不使用 `exit`，不打印 user-facing error，不格式化时间。
- Run: `bash tests/unit/machine_state.sh`
- Expected: 只读行为单测通过。

#### Step 3: 验证函数边界可解析

- Run: `python3 tools/extract_funcs.py lib/machine_state.sh`
- Expected: `GAPS 0`，没有函数边界解析失败；后续 `exit_contract.py` 能覆盖该文件。

### Task 3: `machine_state.sh` 实现 snapshot / marker 状态转换

目标：让 snapshot、marker 和 legacy lock 清理由 `machine_state` module 原子且 dry-run 安全地执行。

Files:

- Modify: `lib/machine_state.sh`
- Modify: `tests/unit/machine_state.sh`

验证范围：`bash tests/unit/machine_state.sh`、`python3 tools/exit_contract.py`。

#### Step 1: 扩展写入与 dry-run 单测

- Change: 在 `tests/unit/machine_state.sh` 增加断言：
  - snapshot 写入生成 `<machine>.snapshot`，不生成 `<machine>.lock`。
  - snapshot 写入使用同目录临时文件 + `mv`，失败时不留下半截目标文件；优先通过传入不存在的 deps.json 触发失败并观察目标未被覆盖，避免 chmod 目录造成权限垃圾。
  - `machine_state_mark_init_done` 写入 UTC timestamp marker。
  - `machine_state_clear_init_progress` 删除 marker、snapshot 和 legacy `.lock`。
  - `DRY_RUN=1` 时 clear / write snapshot / mark done 都不修改 configs 文件。
- Run: `bash tests/unit/machine_state.sh`
- Expected: 新写入相关断言失败，因为函数尚未实现。

#### Step 2: 实现写入和清理函数

- Change: 在 `lib/machine_state.sh` 实现：
  - `machine_state_write_snapshot <machine> <deps_json> <openbmc_commit>`，输出 JSON 字段与旧 lockfile 内容一致但写到 `<machine>.snapshot`。
  - `machine_state_mark_init_done <machine>`，写入 UTC timestamp。
  - `machine_state_clear_init_progress <machine>`，清理 marker、snapshot、legacy lock。
  - 所有写入先写同目录 tmp，再 `mv`。
  - 所有修改磁盘的函数在 `DRY_RUN=1` 时只返回成功并可用 `verbose` / `info [DRY-RUN]` 说明，不删除不写入。
- Run: `bash tests/unit/machine_state.sh`
- Expected: 写入、清理、dry-run 单测通过。

#### Step 3: 验证 no-exit 门禁

- Run: `python3 tools/exit_contract.py`
- Expected: `machine_state.sh` 中没有真实 `exit`，Y 规则通过。

### Task 4: `init_pipeline.sh` 迁移 Step 6 为 machine snapshot

目标：`ob init` 的 Step 6 写 `<machine>.snapshot`，report 文案更新，dry-run 不写状态文件。

Files:

- Modify: `lib/init_pipeline.sh` (`generate_lockfile` 相关函数)
- Modify: `lib/commands.sh` (`cmd_init` 开始和结束状态转换调用)
- Modify: `tests/orchestration/generate_config.sh`

验证范围：`bash tests/orchestration/generate_config.sh`、`python3 tools/extract_funcs.py lib/init_pipeline.sh lib/commands.sh`、`python3 tools/exit_contract.py`。

#### Step 1: 更新 orchestration 测试为 snapshot 期望

- Change: 将 `tests/orchestration/generate_config.sh` 中 lockfile 断言改为 snapshot：dry-run 不写 `<machine>.snapshot`，实写后读取 `<machine>.snapshot` 并断言 JSON 字段；断言 `<machine>.lock` 不存在。额外预置已有 marker、snapshot、legacy lock，跑 `ob init <machine> --dry-run` 或等价 orchestration dry-run 后确认三者仍存在，覆盖“不删已有”。
- Run: `bash tests/orchestration/generate_config.sh`
- Expected: 当前代码仍写 `.lock`，测试失败。

#### Step 2: 迁移 Step 6 实现

- Change: 将旧 `generate_lockfile` 重命名或改造为 `generate_machine_snapshot`。它负责取 `git rev-parse HEAD` 和调用 `machine_state_write_snapshot`；`cmd_init` Step 6 调用新函数。更新 `print_report` 中 `Lockfile:` 文案为 `Snapshot:`。
- Run: `bash tests/orchestration/generate_config.sh`
- Expected: orchestration 测试通过，`.snapshot` 生成，`.lock` 不生成。

#### Step 3: 迁移 init 开始/结束状态转换

- Change: 在 `cmd_init` 解析 machine 并设置 `BUILD_DIR` / `SRC_DIR` 后，用 `machine_state_clear_init_progress` 替代直接 `rm -f "$CONFIGS_DIR/$MACHINE.init-done"`。在 `print_report` 后用 `machine_state_mark_init_done` 替代直接重定向写 marker。
- Run: `bash tests/orchestration/generate_config.sh && bash tests/unit/machine_state.sh && python3 tools/extract_funcs.py lib/init_pipeline.sh lib/commands.sh && python3 tools/exit_contract.py`
- Expected: orchestration 和 unit 均通过。

### Task 5: `cmd_status` 迁移到 machine_state records

目标：`ob status` 不直接扫描 `.lock` / `.init-done` / deploy image，并保留 partial 和 build 三态。

Files:

- Modify: `lib/commands.sh` (`status_section_machines`, `cmd_status` tips)
- Create: `tests/protocol/status_machine_state.sh`

验证范围：`bash tests/protocol/status_machine_state.sh`、`python3 tools/extract_funcs.py lib/commands.sh`、`python3 tools/exit_contract.py`。

#### Step 1: 写 status protocol 测试

- Change: 创建 `tests/protocol/status_machine_state.sh`，构造临时 workspace；测试文件必须 `source tests/lib/ob_loader.sh` 后调用 `cmd_status`，不要裸 `OB_NO_MAIN=1 source ./ob`，避免 `set -euo pipefail` 泄漏到测试主进程。覆盖：
  - legacy `.lock` 单独存在时，该 machine 不进入 Machines 列表，不显示 partial，不提示 legacy ignored。
  - `.snapshot` 单独存在时显示 partial。
  - marker 存在时显示 done。
  - 顶层 build dir 存在但无 image 时显示 failed。
  - deploy image 存在时显示 succeeded。
- Run: `bash tests/protocol/status_machine_state.sh`
- Expected: 当前 `cmd_status` 仍读 `.lock` 且 image/build 逻辑未走 `machine_state`，测试失败。

#### Step 2: 迁移 `status_section_machines`

- Change: 用 `machine_state_list_records` 替换 `configs/*.init-done` / `*.lock` 合并扫描。通过 record 字段渲染 Init、Build、Repos、Init time、Image path。UI 文案保持当前风格：done / partial / succeeded / failed / never。
- Run: `bash tests/protocol/status_machine_state.sh`
- Expected: status protocol 测试通过。

#### Step 3: 迁移 `cmd_status` tips 的 never-built 判定

- Change: `cmd_status` tips 不再自行扫描 init-done 和 `*.static.mtd`，改为从 `machine_state` records 计算 `has_init_done` 和 `has_never_built`。
- Run: `bash tests/protocol/status_machine_state.sh && python3 tools/extract_funcs.py lib/commands.sh && python3 tools/exit_contract.py`
- Expected: status tips 行为不回退，测试和轻量结构/exit 门禁均通过。

### Task 6: `cmd_build` 迁移 initialized 和 image summary

目标：`cmd_build` 不直接扫描 init-done / snapshot / image path，remedy line 不变。

Files:

- Modify: `lib/commands.sh` (`cmd_build`)
- Modify: `tests/protocol/build_noninteractive.sh`

验证范围：`bash tests/protocol/build_noninteractive.sh`、`python3 tools/extract_funcs.py lib/commands.sh`、`python3 tools/exit_contract.py`。

#### Step 1: 扩展 build protocol 测试

- Change: 在 `tests/protocol/build_noninteractive.sh` 增加 fixture：只有 `.snapshot` 没有 marker 时，`cmd_build` exit 3，输出 `Run 'ob init romulus' first.`；legacy `.lock` 单独存在时同样不授予 build 资格。
- Run: `bash tests/protocol/build_noninteractive.sh`
- Expected: 当前 legacy `.lock` 对指定 machine build 未授予资格，snapshot-only 也未授予资格；如果测试已通过，记录这是现有行为；继续用后续实现确保行为保持。

#### Step 2: 迁移 build machine discovery

- Change: 未指定 machine 时，`cmd_build` 使用 `machine_state_list_records` 筛选 `init=done`；repo count 从 record 读取；init time 在 `commands.sh` 里用 `format_timestamp` 格式化。
- Run: `bash tests/protocol/build_noninteractive.sh`
- Expected: build protocol 测试通过，缺 marker remedy 不变。

#### Step 3: 迁移 build 成功 image summary

- Change: build 成功后用 `machine_state_image_path "$MACHINE"` 获取 image path，找不到时保持 `<not found>` 展示。
- Run: `bash tests/protocol/build_noninteractive.sh && python3 tools/extract_funcs.py lib/commands.sh && python3 tools/exit_contract.py`
- Expected: build protocol 测试通过；无新 exit-code 行为变化；结构/exit 门禁通过。

### Task 7: `cmd_start_qemu` 迁移 built discovery 和 image prerequisite

目标：`cmd_start_qemu` 用 `machine_state` 获取 built machines 和 image path，但 QEMU runtime 逻辑仍留在 `qemu.sh`。

Files:

- Modify: `lib/commands.sh` (`cmd_start_qemu`)
- Modify: `tests/protocol/start_qemu_remedy.sh`

验证范围：`bash tests/protocol/start_qemu_remedy.sh`、`python3 tools/extract_funcs.py lib/commands.sh`、`python3 tools/exit_contract.py`。

#### Step 1: 扩展 start-qemu remedy 测试

- Change: 在 `tests/protocol/start_qemu_remedy.sh` 增加 fixture：init done 但只有顶层 build dir、没有 image 时 exit 3，remedy line 为 `Run 'ob build' first.`；legacy `.lock` 单独存在时不视为 initialized。
- Run: `bash tests/protocol/start_qemu_remedy.sh`
- Expected: 当前实现的 missing image remedy 仍应通过；legacy lock hard-cut 相关断言在迁移前可能失败或需要新增后失败。

#### Step 2: 迁移 no-machine built discovery

- Change: `cmd_start_qemu` 未指定 machine 时使用 `machine_state_list_records` 筛选 `init=done` 且 `build=succeeded` 的 machines。没有 built machines 时，仍区分“无 initialized machines”和“已有 initialized 但未 built”，保持现有 remedy line。
- Run: `bash tests/protocol/start_qemu_remedy.sh`
- Expected: remedy line 测试通过。

#### Step 3: 迁移指定 machine image prerequisite

- Change: 用 `machine_state_image_path "$MACHINE"` 替代直接 `find deploy_dir ... '*.static.mtd'`。找不到 image 时保持 exit 3 和 `Run 'ob build' first.`。
- Run: `bash tests/protocol/start_qemu_remedy.sh && python3 tools/extract_funcs.py lib/commands.sh && python3 tools/exit_contract.py`
- Expected: start-qemu protocol 测试通过；QEMU PID file 相关逻辑未迁移；结构/exit 门禁通过。

### Task 8: `repo.sh::print_previously_initialized` 消费 machine_state records

目标：repo selection UI 不直接 glob `*.init-done`。

Files:

- Modify: `lib/repo.sh` (`print_previously_initialized`)
- Create: `tests/unit/repo_previously_initialized.sh`

验证范围：`bash tests/unit/repo_previously_initialized.sh`、`python3 tools/extract_funcs.py lib/repo.sh`、`python3 tools/exit_contract.py`。相对设计文档里的 orchestration 表述，本计划把该检查下沉为 unit test，因为它不经过 `ob` 编排，只验证 `print_previously_initialized` 函数消费 records 的行为。

#### Step 1: 写 repo selection UI 单测

- Change: 创建 `tests/unit/repo_previously_initialized.sh`，构造 machine array 和 configs state，断言 `print_previously_initialized` 只显示 `init=done` machines，时间由 `format_timestamp` 格式化；legacy `.lock` 不产生输出。
- Run: `bash tests/unit/repo_previously_initialized.sh`
- Expected: 当前实现直接 glob init-done，done case 可能通过；legacy lock 不影响。测试中加入“函数不直接依赖 raw glob”的断言可以通过 `machine_state` stub 或 shell function override 触发当前失败。

#### Step 2: 迁移 repo function

- Change: `print_previously_initialized` 调用 `machine_state_list_records`，从 records 中提取 `machine`、`init=done`、`init_time`。保留原有排序：按传入 machine array 的顺序匹配并显示原 index。
- Run: `bash tests/unit/repo_previously_initialized.sh && python3 tools/extract_funcs.py lib/repo.sh && python3 tools/exit_contract.py`
- Expected: repo unit 测试通过；无直接 init-done glob；extract_funcs 和 exit_contract 均通过。

### Task 9: 同步文档、覆盖矩阵和残留旧术语

目标：让当前约束文档和工具覆盖说明不再误导后续 agent。

Files:

- Modify: `CONTEXT.md`
- Modify: `tools/coverage_matrix.md`
- Search/Verify: `lib/`, `tests/`, `docs/adr/`

验证范围：`rg` 静态检查。

#### Step 1: 写当前残留检查

- Run: `rg -n "lockfile|<machine>\.lock|\.lock|machine_state|exit_contract.*util\.sh|lib/\{util,repo,qemu,init_pipeline,commands\}" CONTEXT.md tools/coverage_matrix.md lib tests docs/adr -g '!workspace/**'`
- Expected: 当前存在旧 lockfile / `.lock` / 五文件边界 / util-only exit_contract 描述等残留。

#### Step 2: 更新文档

- Change: `CONTEXT.md` 的 `function semantic layer` 更新为 `lib/{util,repo,machine_state,qemu,init_pipeline,commands}.sh` 六文件边界；`exit_contract` Y 规则描述更新为 leaf-pure basename modules（`util.sh` / `machine_state.sh`）。`tools/coverage_matrix.md` 中 lockfile 相关项改为 machine snapshot。
- Run: `rg -n 'lockfile|<machine>\.lock|lib/\{util,repo,qemu,init_pipeline,commands\}|basename\(.*util\.sh.*\)' CONTEXT.md tools/coverage_matrix.md docs/adr || true`
- Expected: 不再有会误导当前设计的旧 lockfile / 五文件边界 / util-only Y 规则表述；`CONTEXT.md` 的 `_Avoid_: lockfile...` 允许保留。

#### Step 3: 检查代码测试残留

- Run: `rg -n "\.lock|generate_lockfile|Lockfile|lockfile" lib tests -g '!workspace/**'`
- Expected: 只允许 `openbmc-source.lock`、QEMU update `.lock`、legacy cleanup 测试/实现、以及明确的 `_Avoid_` 或 hard-cut 断言；不应有 `<machine>.lock` 作为 active state 的读取或写入。

### Task 10: 运行分层验证并处理 shellcheck baseline

目标：用仓库标准门禁收口全部改动。

Files:

- Potential Modify: `tests/.shellcheck-baseline`

验证范围：`tools/ob_check.sh`、必要时 `tests/run_all.sh --full`。

#### Step 1: 运行标准自检

- Run: `tools/ob_check.sh`
- Expected: extract_funcs、shellcheck baseline、exit-contract、run_all 全绿；若 shellcheck baseline 自动重生成，必须检查 diff。

#### Step 2: 检查 shellcheck baseline diff

- Run: `git diff -- tests/.shellcheck-baseline`
- Expected: 无 diff，或只有确认合理的 baseline 行号平移/告警减少；如果出现新增告警内容，先修代码，不直接接受 baseline。

#### Step 3: 运行完整交互协议测试

- Run: `tests/run_all.sh --full`
- Expected: protocol/unit/orchestration 加 `.exp` 交互矩阵通过。若环境缺 `expect` 或外部依赖，记录阻塞原因，不把未跑说成通过。

#### Step 4: 最终残留扫描

- Run: `rg -n "<machine>\.lock|generate_lockfile|Lockfile|lockfile" lib tests CONTEXT.md docs/adr tools/coverage_matrix.md -g '!workspace/**'`
- Expected: 只剩允许的 `openbmc-source.lock`、QEMU update lock、legacy cleanup/hard-cut 测试、`CONTEXT.md` 禁用词说明；无 active Machine state `.lock` 读写。

## 执行纪律

- 开始实现前，先完整复查本计划和设计文档；如果发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 开始实现前运行 `git branch --show-current`。如果当前分支是 `main` 或 `master`，且用户没有明确同意在该分支修改，先停下确认。
- 按任务顺序执行，不要无声跳步、合并步或改变任务目标。
- 每完成一个任务，都运行该任务定义的验证命令。
- 任何任务验证失败时，先修同一任务范围内的问题并重跑同一验证；如果失败暴露计划与仓库现实不符，停下说明。
- 不迁移 QEMU PID file ownership；任何实现中出现 `machine_state` 读取或校验 PID file 都应视为偏离计划。
- 不把旧 `<machine>.lock` 做兼容路径；旧文件只能被 `ob init <machine>` 清理或被测试用作 hard-cut fixture。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

Run:

```bash
tools/ob_check.sh
tests/run_all.sh --full
rg -n "<machine>\.lock|generate_lockfile|Lockfile|lockfile" lib tests CONTEXT.md docs/adr tools/coverage_matrix.md -g '!workspace/**'
```

Expected:

- `tools/ob_check.sh` 全绿。
- `tests/run_all.sh --full` 通过，或明确记录环境缺失导致未跑的原因。
- 残留扫描只包含允许的 source lock、QEMU update lock、legacy cleanup/hard-cut 测试和禁用词说明。
- `git diff -- tests/.shellcheck-baseline` 无新增告警被误吞。

## 审阅 Checkpoint

实施计划已写好后，先审阅本计划。审阅通过前，不进入实现。
