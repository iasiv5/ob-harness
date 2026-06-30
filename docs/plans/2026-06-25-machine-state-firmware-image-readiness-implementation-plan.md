# machine_state firmware image readiness 实施计划

## 目标

- 按 ADR-0006 将 `machine_state` 深化为 machine lifecycle state 的拥有者，分离 init completion 与 firmware image readiness。
- 删除旧公共 interface `machine_state_list_records`、`machine_state_record_field`，并迁移生产代码、测试脚本和测试 mock。
- 将旧 `build=succeeded` / `image=yes` / `init=done` 字段迁移到 `init_state`、`snapshot_state`、`firmware_image_ready`、`firmware_image_orphaned`、`firmware_image_path`、`firmware_image_mtime`、`discovered_by`。
- `ob status` 主 Machines 表保持日常可读，`orphan firmware image artifact` 只进入 Diagnostics 小节。

## 架构快照

`lib/machine_state.sh` 是本次唯一的 lifecycle 决策 module。它提供两类 surface：

- 展示/诊断 surface：`machine_state_records`
- 决策 surface：`machine_state_initialized_machines`、`machine_state_firmware_image_ready_machines`、`machine_state_is_initialized`、`machine_state_firmware_image_path`

`commands.sh` 和 `repo.sh` 不再通过公共 `machine_state_record_field` 自行判断 `init=done`、`build=succeeded` 或 `image=yes`。决策型 caller 使用 filtered machine-name lists / predicate / path interface；展示型 caller 可以使用文件内私有 record parser 读取 `machine_state_records` 的展示字段。

Firmware image discovery 只接受标准同名路径：`$OPENBMC_DIR/build/<machine>/tmp/deploy/images/<machine>/*.static.mtd`。`firmware_image_ready=yes` 必须满足 `init_state=initialized` 且存在 firmware image artifact。artifact-only 或 partial-init artifact 只设置 `firmware_image_orphaned=yes`，不进入 `machine_state_firmware_image_ready_machines`。

`machine` 与 `init_time` 是保留展示字段；`repos` 改名为 `repo_count`。这些字段服务 status/build selection 的展示，不属于 ADR-0006 的 readiness 决策字段。

`discovered_by` 是逗号分隔的多值集合，取值只允许 `snapshot`、`init_done`、`firmware_image`，并按这个固定顺序输出已命中的来源子集。

## 输入工件

- `docs/adr/0001-init-done-marker.md`
- `docs/adr/0006-machine-state-firmware-image-readiness.md`
- `CONTEXT.md` 中的 `firmware-image-ready machine` 与 `orphan firmware image artifact`

## 文件结构与职责

- Modify: `lib/machine_state.sh`
  - 新增 `machine_state_records`、`machine_state_initialized_machines`、`machine_state_firmware_image_ready_machines`、`machine_state_is_initialized`、`machine_state_firmware_image_path`。
  - 删除 `machine_state_list_records`、`machine_state_record_field`、`machine_state_build_state`、`machine_state_image_path`、`machine_state_has_init_done` 的外部调用面。
  - 增加 firmware image artifact discovery 与 orphan 诊断字段。
  - 保持 lib 三段纯函数结构：不在函数定义外增加顶层执行语句，确保 `tools/extract_funcs.py` / `tools/ob_check.sh` 继续通过。
- Modify: `lib/commands.sh`
  - `cmd_status` 使用 records 展示主表与 Diagnostics，并更新 tips 信号计算。
  - `cmd_build` 迁移 explicit prerequisite、interactive initialized list、以及 bitbake 成功后的 firmware image path 展示。
  - `cmd_start_qemu` 迁移 interactive firmware-image-ready list、explicit prerequisite、以及 firmware image path 检查。
  - 展示解析只用 `commands.sh` 私有 helper。
- Modify: `lib/repo.sh`
  - `print_previously_initialized` 使用 `machine_state_initialized_machines` 做筛选。
  - 展示 `init_time` 时只使用 `repo.sh` 私有 helper 解析 records。
- Modify: `tests/unit/machine_state.sh`
  - 覆盖新 record 字段、filtered lists、orphan artifact、标准路径 discovery、非同名路径忽略、missing build dir、旧函数删除。
- Modify: `tests/unit/repo_previously_initialized.sh`
  - mock 新 machine_state interface，移除旧 records mock。
