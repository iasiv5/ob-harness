# machine_state lifecycle interface 深化实施计划

## 目标

- 将 `machine_state_records` 从 public interface 中移除，避免 `commands.sh`、`repo.sh` 和测试继续解析 machine-state record 字段。
- 复用当前已经落地的 `machine_state` 小查询/list interface，并只补齐迁移剩余调用点真正缺的查询函数。
- 保持 `machine_state.sh` 作为 leaf-pure module：不输出 UI 文案，不决定 `remedy line`，不处理 `exit-code 契约`，不做命令编排。
- 在 `tools/ob_check.sh` 中加入严格静态门禁，证明生产代码不再调用 public records surface 或旧 parser helper。

## 架构快照

本次深化采用 strangler 迁移顺序：先让旧 public surface 的生产代码调用变成红灯，再补齐新 interface，然后逐个迁移 `repo.sh`、`cmd_build` metadata loop 和 `cmd_status` 全链路，最后删除 public `machine_state_records` surface。

当前代码已经存在并被生产代码使用的 interface 不重建：`machine_state_is_initialized`、`machine_state_firmware_image_path`、`machine_state_repo_count`、`machine_state_initialized_machines`、`machine_state_firmware_image_ready_machines`。`cmd_start_qemu` 已经主要通过 `machine_state_firmware_image_ready_machines`、`machine_state_initialized_machines` 和 `machine_state_is_initialized` 判断前置；`cmd_build` 的 machine 发现已经使用 `machine_state_initialized_machines`。本计划的待迁移生产调用点收敛为三处：`lib/repo.sh` 的 `print_previously_initialized`、`lib/commands.sh` 的 `cmd_build` metadata loop、`lib/commands.sh` 的 status helpers 与 tips 计算。

第一阶段不引入大而全的 facts collector。只有当 `cmd_status` 迁移后出现明显重复调用时，才考虑引入 nameref collector；即便引入，也不得输出需要调用者二次解析的 record / `key=value` 行。

## 输入工件

- `CONTEXT.md`：`machine lifecycle state` glossary。
- `docs/adr/0006-machine-state-firmware-image-readiness.md`：接受“明确状态查询 + facts interface”，拒绝 public `machine_state_records`。
- 当前分支：`feature/machine-state-lifecycle-interface`。

## 文件结构与职责

- Modify: `lib/machine_state.sh`
  - 复用已存在的小查询/list interface。
  - 增加缺失的小查询/list interface。
  - 删除或私有化 record-like 实现细节。
  - 保持 no-exit leaf-pure 约束。
- Modify: `lib/repo.sh`
  - `print_previously_initialized` 不再调用 `machine_state_records` 或解析 record 字段。
- Modify: `lib/commands.sh`
  - `cmd_build` metadata loop 不再读取 `machine_state_records`。
  - `cmd_status`、`status_section_machines`、`status_section_diagnostics`、`status_section_tips` 不再解析 machine-state record 字段。
- Modify: `tools/ob_check.sh`
  - 增加生产代码禁止调用 public records surface 和旧 parser helper 的静态门禁。
- Modify: `tests/unit/machine_state.sh`
  - 从 record 字段断言迁移到明确状态 interface 断言。
- Modify: `tests/unit/repo_previously_initialized.sh`
  - 调整现有 mock，证明 `print_previously_initialized` 使用 initialized list 与 init-time 查询，不调用 `machine_state_records`。
- Modify: `tests/protocol/status_machine_state.sh`
  - 保留 status 行为断言，并证明 `cmd_status` 不调用 public record surface。
- Modify: `tools/coverage_matrix.md`
  - 补充或更新 machine lifecycle state interface 与静态门禁的覆盖说明。

## 新 interface 语义

已存在 interface，必须复用，不重建：