- Modify: `tests/protocol/status_machine_state.sh`
  - 覆盖主表、Diagnostics、firmware image tips、新文案。
- Modify: `tests/protocol/build_noninteractive.sh`
  - 覆盖 `cmd_build` 对 initialized machines 的选择、success display path、exit 3 remedy。
- Modify: `tests/protocol/start_qemu_remedy.sh`
  - 覆盖 `cmd_start_qemu` 对 firmware-image-ready machines 的选择、orphan 排除、exit 3 remedy。
- Inspect: `tests/orchestration/`、`tests/protocol/manual_matrix.exp`
  - 如旧字段或旧函数名仍被引用，同步迁移；没有引用则保持不动。
- Not in scope: `lib/init_pipeline.sh` 的 `machine_state_snapshot_path` / `machine_state_write_snapshot` 调用保持不变；它们是 snapshot 写入路径，不参与 firmware image readiness interface 迁移。

## 调用点映射

| 文件/函数 | 当前职责 | 本次落点 |
|---|---|---|
| `lib/commands.sh` `status_section_machines` | 主 Machines 表与 per-machine 展开 | Task 6 |
| `lib/commands.sh` `cmd_status` | tips 信号计算与 QEMU instances 后续展示 | Task 6 |
| `lib/commands.sh` `cmd_build` explicit prerequisite | `ob build <machine>` init 前置 | Task 4 |
| `lib/commands.sh` `cmd_build` interactive selection | 无参数 build 的 initialized machine 列表与展示 | Task 4 |
| `lib/commands.sh` `cmd_build` success display | bitbake 成功后的 firmware image path / size 展示 | Task 4 |
| `lib/commands.sh` `cmd_start_qemu` interactive selection | 无参数 start-qemu 的 firmware-image-ready machine 列表 | Task 5 |
| `lib/commands.sh` `cmd_start_qemu` explicit prerequisite | init 前置与 firmware image path 检查 | Task 5 |
| `lib/repo.sh` `print_previously_initialized` | init task machine list 里的 previously initialized 展示 | Task 3 |

## 任务清单

### Task 1: 更新 `tests/unit/machine_state.sh` 合同测试

- 目标：先用单测锁定 ADR-0006 的新 `machine_state` interface 和 record 字段。
- Files
  - Modify: `tests/unit/machine_state.sh`
- 验证范围：`bash tests/unit/machine_state.sh`

#### Step 1: 写失败测试

- Change:
  - 将 `record_for` 改为读取 `machine_state_records`。
  - 断言新函数存在：`machine_state_records`、`machine_state_initialized_machines`、`machine_state_firmware_image_ready_machines`、`machine_state_is_initialized`、`machine_state_firmware_image_path`。
  - 断言旧函数不存在：用数组保存旧函数名并循环 `declare -F "$old_func"`，避免在测试中定义或 mock 旧函数。
  - 将字段断言迁移为：`init_state=partial|initialized|uninitialized`、`snapshot_state=present|missing`、`repo_count=<n|?>`、`firmware_image_ready=yes|no`、`firmware_image_orphaned=yes|no`、`firmware_image_path=`、`firmware_image_mtime=`、`discovered_by=`。
  - 增加 artifact-only fixture：只创建 `$OPENBMC_DIR/build/orphan/tmp/deploy/images/orphan/orphan.static.mtd`，预期 record 存在、`firmware_image_ready=no`、`firmware_image_orphaned=yes`、`discovered_by=firmware_image`。
  - 增加 partial+artifact fixture：snapshot + firmware artifact，无 init-done，预期 `init_state=partial`、`firmware_image_orphaned=yes`。
  - 增加 mismatched artifact fixture：`build/romulus/tmp/deploy/images/other/*.static.mtd`，预期不被 discovery 加入 records。
  - 增加 missing-build-dir fixture：`$OPENBMC_DIR/build` 不存在或为空时，firmware image discovery 返回空且不报错。
  - 断言 `machine_state_initialized_machines` 只输出 init-done machine。
  - 断言 `machine_state_firmware_image_ready_machines` 只输出 init-done + firmware artifact 的 machine。
- Run: `bash tests/unit/machine_state.sh`
- Expected: 失败，错误指向新函数未定义、旧函数仍存在或旧字段/旧函数仍存在。

#### Step 2: 确认失败信号稳定

- Run: `bash tests/unit/machine_state.sh`
- Expected: 非零退出；输出至少包含一个新 interface 未定义、旧函数删除断言失败或旧字段不匹配的断言失败；没有 shell 语法错误。

### Task 2: 实现 `lib/machine_state.sh` 新 interface

- 目标：让 machine_state 单测通过，并删除旧 public field parser interface。
- Files
  - Modify: `lib/machine_state.sh`
  - Test: `tests/unit/machine_state.sh`
- 验证范围：`bash tests/unit/machine_state.sh`，以及旧函数名局部 grep。

#### Step 1: 确认 Task 1 测试仍失败

- Run: `bash tests/unit/machine_state.sh`
- Expected: 非零退出，失败原因来自新 interface 尚未实现或旧 public functions 尚未删除。

#### Step 2: 写最小实现

- Change:
  - Rename/replace `machine_state_has_init_done` 为 `machine_state_is_initialized`。
  - Rename/replace `machine_state_image_path` 为 `machine_state_firmware_image_path`。
  - Remove `machine_state_build_state`。
  - Remove `machine_state_list_records` 和 `machine_state_record_field`。
  - Add machine discovery from three sources: `*.snapshot`、`*.init-done`、standard firmware image artifact path。
  - Enumerate firmware image artifacts with a narrow glob over `$OPENBMC_DIR/build/*/tmp/deploy/images/*/*.static.mtd`, then accept only paths where the `build/<machine>` segment equals the `images/<machine>` segment。
  - If `$OPENBMC_DIR` is empty, unset, missing, or has no `build` directory, firmware image discovery returns no machines and does not print errors。
  - Add `machine_state_records` output fields: `machine`、`discovered_by`、`init_state`、`snapshot_state`、`repo_count`、`firmware_image_ready`、`firmware_image_orphaned`、`firmware_image_path`、`firmware_image_mtime`、`init_time`。
  - Add `machine_state_initialized_machines` and `machine_state_firmware_image_ready_machines` as name-only filtered lists。
  - Keep lower module no-exit discipline: return non-zero for missing firmware image path, do not `exit` inside `lib/machine_state.sh`。
  - Keep lib three-section structure clean: no top-level executable statements outside function definitions, so `tools/extract_funcs.py` and `tools/ob_check.sh` continue to pass。

#### Step 3: 验证 machine_state 单测通过

- Run: `bash tests/unit/machine_state.sh`
- Expected: `ALL ... PASS` 或测试框架等价通过摘要；无失败断言。

#### Step 4: 验证旧 machine_state 调用/定义已从本文件和单测移除

- Run: `rg 'machine_state_list_records\s*\(|machine_state_record_field\s*\(|machine_state_build_state\s*\(|machine_state_image_path\s*\(|machine_state_has_init_done\s*\(' lib/machine_state.sh tests/unit/machine_state.sh`
- Expected: 无匹配，`rg` 退出码为 1。

### Task 3: 迁移 `lib/repo.sh` previously initialized 展示

- 目标：`print_previously_initialized` 使用 `machine_state_initialized_machines` 做筛选，只把 record parser 用于展示 `init_time`。
- Files
  - Modify: `lib/repo.sh` (`print_previously_initialized`)
  - Modify: `tests/unit/repo_previously_initialized.sh`
- 验证范围：`bash tests/unit/repo_previously_initialized.sh`

#### Step 1: 更新单测 mock 为新 interface

- Change:
  - 删除测试里的 `machine_state_list_records` mock。
  - 新增 `machine_state_initialized_machines` mock，输出 `romulus`。
  - 新增 `machine_state_records` mock，输出 `romulus` 与 `partial` 的新字段 records。
  - 保留断言：只展示 `romulus`，不展示 `partial`，保留原始 machine list index。
- Run: `bash tests/unit/repo_previously_initialized.sh`
- Expected: 失败，原因是 `lib/repo.sh` 仍调用旧 `machine_state_list_records` / `machine_state_record_field`。

#### Step 2: 实现 repo.sh 迁移

- Change:
  - 在 `repo.sh` 内增加私有 helper，例如 `_repo_machine_record_field`，只供展示使用。
  - `print_previously_initialized` 遍历 `machine_state_initialized_machines`，不再解析 `init_state` 做筛选。
  - 通过 `machine_state_records` 查对应 machine 的 `init_time`。