- `machine_state_is_initialized <machine>`：`init-done marker` 存在时 return 0，否则 return 1。
- `machine_state_firmware_image_path <machine>`：存在 firmware image artifact 时输出排序后的第一个 `.static.mtd` 路径，否则 return 1。
- `machine_state_repo_count <machine>`：snapshot 存在且 JSON 可读时输出 `sub_repos` 数量，否则输出 `?`。
- `machine_state_initialized_machines`：列出有 `init-done marker` 的 machine。
- `machine_state_firmware_image_ready_machines`：列出 initialized 且存在 firmware image artifact 的 machine。

本次新增 interface，必须满足以下语义：

- `machine_state_init_state <machine>`：有 init-done 输出 `initialized`；无 init-done 但有 snapshot 输出 `partial`；两者都没有输出 `uninitialized`。
- `machine_state_snapshot_state <machine>`：有 snapshot 输出 `present`，否则输出 `missing`。
- `machine_state_init_time <machine>`：有 init-done 时输出 marker 中的原始时间；无 marker 或读取失败时输出空字符串并 return 0。
- `machine_state_firmware_image_mtime <machine>`：有 firmware image artifact 时输出 UTC ISO mtime；没有 artifact 或 stat 失败时输出空字符串并 return 0。
- `machine_state_is_firmware_image_ready <machine>`：initialized 且存在 firmware image artifact 时 return 0，否则 return 1。
- `machine_state_is_orphan_firmware_image <machine>`：存在 firmware image artifact 且不是 initialized 时 return 0；覆盖 artifact-only 和 partial+image 两种场景。
- `machine_state_display_machines`：列出有 snapshot 或 init-done 的 machine；排除纯 artifact-only orphan，但包含 snapshot-only、marker-only、partial+image 和 ready。
- `machine_state_orphan_firmware_image_machines`：列出存在 firmware image artifact 且不是 initialized 的 machine；覆盖 artifact-only 和 partial+image。

`discovered_by` 不作为新 public interface 暴露；旧断言迁移为 list 成员关系断言。例如 partial+image 应同时在 `machine_state_display_machines` 与 `machine_state_orphan_firmware_image_machines` 中，不在 `machine_state_firmware_image_ready_machines` 中。

## 任务清单

### Task 1: `tools/ob_check.sh` 增加 public records surface 门禁

目标：让旧 public surface 和 parser helper 的生产代码调用变成自动失败，而不是靠人工 review 发现。

Files:
- Modify: `tools/ob_check.sh`

验证范围：当前代码应被新门禁识别为失败；完成迁移后门禁转绿。

- [ ] Step 1: 写当前状态检查
- Run: `grep -RInE '(^|[^[:alnum:]_])(machine_state_records|_commands_machine_record_field|_commands_record_has_discovery_source|_commands_collect_machine_state_records|_repo_machine_record_field)($|[^[:alnum:]_])' lib/*.sh | grep -v '^lib/machine_state.sh:' || true`
- Expected: 输出包含 `lib/commands.sh` 和 `lib/repo.sh` 的命中，证明旧 surface 和 parser helper 仍在生产代码中使用。
- [ ] Step 2: 在 `tools/ob_check.sh` 中加入门禁
- Change: 在 `extract_funcs` 检查之后、shellcheck baseline 之前增加检查，扫描 `lib/*.sh` 中除 `lib/machine_state.sh` 外的 `machine_state_records`、`_commands_machine_record_field`、`_commands_record_has_discovery_source`、`_commands_collect_machine_state_records`、`_repo_machine_record_field`。门禁实现必须复用 Step 1 的 POSIX 边界正则 `(^|[^[:alnum:]_])(symbols)($|[^[:alnum:]_])`，不使用裸符号交替；有命中时调用 `bad "machine-state public records surface still in use"` 并打印命中行；无命中时调用 `ok "machine-state public records surface removed"`。
- [ ] Step 3: 运行并确认当前失败
- Run: `OB_CHECK_SKIP_TESTS=1 OB_CHECK_READONLY=1 tools/ob_check.sh`
- Expected: 输出包含 `machine-state public records surface still in use` 的失败项，且命中位置指向 `lib/commands.sh` / `lib/repo.sh`。