#### Step 3: 验证 repo 单测通过

- Run: `bash tests/unit/repo_previously_initialized.sh`
- Expected: 测试通过，且 `partial` 不出现在输出中。

#### Step 4: 验证 repo.sh 不再引用旧 public interface

- Run: `rg 'machine_state_list_records\s*\(|machine_state_record_field\s*\(|init=done|build=succeeded|image=yes' lib/repo.sh tests/unit/repo_previously_initialized.sh`
- Expected: 无匹配，`rg` 退出码为 1。

### Task 4: 迁移 `cmd_build` 到 initialized decision surface

- 目标：`cmd_build` 不再解析 records 判断 init-done；success display 也不再调用旧 image path interface。
- Files
  - Modify: `lib/commands.sh` (`cmd_build`)
  - Modify: `tests/protocol/build_noninteractive.sh`
- 验证范围：`bash tests/protocol/build_noninteractive.sh`

#### Step 1: 更新 build protocol 断言

- Change:
  - 保留 explicit `ob build <machine>` 无 init-done 时 exit 3 和 `Run 'ob init <machine>' first.` remedy。
  - 将 snapshot-only 用例明确为 `init_state=partial` 语义：仍 exit 3，仍提示 init。
  - 如果现有测试 harness 已有可低成本复用的 bitbake mock，可增加 success-path 动态断言，验证产物展示使用 `machine_state_firmware_image_path` 且不会误显示 `Image: <not found>`；如果需要从零搭 PATH 注入 fake bitbake 和 artifact fixture，则不阻塞本任务，硬门禁以 Step 4 的 `cmd_build` 区段静态扫描为准。
  - 如测试中构造 records，迁移为 init-done marker / snapshot / new interface 需要的真实文件状态，不 mock 旧 record 字段。
- Run: `bash tests/protocol/build_noninteractive.sh`
- Expected: 若加入 success-path 动态断言，则当前失败原因是成功展示仍调用旧 `machine_state_image_path` 或展示 `<not found>`；若未加入动态断言，本步骤可以通过，回归防护由 Step 4 的 `cmd_build` 区段静态扫描承担。

#### Step 2: 实现 cmd_build 迁移

- Change:
  - explicit machine path 使用 `machine_state_is_initialized "$MACHINE"`。
  - interactive path 使用 `machine_state_initialized_machines` 取得 machine name list。
  - 如果需要展示 init time / repo count，从 `machine_state_records` 读取展示字段，解析 helper 保持在 `commands.sh` 私有作用域。
  - bitbake 成功后的产物展示块必须把 `machine_state_image_path "$MACHINE"` 改为 `machine_state_firmware_image_path "$MACHINE"`，否则成功 build 会误显示 `Image: <not found>`。
  - 保持 exit-code 契约：无 initialized machine 返回 exit 3，并输出恰好一条向前看的 remedy line。

#### Step 3: 验证 build protocol 通过

- Run: `bash tests/protocol/build_noninteractive.sh`
- Expected: 测试通过；无 `build=succeeded`、`image=yes` 或 `init=done` 断言；成功路径展示真实 firmware image path。

#### Step 4: 验证 cmd_build 没有旧 interface 和旧字段

- Run: `awk '/^cmd_build\(\)/,/^cmd_start_qemu\(\)/ { print }' lib/commands.sh | rg 'machine_state_list_records\s*\(|machine_state_record_field\s*\(|machine_state_image_path\s*\(|machine_state_has_init_done\s*\(|init=done|build=succeeded|image=yes'`
- Expected: 无匹配，`rg` 退出码为 1。`cmd_build` 区段内 explicit 前置、interactive selection、success display 都不得再引用旧 interface 或旧字段。
- Run: `rg 'machine_state_list_records\s*\(|machine_state_record_field\s*\(|init=done|build=succeeded|image=yes' tests/protocol/build_noninteractive.sh`
- Expected: 无匹配，`rg` 退出码为 1。

### Task 5: 迁移 `cmd_start_qemu` 到 firmware-image-ready decision surface

- 目标：`cmd_start_qemu` 的交互列表只来自 `machine_state_firmware_image_ready_machines`，explicit path 先检查 initialized，再取 firmware image path。
- Files
  - Modify: `lib/commands.sh` (`cmd_start_qemu`)
  - Modify: `tests/protocol/start_qemu_remedy.sh`
- 验证范围：`bash tests/protocol/start_qemu_remedy.sh`

#### Step 1: 更新 start-qemu protocol 断言

- Change:
  - 无 init-done 时保持 exit 3 和 init remedy。
  - init-done 但无 firmware image artifact 时保持 exit 3 和 build remedy。
  - 增加 orphan firmware image artifact fixture：创建 standard `.static.mtd` artifact 但不创建 init-done，预期不能进入 start-qemu 选择列表，explicit machine 仍提示 init。
  - 断言 exit 3 输出中每个前置缺失路径只有一条 forward remedy line：缺 init 是 `Run 'ob init <machine>' first.`；缺 firmware image 是 `Run 'ob build <machine>' first.`，其中 explicit machine 路径应展开为具体 machine 名。
  - 文案使用 `firmware image`，不要写 `QEMU image`。
  - 明确迁移旧诊断 `No built machines found (initialized but not built).`，新文案使用 firmware-image-ready / firmware image 语义，例如 `No firmware-image-ready machines found.` 或 `Initialized machines have no firmware image.`。
- Run: `bash tests/protocol/start_qemu_remedy.sh`
- Expected: 当前失败，原因是 `cmd_start_qemu` 仍按旧 `build=succeeded` 或旧 image path 检查，或 remedy line 文案/数量不符合预期。

#### Step 2: 实现 start-qemu 迁移

- Change:
  - interactive path 使用 `machine_state_firmware_image_ready_machines`。
  - 判断是否存在 initialized machine 时使用 `machine_state_initialized_machines`，不解析 records。
  - explicit machine path 先用 `machine_state_is_initialized`，再用 `machine_state_firmware_image_path`。
  - 缺 artifact 的诊断行写 `No firmware image found for machine '<machine>'.` 或同等明确文案；remedy line 必须恰好一条且向前看。
  - explicit machine 缺 artifact 时实现可使用 `$MACHINE` 变量，但输出必须展开为具体 machine 名；测试断言用 `Run 'ob build <machine>' first.` 表示占位口径。无 machine 参数且存在 initialized machines 但没有 firmware-image-ready machines 时使用 `Run 'ob build <machine>' first.`。
  - 迁移 interactive no-ready 诊断：旧 `No built machines found (initialized but not built).` 不得保留，改为 firmware-image-ready / firmware image 语义。

#### Step 3: 验证 start-qemu protocol 通过

- Run: `bash tests/protocol/start_qemu_remedy.sh`
- Expected: 测试通过；orphan artifact 不被视为 firmware-image-ready machine；exit 3 remedy line 恰好一条且向前看。

#### Step 4: 验证 start-qemu 区段不再出现旧 ready 语义

- Run: `awk '/^cmd_start_qemu\(\)/,/^cmd_stop_qemu\(\)/ { print }' lib/commands.sh | rg 'Discover built machines|[Nn]o built machines|initialized but not built|build=succeeded|image=yes|machine_state_image_path\s*\(|machine_state_has_init_done\s*\('`
- Expected: 无匹配，`rg` 退出码为 1。该 awk 区段会包含 `_qemu_post_launch`；当前该 helper 无旧 machine_state 引用，如未来产生匹配，需要按实际落点判断是否属于本次迁移残留。

### Task 6: 迁移 `ob status` 主表、tips 和 Diagnostics

- 目标：`ob status` 使用新 records 展示主 Machines 表，并将 orphan firmware image artifact 放入 Diagnostics 小节。
- Files
  - Modify: `lib/commands.sh` (`status_section_machines`, `status_section_tips`, `cmd_status`, new diagnostics helper)
  - Modify: `tests/protocol/status_machine_state.sh`
- 验证范围：`bash tests/protocol/status_machine_state.sh`

#### Step 1: 更新 status protocol 断言

- Change:
  - 主表字段从 `Build` 迁移为 `Firmware Image` 或等价短标题。
  - snapshot-only 显示 partial / missing firmware image。
  - init-done + `.static.mtd` 显示 firmware image ready，并在展开信息里显示 firmware image path / mtime。
  - init-done + no artifact 触发 tip：`Run 'ob build <machine>' to produce a firmware image.`。
  - artifact-only machine 不进入主 Machines 表，进入 Diagnostics 小节，显示 path、reason、next step `ob init <machine>`。
  - partial+artifact machine 保留在主表 partial，同时 Diagnostics 解释 orphan artifact。
  - 不出现 `invalid image`、`broken image`、`QEMU image`。