### Task 2: `machine_state.sh` 增加缺失小查询/list interface

目标：只补齐当前迁移需要且尚不存在的 lifecycle state 查询函数，不重建已经存在并被调用的函数。

Files:
- Modify: `lib/machine_state.sh`
- Modify: `tests/unit/machine_state.sh`

验证范围：新增 interface 能覆盖 initialized、partial、uninitialized、firmware-image-ready、orphan artifact、mtime、init time、display machines。

- [ ] Step 1: 在 `tests/unit/machine_state.sh` 写失败断言
- Change: 保留已存在函数的 `defined` 断言；新增对 `machine_state_display_machines`、`machine_state_orphan_firmware_image_machines`、`machine_state_init_state`、`machine_state_snapshot_state`、`machine_state_init_time`、`machine_state_firmware_image_mtime`、`machine_state_is_firmware_image_ready`、`machine_state_is_orphan_firmware_image` 的存在性和行为断言。
- Run: `bash tests/unit/machine_state.sh`
- Expected: 因新增函数尚不存在或行为未实现而失败，失败点指向新增 interface；不得因为重定义已存在函数导致 start-qemu/build 相关断言变化。
- [ ] Step 2: 在 `lib/machine_state.sh` 写最小实现
- Change: 使用现有 `machine_state_snapshot_path`、`machine_state_init_done_path`、`machine_state_repo_count`、`machine_state_firmware_image_path`、`_machine_state_discover_machines` 和 `_machine_state_file_mtime_iso` 实现新增小查询/list。函数只返回状态值、路径、时间或 return code，不输出 UI 文案，不 exit。
- [ ] Step 3: 运行并确认通过
- Run: `bash tests/unit/machine_state.sh`
- Expected: 新旧 lifecycle state 场景全部通过，包括 orphan artifact 不进入 firmware-image-ready list。
- [ ] Step 4: leaf-pure 静态检查
- Run: `python3 tools/exit_contract.py lib/machine_state.sh`
- Expected: `machine_state.sh` 无 exit 纪律违反。

### Task 3: `tests/unit/machine_state.sh` 重写状态组合断言

目标：把 record 字段级断言迁移为新 interface 行为断言，明确覆盖旧 `discovered_by` 语义。

Files:
- Modify: `tests/unit/machine_state.sh`

验证范围：snapshot-only、marker-only、bad-json、initialized-missing-image、ready、artifact-only orphan、partial+image、mismatched deploy、empty build dir 均通过新 interface 验证。

- [ ] Step 1: 写场景映射表到测试结构中
- Change: 将旧 helper `record_for`、`record_field`、`assert_record_field`、`assert_no_record` 的使用点逐组映射到新断言：`machine_state_init_state`、`machine_state_snapshot_state`、`machine_state_repo_count`、`machine_state_init_time`、`machine_state_firmware_image_path`、`machine_state_firmware_image_mtime`、`machine_state_is_firmware_image_ready`、`machine_state_is_orphan_firmware_image`、`machine_state_display_machines`、`machine_state_orphan_firmware_image_machines`、`machine_state_initialized_machines`、`machine_state_firmware_image_ready_machines`。
- Run: `bash tests/unit/machine_state.sh`
- Expected: 在删除旧 helper 前，测试仍能运行；新增断言覆盖全部旧状态组合。
- [ ] Step 2: 删除 record 字段 helper 依赖
- Change: 删除或停止使用 `record_for`、`record_field`、`assert_record_field`、`assert_no_record`；`discovered_by` 断言改为成员关系断言：snapshot-only 在 display list；marker-only 在 display list 和 initialized list；ready 在 display list、initialized list、firmware-ready list；artifact-only orphan 在 orphan list、不在 display list；partial+image 在 display list 和 orphan list、不在 firmware-ready list。
- [ ] Step 3: 运行并确认通过
- Run: `bash tests/unit/machine_state.sh`
- Expected: 测试通过，且不再依赖 public record 字段解析 helper。

### Task 4: `repo.sh` 迁移 `print_previously_initialized`