- Run: `bash tests/protocol/status_machine_state.sh`
- Expected: 当前失败，原因是 status 仍输出旧 Build / succeeded / failed / never 语义或没有 Diagnostics。

#### Step 2: 实现 status 展示迁移

- Change:
  - 在 `commands.sh` 增加私有 helper，例如 `_status_record_field` 与 `_status_record_has_discovery_source`。
  - `status_section_machines` 读取 `machine_state_records`，主表只展示 `discovered_by` 含 `snapshot` 或 `init_done` 的 records。
  - Firmware image 列使用 `ready` / `missing`；orphan 不混入主表 ready 状态。
  - 新增 Diagnostics 小节，只在存在 `firmware_image_orphaned=yes` 时显示。
  - `cmd_status` 原 tips 信号计算区段必须从 `_ms_init` / `_ms_build` 改为新字段语义：存在 `init_state=initialized` 记为有 initialized machine；存在 `init_state=initialized && firmware_image_ready=no` 时提示 build firmware image。

#### Step 3: 验证 status protocol 通过

- Run: `bash tests/protocol/status_machine_state.sh`
- Expected: 测试通过；输出不包含旧 build 状态词 `succeeded` / `failed` / `never` 作为 machine firmware 状态。

#### Step 4: 验证 status 文案不误绑定 QEMU

- Run: `bash tests/protocol/status_machine_state.sh && ! bash tests/protocol/status_machine_state.sh 2>&1 | grep -F 'QEMU image'`
- Expected: 命令整体退出 0；status 输出不包含 `QEMU image`。

### Task 7: 清理旧 interface 引用并更新剩余测试

- 目标：生产代码、测试脚本、测试 mock 中不再依赖旧 public record parser 和旧字段名。
- Files
  - Modify: `lib/commands.sh`
  - Modify: `lib/repo.sh`
  - Modify: `tests/unit/*.sh`
  - Modify: `tests/protocol/*.sh`
  - Inspect: `tests/orchestration/*`, `tests/protocol/*.exp`
- 验证范围：全局 `rg` 清理检查。

#### Step 1: 运行旧调用扫描

- Run: `rg 'machine_state_list_records\s*\(|machine_state_record_field\s*\(|machine_state_image_path\s*\(|machine_state_build_state\s*\(|machine_state_has_init_done\s*\(' lib tests`
- Expected: 仍可能有少量匹配，且每个匹配都属于本次迁移需要清理的旧调用、旧定义或旧 mock。

#### Step 2: 运行旧字段扫描

- Run: `rg 'init=done|snapshot=yes|\brepos=|build=succeeded|image=yes|Run '\''ob build'\'' to build a machine|QEMU image|[Nn]o built machines|initialized but not built' lib tests`
- Expected: 仍可能有少量匹配，且每个匹配都属于本次迁移需要清理的旧字段、旧断言或误导文案。

#### Step 3: 清理剩余引用

- Change:
  - 替换旧函数名为新 interface。
  - 替换旧字段断言为 `init_state` / `firmware_image_*`。
  - 保留不属于 machine_state readiness 的 `QEMU` 文案，例如 `ob start-qemu` 自身命令描述；只清理把 firmware image 误称为 `QEMU image` 的文案。

#### Step 4: 验证旧引用清理完成

- Run: `rg 'machine_state_list_records\s*\(|machine_state_record_field\s*\(|machine_state_image_path\s*\(|machine_state_build_state\s*\(|machine_state_has_init_done\s*\(|init=done|snapshot=yes|\brepos=|build=succeeded|image=yes|Run '\''ob build'\'' to build a machine|QEMU image|[Nn]o built machines|initialized but not built' lib tests`
- Expected: 无匹配，`rg` 退出码为 1。

### Task 8: 分层回归与 `ob_check` 收口

- 目标：运行本次改动相关的窄测试、快速全量测试和 ob/lib 自检。
- Files
  - Test: `tests/run_all.sh`
  - Test: `tools/ob_check.sh`
- 验证范围：全部命令通过。

#### Step 1: 运行窄测试组合

- Run: `bash tests/unit/machine_state.sh && bash tests/unit/repo_previously_initialized.sh && bash tests/protocol/build_noninteractive.sh && bash tests/protocol/start_qemu_remedy.sh && bash tests/protocol/status_machine_state.sh`
- Expected: 全部通过，命令退出 0。