目标：`print_previously_initialized` 通过 initialized list 和 init-time 查询展示已初始化 machine，不再读 record 字段。

Files:
- Modify: `lib/repo.sh`
- Modify: `tests/unit/repo_previously_initialized.sh`

验证范围：repo machine selection UI 保留原有输出，并证明不调用 `machine_state_records`。

- [ ] Step 1: 调整现有 mock 与断言
- Change: `tests/unit/repo_previously_initialized.sh` 已有 `machine_state_initialized_machines` 和 `machine_state_records` mock；新增 `machine_state_init_time` mock。将 `machine_state_records` mock 保留为计数哨兵，断言反转为 `machine_state_initialized_machines` 调用一次、`machine_state_records` 调用零次；保留输出仍包含 `romulus`、原始 index 和格式化时间的断言。
- Run: `bash tests/unit/repo_previously_initialized.sh`
- Expected: 当前实现失败，失败原因是仍调用 `machine_state_records` 或 `_repo_machine_record_field`。
- [ ] Step 2: 修改 `lib/repo.sh`
- Change: 删除 `_repo_machine_record_field`；`print_previously_initialized` 先读取 `machine_state_initialized_machines`，再对每个 initialized machine 调 `machine_state_init_time`，并按原 machine 列表保留原 index。
- [ ] Step 3: 运行并确认通过
- Run: `bash tests/unit/repo_previously_initialized.sh`
- Expected: 测试通过，`partial` 不显示，legacy lock 不显示，`machine_state_records` 未被调用。

### Task 5: `commands.sh` 迁移 `cmd_build` metadata loop

目标：`cmd_build` 的交互 machine 列表不再通过 record parser 读取 init time 和 repo count。

Files:
- Modify: `lib/commands.sh`
- Relevant tests: `tests/protocol/build_noninteractive.sh`, `tests/protocol/smoke_ob.sh`

验证范围：build 前置行为不退化，`cmd_build` 不再依赖 `_commands_machine_record_field`。

- [ ] Step 1: 写当前状态检查
- Run: `grep -n '_commands_machine_record_field\|machine_state_records' lib/commands.sh`
- Expected: 输出包含 `cmd_build` metadata loop 附近的旧 parser 调用，同时也会包含 status 旧调用。
- [ ] Step 2: 修改 `cmd_build`
- Change: 删除 `cmd_build` 中读取 `machine_state_records` 的 metadata loop；machine 列表继续来自已经存在的 `machine_state_initialized_machines`，init time 使用 `machine_state_init_time "$mname"`，repo count 使用 `machine_state_repo_count "$mname"`。
- [ ] Step 3: 运行 build protocol 检查
- Run: `bash tests/protocol/smoke_ob.sh && bash tests/protocol/build_noninteractive.sh`
- Expected: 两个测试均通过，空 workspace 仍按 exit 3 报前置缺失，非交互 build 行为不退化。
- [ ] Step 4: 确认 `cmd_build` 旧调用已消失
- Run: `grep -n '_commands_machine_record_field\|machine_state_records' lib/commands.sh || true`
- Expected: 仍可有 status 相关旧调用，但不再有 `cmd_build` metadata loop 相关旧调用。

### Task 6: `commands.sh` 迁移 status 路径

目标：`cmd_status`、`status_section_machines`、`status_section_diagnostics`、`status_section_tips` 使用小查询/list，不再收集或解析 machine-state records。

Files:
- Modify: `lib/commands.sh`
- Modify: `tests/protocol/status_machine_state.sh`

验证范围：status 输出行为保持不变，orphan artifact 仍只出现在 Diagnostics，build tip 仍按 initialized-without-image 触发。

- [ ] Step 1: 调整 status 测试的调用哨兵
- Change: `tests/protocol/status_machine_state.sh` 保留真实 fixture。`machine_state_records` mock 只作为计数哨兵，不负责提供数据；断言迁移后调用次数为 0。数据来源应改由真实的新小查询/list 读取 fixture。保留现有 status 输出断言。
- Run: `bash tests/protocol/status_machine_state.sh`
- Expected: 当前实现失败，失败原因是 `cmd_status` 仍调用 public record surface。
- [ ] Step 2: 修改 status helpers
- Change: 删除 `_commands_machine_record_field`、`_commands_record_has_discovery_source`、`_commands_collect_machine_state_records`；`status_section_machines` 改为无参函数，通过 `machine_state_display_machines` 遍历 display machines，并用 `machine_state_init_state`、`machine_state_snapshot_state`、`machine_state_repo_count`、`machine_state_is_firmware_image_ready`、`machine_state_firmware_image_path`、`machine_state_firmware_image_mtime` 填表；`status_section_diagnostics` 也改为无参函数，通过 `machine_state_orphan_firmware_image_machines` 获取 orphan list；`cmd_status` 删除 `machine_records` 数组和传参调用，直接调用 `status_section_machines`、`status_section_diagnostics`，tips 通过 `machine_state_initialized_machines` 和 `machine_state_is_firmware_image_ready` 计算。
- [ ] Step 3: 运行并确认通过
- Run: `bash tests/protocol/status_machine_state.sh`
- Expected: 测试通过；输出仍包含 `Diagnostics`、`Orphan firmware image artifacts`、`Next step : ob init orphan`，且 artifact-only orphan 不在主 Machines 表。
- [ ] Step 4: 运行 start-qemu remedy 回归
- Run: `bash tests/protocol/start_qemu_remedy.sh`
- Expected: start-qemu 的 init/build remedy 行为保持通过。

### Task 7: 删除 public `machine_state_records` surface

目标：让旧 public record surface 在生产代码中不可用，避免后续回退。

Files:
- Modify: `lib/machine_state.sh`
- Modify: `tests/unit/machine_state.sh`

验证范围：`machine_state_records` 不再是 public 函数，旧 parser 测试已被新 interface 测试替代。

- [ ] Step 1: 修改 unit 测试的旧函数断言
- Change: 将 `tests/unit/machine_state.sh` 中 `machine_state_records defined` 改为 `machine_state_records removed`；确认 Task 3 已经移除 public record 字段 helper 依赖。
- Run: `bash tests/unit/machine_state.sh`
- Expected: 当前实现因 `machine_state_records` 仍存在而失败。
- [ ] Step 2: 删除或私有化 record 实现
- Change: 从 `lib/machine_state.sh` 删除 public `machine_state_records` 和 `_machine_state_print_record`；如确需内部复用，只保留 `_machine_state_*` 私有 helper，且不输出 public record / `key=value` 行。
- [ ] Step 3: 运行 unit 测试
- Run: `bash tests/unit/machine_state.sh`
- Expected: 测试通过，所有状态组合通过新 interface 验证。

### Task 8: 更新 coverage checklist

目标：让覆盖清单反映新的 public interface 和架构门禁，避免未来 agent 误读测试现状。

Files:
- Modify: `tools/coverage_matrix.md`

验证范围：coverage checklist 包含 machine lifecycle state interface 与 ob_check 静态门禁。

- [ ] Step 1: 检查当前 coverage 条目缺口
- Run: `grep -n 'machine_state_records\|machine lifecycle\|ob_check' tools/coverage_matrix.md || true`
- Expected: 当前 coverage matrix 未完整描述新 interface 和 public records surface 门禁。
- [ ] Step 2: 更新 coverage matrix
- Change: 在 `status` 或横切区域添加 machine lifecycle state interface 条目，列出已存在和新增的 machine_state 小查询/list 函数由 `tests/unit/machine_state.sh` 和 `tests/protocol/status_machine_state.sh` 覆盖；添加 `tools/ob_check.sh` public records surface gate 条目。
- [ ] Step 3: 验证文档更新
- Run: `grep -n 'machine lifecycle state\|public records surface\|machine_state_display_machines' tools/coverage_matrix.md`
- Expected: 输出包含新增或更新的 coverage 条目。