#### Step 2: 运行快速分层回归

- Run: `bash tests/run_all.sh`
- Expected: 输出 `ALL GREEN`，命令退出 0。

#### Step 3: 运行交互矩阵回归

- Run: `bash tests/run_all.sh --full`
- Expected: 输出 `ALL GREEN`；如果当前环境没有 `expect`，相关 `.exp` 用例显示 `skip ... (no expect)`，命令仍退出 0。

#### Step 4: 运行 ob/lib 一站式自检

- Run: `tools/ob_check.sh`
- Expected: 输出 `ALL GREEN`，命令退出 0。若 shellcheck baseline 因良性行号漂移自动更新，必须检查 `git diff -- tests/.shellcheck-baseline`，确认没有新增告警文本。

#### Step 5: 最终旧引用扫描

- Run: `rg 'machine_state_list_records\s*\(|machine_state_record_field\s*\(|machine_state_image_path\s*\(|machine_state_build_state\s*\(|machine_state_has_init_done\s*\(|init=done|snapshot=yes|\brepos=|build=succeeded|image=yes|Run '\''ob build'\'' to build a machine|QEMU image|[Nn]o built machines|initialized but not built' lib tests`
- Expected: 无匹配，`rg` 退出码为 1。

## 执行纪律

- 开始实现前先批判性复查整份计划；如果发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不要无声跳步、合并步或改变任务目标。
- 每完成一个任务，都运行该任务定义的验证。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下来说明，不要猜。
- 如果当前就在 `main` 或 `master`，且用户没有明确同意，开始实现前先确认。
- 全部任务完成后，运行最终验证并输出修改摘要。
- 不修改 `docs/adr/0001-init-done-marker.md` 的决策；本次实现只引用它。
- 不把 orphan firmware image artifact 自动删除或自动视为 ready。

## 最终验证

- Run: `bash tests/unit/machine_state.sh && bash tests/unit/repo_previously_initialized.sh && bash tests/protocol/build_noninteractive.sh && bash tests/protocol/start_qemu_remedy.sh && bash tests/protocol/status_machine_state.sh`
- Expected: 全部通过，命令退出 0。
- Run: `bash tests/run_all.sh`
- Expected: 输出 `ALL GREEN`，命令退出 0。
- Run: `bash tests/run_all.sh --full`
- Expected: 输出 `ALL GREEN`；无 `expect` 环境下 `.exp` 用例显示 skip 且命令退出 0。
- Run: `tools/ob_check.sh`
- Expected: 输出 `ALL GREEN`，命令退出 0。
- Run: `rg 'machine_state_list_records\s*\(|machine_state_record_field\s*\(|machine_state_image_path\s*\(|machine_state_build_state\s*\(|machine_state_has_init_done\s*\(|init=done|snapshot=yes|\brepos=|build=succeeded|image=yes|Run '\''ob build'\'' to build a machine|QEMU image|[Nn]o built machines|initialized but not built' lib tests`
- Expected: 无匹配，`rg` 退出码为 1。

## Inline 自检结论

- ADR-0006 的关键要求均有任务落点：正交状态、firmware-image-ready 约束、orphan diagnostics、删除旧 parser、测试迁移。
- 已吸收评审指出的实质遗漏：`cmd_build` 成功展示路径纳入 Task 4；调用点映射、discovery glob、start-qemu remedy、status tips 和 `init_pipeline.sh` 非范围声明均已补充。
- 已吸收第二/第三轮评审指出的门禁分叉：旧字段 regex 统一覆盖 `init=done`、`snapshot=yes`、`\brepos=`、`build=succeeded`、`image=yes`，并补入 start-qemu interactive 旧 `built` 诊断扫描。
- 计划没有使用占位符；所有任务都有具体文件、命令和预期结果。
- 命名统一使用 `firmware_image_*` 和 `firmware-image-ready machine`，不再使用裸 `image_ready`。
- 验证命令匹配当前 Linux + bash 环境和仓库现有测试入口。
- 最终验证包含窄测试、快速分层回归、交互矩阵回归、`tools/ob_check.sh` 和旧引用扫描。

## 审阅 Checkpoint

- 实施计划到此停止。审阅通过前，不进入实现。