### Task 9: 最终架构门禁与全量快速验证

目标：证明行为测试和架构门禁都已经收口。

Files:
- Validate: `lib/*.sh`, `tools/ob_check.sh`, `tests/**`, `tools/coverage_matrix.md`

验证范围：旧 public records surface 不再出现在生产代码，ob/lib 自检全绿。

- [ ] Step 1: 静态确认生产代码没有旧 surface
- Run: `grep -RInE '(^|[^[:alnum:]_])(machine_state_records|_commands_machine_record_field|_commands_record_has_discovery_source|_commands_collect_machine_state_records|_repo_machine_record_field)($|[^[:alnum:]_])' lib/*.sh | grep -v '^lib/machine_state.sh:' || true`
- Expected: 无输出。
- [ ] Step 2: 运行一站式自检
- Run: `tools/ob_check.sh`
- Expected: 输出 `ALL GREEN`；新增 `machine-state public records surface removed` 门禁为 pass。
- [ ] Step 3: 如 shellcheck baseline 被自动重生成，检查 diff
- Run: `git --no-pager diff -- tests/.shellcheck-baseline tools/ob_check.sh lib/machine_state.sh lib/commands.sh lib/repo.sh tests/unit/machine_state.sh tests/unit/repo_previously_initialized.sh tests/protocol/status_machine_state.sh tools/coverage_matrix.md`
- Expected: diff 只包含本计划相关变更；无无关格式化或行为扩张。

## 执行纪律

- 开始实现前先批判性复查本计划；若发现 ADR-0006、`CONTEXT.md`、代码现状或验证命令不一致，先修计划再实现。
- 当前工作应在 `feature/machine-state-lifecycle-interface` 分支执行；如果执行者发现自己在 `main` 或 `master`，必须先停下。
- 实现前确认 `CONTEXT.md` 与 `docs/adr/0006-machine-state-firmware-image-readiness.md` 已稳定，且没有与本计划冲突的新改动。
- 按 Task 顺序执行，不要无声跳步、合并任务或扩大目标。
- 每完成一个 Task，都运行该 Task 定义的验证命令。
- `machine_state.sh` 不得新增 `exit`；如必须改变 exit 行为，先停下重新审查 ADR 和计划。
- 遇到重复失败、测试无法表达目标、或计划与仓库现实不符，立即停下说明，不要猜。
- 不提交、不推送，除非用户另行明确要求。

## 最终验证

- Run: `tools/ob_check.sh`
- Expected: `ALL GREEN`，并包含 public records surface 静态门禁通过。
- Run: `bash tests/protocol/start_qemu_remedy.sh && bash tests/protocol/status_machine_state.sh && bash tests/unit/machine_state.sh && bash tests/unit/repo_previously_initialized.sh`
- Expected: 全部测试通过，关键 lifecycle state 行为保持不变。
- Run: `grep -RInE '(^|[^[:alnum:]_])(machine_state_records|_commands_machine_record_field|_commands_record_has_discovery_source|_commands_collect_machine_state_records|_repo_machine_record_field)($|[^[:alnum:]_])' lib/*.sh | grep -v '^lib/machine_state.sh:' || true`
- Expected: 无输出。

## Inline 自检结果

- 设计覆盖：覆盖了 ADR-0006、`CONTEXT.md`、用户确认的“删除 public record surface”“严格门禁”“先小查询函数迁移”三项要求，并吸收了评审指出的现状漂移。
- 文件范围：只覆盖 `machine_state` lifecycle interface、调用方迁移、测试和门禁；不改 QEMU launch profile、source manifest 或其他子系统。
- 占位符扫描：计划中没有未决占位标记或未展开的验证项。
- 可执行性：每个 Task 都有具体路径、命令和预期结果；最终验证使用 Linux bash 和仓库现有命令。

## 审阅 Checkpoint

实施计划写入后先审阅。审阅通过前，不进入实现；后续可由普通编码 agent 或人工执行者按本计划执行，也可以继续交给评审 agent 做计划审查。
