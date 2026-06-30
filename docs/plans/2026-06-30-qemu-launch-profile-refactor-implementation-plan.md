# QEMU launch profile 重构实施计划

## 目标

- 将 `ob start-qemu` 的 QEMU 启动决策收口到 `QEMU launch profile` module。
- `cmd_start_qemu` 只调用 `resolve_qemu_launch_profile`，不再直接调用 `resolve_qb_vars`、`detect_soc_type`、`derive_qemu_machine_name` 或 `find_ast2700_bootloaders`。
- `build_qemu_cmd` 的启动决策只来自 `QEMU_LAUNCH_*` 变量，不再自己判断 SoC 或查找 AST2700 bootloader；它仍可消费 image path、ports、serial path、`QEMU_BIN_FILE` / `QEMU_PCBIOS_DIR` 等运行时路径。
- 保留旧 machine 的 legacy AST2600 fallback，但必须输出 warning，并在 profile 内记录 source/confidence。
- 用 4 层测试矩阵完成质量门禁：unit、orchestration、protocol、structure/regression lock。

## 架构快照

`QEMU launch profile` 表达“某个 machine 应该如何被 QEMU 启动”。本次不新增持久化 profile 文件，也不拆 `lib/qemu_launch_profile.sh`；`resolve_qemu_launch_profile` 先作为 `lib/qemu.sh` 内的唯一外部 interface 落地。

成功解析后，调用者只读取 `QEMU_LAUNCH_*` 变量：

```bash
QEMU_LAUNCH_SOC_TYPE
QEMU_LAUNCH_SOC_SOURCE
QEMU_LAUNCH_SOC_CONFIDENCE
QEMU_LAUNCH_SYSTEM_NAME
QEMU_LAUNCH_MACHINE_NAME
QEMU_LAUNCH_MACHINE_NAME_SOURCE
QEMU_LAUNCH_MEM_FLAG
QEMU_LAUNCH_REQUIRES_PCBIOS
QEMU_LAUNCH_BOOTLOADER_UBOOT_NODTB
QEMU_LAUNCH_BOOTLOADER_UBOOT_DTB
QEMU_LAUNCH_BOOTLOADER_BL31
QEMU_LAUNCH_BOOTLOADER_OPTEE
QEMU_LAUNCH_BOOTLOADER_UBOOT_SIZE
```

`QB_*`、裸 `SOC_TYPE`、deploy hint、machine conf hint 和 machine-name fallback 都属于 `QEMU launch profile` implementation 细节。外部调用者不得再直接依赖这些旧变量作为决策 surface。

`resolve_qemu_launch_profile` 入口必须先清空全部 `QEMU_LAUNCH_*` 变量，再解析当前 machine。AST2700 后再解析 AST2600 时，`QEMU_LAUNCH_BOOTLOADER_*` 必须为空，`QEMU_LAUNCH_REQUIRES_PCBIOS=no`，不能继承上一次 profile 状态。

Deploy 证据规则固定如下：

- explicit AST2700 deploy evidence = AST2700 QEMU 启动所需四个 bootloader 文件同时存在：`u-boot-nodtb.bin`、`u-boot.dtb`、`bl31.bin`、`optee/tee-raw.bin`。
- partial AST2700 deploy evidence = 上述文件组只出现一部分；它不能触发 legacy AST2600 fallback，也不能覆盖 BitBake / machine-conf 的强 AST2600 证据。若 BitBake/machine conf 已判定 AST2700，则按缺 bootloader exit 3；若 BitBake/machine conf 已判定 AST2600，则继续采用强 AST2600 证据，可输出 stale deploy warning 但不得 conflict；若没有强证据，则按 SoC 不明确 exit 3。
- legacy AST2600 fallback 只能在 `.static.mtd` firmware image 存在、没有 QB_SYSTEM_NAME、没有可识别 machine conf、没有 explicit 或 partial AST2700 deploy evidence 时触发，并必须 warning。
- 空 deploy 目录、仅存在 deploy 目录、或没有 `.static.mtd` 的 deploy 目录都不算 legacy AST2600 证据。

错误码沿用 `exit-code 契约`：缺前置或可由用户补配置/补构建解决的情况用 exit 3，并输出诊断行 + 恰好一行 remedy line；证据冲突或 profile 内部矛盾用 exit 1。

## 输入工件

- `CONTEXT.md` 中的 `QEMU launch profile`、`QB variable`、`QEMU manifest`、`exit-code 契约`、`remedy line`
- `docs/adr/0002-qb-variables-via-bitbake-e.md`
- `docs/adr/0003-ob-first-front-door.md`
- `docs/adr/0007-qemu-launch-profile-start-qemu-decision-seam.md`
- `docs/adr/0002-qb-variables-via-bitbake-e.md` 只约束 QB variable 值必须来自 `bitbake -e`；不再拥有缺失输入处理策略。
- `docs/adr/0007-qemu-launch-profile-start-qemu-decision-seam.md` 拥有 `start-qemu` 缺失输入到 `QEMU_LAUNCH_*` 的兼容策略；fallback 不能回填或命名为 `QB_*`。
- 本次 grill-with-docs 已批准决策：函数 interface、不新增 profile 文件、保留 legacy fallback + warning、AST2700 bootloader 收进 profile、最终结构一次落地、4 层测试矩阵

## 文件结构与职责

- Modify: `lib/qemu.sh`
  - 新增 `resolve_qemu_launch_profile` 作为 QEMU launch profile 的唯一外部 interface。
  - 在 `resolve_qemu_launch_profile` 入口清空全部 `QEMU_LAUNCH_*` 变量，避免跨 machine / 跨测试用例泄漏。
  - 将 QB variable 解析、SoC 证据收集、QEMU machine name 推导、AST2700 bootloader 校验收进 profile implementation。
  - 将旧 public 函数删除或改成 profile 内部 helper；不保留旧 public 调用面给 `commands.sh` 使用。
  - 保持 `lib/*.sh` 纯函数定义结构，避免函数定义外新增顶层执行语句。
- Modify: `lib/commands.sh`
  - `cmd_start_qemu` 改为只调用 `resolve_qemu_launch_profile` 获取启动画像。
  - `cmd_start_qemu` 后续启动决策只读取 `QEMU_LAUNCH_*`；运行时路径、端口和 serial log 仍由原有流程提供。
  - 保持既有 init-done 与 firmware image prerequisite 顺序。
- Modify: `tests/unit/soc.sh`
  - 迁移为 profile helper 的纯规则测试，覆盖 QB_SYSTEM_NAME、machine conf include、machine-name fallback 等不依赖 BitBake 的规则。
- Modify/Create: `tests/orchestration/qemu_launch_profile.sh`
  - 覆盖 `resolve_qemu_launch_profile` interface，使用 fake BitBake、fake deploy dir 和 fake machine conf。
- Modify: `tests/orchestration/resolve_qb_vars.sh`
  - 如果 `resolve_qb_vars` 不再是 public surface，则迁移或删除对应测试；保留的测试必须通过 `resolve_qemu_launch_profile` 断言 QB 解析结果。
- Modify/Create: `tests/protocol/qemu_launch_profile_remedy.sh`
  - 覆盖 profile 相关 exit 3 的诊断行 + remedy line 契约。
- Modify/Create: `tests/protocol/qemu_launch_profile_structure.sh`
  - 锁定旧调用清零、QEMU helper 不再读取旧决策变量、`build_qemu_cmd` 不再查找 bootloader、`cmd_start_qemu` 必须调用新 interface。
- Create: `tests/unit/qemu_launch_consumers.sh`
  - 直接构造 `QEMU_LAUNCH_*` 后测试 `build_qemu_cmd` 与 `ensure_qemu_firmware` 的 consumer 行为。
- Inspect: `tests/protocol/start_qemu_remedy.sh`
  - 如 profile remedy 会透出到 `cmd_start_qemu`，补充 start-qemu 层面的 exit 3 文案断言。
- Inspect: `tests/integration/manual_matrix_qemu.exp`
  - 保持手动 QEMU 矩阵说明准确；不把真实 QEMU 启动纳入默认快速验证。
- Not in scope: 新增持久化 `workspace/configs/<machine>.qemu-launch-profile` 文件。
- Not in scope: 拆分 `lib/qemu_launch_profile.sh`。
- Not in scope: 改变 `QEMU manifest` 的语义或文件格式。

## 任务清单

### Task 1: 锁定 profile helper 纯规则测试

- 目标：先用 unit 测试锁住不依赖 BitBake 的 SoC 与 machine-name 规则。
- Files
  - Modify: `tests/unit/soc.sh`
  - Modify: `lib/qemu.sh`
- 验证范围：`bash tests/unit/soc.sh`

#### Step 1: 写失败测试或失败检查

- Change:
  - 将现有 `detect_soc_type` 直接测试迁移为 profile helper 或新 interface 的纯规则断言。
  - 覆盖 `qemu-system-arm -> ast2600`、`qemu-system-aarch64 -> ast2700`、unknown `QB_SYSTEM_NAME` 不产生 strong SoC。
  - 覆盖 machine conf include：`ast2600.inc`、`ast2600-default`、`ast2700-sdk.inc`、多层 include、include 循环、missing include。
  - 覆盖 machine-name fallback：`b865g8-bytedance -> b865g8-bmc`，`nodash -> exit 3/remedy`。
- Run: `bash tests/unit/soc.sh`
- Expected: 当前失败，失败信号指向新 helper/interface 未定义或旧 `detect_soc_type` 仍是测试 surface；没有 shell 语法错误。

#### Step 2: 运行并确认当前失败

- Run: `bash tests/unit/soc.sh`
- Expected: 非零退出；至少一个断言说明 `QEMU_LAUNCH_*` 或 profile helper 尚未实现。

#### Step 3: 写最小实现

- Change:
  - 在 `lib/qemu.sh` 增加 profile 内部 helper，用于 QB_SYSTEM_NAME 到 SoC 映射、machine conf chain SoC 识别、machine-name fallback。
  - helper 不执行 BitBake，不访问真实 OpenBMC build，只处理传入变量或 fixture 文件。
  - 对 `nodash` fallback 失败输出诊断行和恰好一行 remedy line，并 exit 3。

#### Step 4: 运行并确认通过

- Run: `bash tests/unit/soc.sh`
- Expected: 测试通过；输出 PASS/FAIL 摘要中 FAIL=0。

### Task 2: 建立 `resolve_qemu_launch_profile` orchestration 测试

- 目标：把核心测试面移到 `resolve_qemu_launch_profile` interface。
- Files
  - Create: `tests/orchestration/qemu_launch_profile.sh`
  - Inspect/Modify: `tests/orchestration/resolve_qb_vars.sh`
- 验证范围：`bash tests/orchestration/qemu_launch_profile.sh`

#### Step 1: 写失败测试或失败检查

- Change:
  - 使用 `tests/lib/ob_loader.sh`、`tests/lib/assert.sh`、`tests/lib/stub.sh` 加载 `ob` 并 fake `bitbake`。
  - 构造 fake `OPENBMC_DIR/setup`、`BUILD_DIR`、`tmp/deploy/images/<machine>` 和 machine conf fixture。
  - 覆盖强证据：BitBake 给 `QB_SYSTEM_NAME=qemu-system-arm` 与 `qemu-system-aarch64`。
  - 覆盖 machine conf 强证据：无 `QB_SYSTEM_NAME`，但 include 明确 ast2600/ast2700。
  - 覆盖优先级一致与冲突：BitBake 与 conf 一致成功；BitBake ast2600 + conf ast2700 exit 1；conf ast2600 + explicit deploy ast2700 exit 1；BitBake/machine-conf 强 AST2600 + partial AST2700 deploy evidence 继续成功为 AST2600，不得 conflict。
  - 覆盖 legacy：无 QB_SYSTEM_NAME、无可识别 conf、有 `.static.mtd` 且没有 AST2700 explicit/partial deploy evidence 时 success，`QEMU_LAUNCH_SOC_TYPE=ast2600`、`QEMU_LAUNCH_SOC_CONFIDENCE=legacy`，stderr/stdout 包含 warning。
  - 覆盖 deploy evidence：四个 AST2700 bootloader 文件齐全时形成 explicit AST2700 evidence；只出现部分文件时不能触发 legacy AST2600 fallback；partial AST2700 evidence + 强 AST2600 证据不得覆盖或 conflict；空 deploy dir、仅 deploy dir、无 `.static.mtd` 均不算 legacy 证据。
  - 覆盖无证据：无 QB_SYSTEM_NAME、无可识别 conf、无 deploy image 时 exit 3 + remedy。
  - 覆盖入口 reset：先解析 AST2700，再解析 AST2600，确认 `QEMU_LAUNCH_BOOTLOADER_*` 清空、`QEMU_LAUNCH_REQUIRES_PCBIOS=no`。
  - 覆盖 QEMU machine name：`QB_MACHINE` 优先；空时使用 machine-name fallback；fallback 成功 warning；fallback 失败 exit 3 + remedy。
  - 覆盖 AST2700 bootloader：四个文件齐全成功并设置 `QEMU_LAUNCH_BOOTLOADER_*`；缺任一文件 exit 3 + remedy；AST2600 不检查这些文件。
  - 覆盖 `QB_MEM`：有值保留到 `QEMU_LAUNCH_MEM_FLAG`，空值不报错。
- Run: `bash tests/orchestration/qemu_launch_profile.sh`
- Expected: 当前失败，失败信号指向 `resolve_qemu_launch_profile` 未定义或 `QEMU_LAUNCH_*` 变量未设置；没有 fixture 路径或 stub 语法错误。

#### Step 2: 运行并确认当前失败

- Run: `bash tests/orchestration/qemu_launch_profile.sh`
- Expected: 非零退出；至少一个断言说明 profile interface 尚未实现。

#### Step 3: 写最小实现

- Change:
  - 在 `lib/qemu.sh` 实现 `resolve_qemu_launch_profile "$MACHINE"`。
  - 函数入口调用 `reset_qemu_launch_profile` 或等价初始化逻辑，清空全部 `QEMU_LAUNCH_*`。
  - 内部调用 BitBake 一次解析 `QB_MACHINE`、`QB_MEM`、`QB_SYSTEM_NAME`。
  - 收集 SoC 证据并交叉验证：BitBake、machine conf、deploy explicit/partial evidence、legacy fallback。
  - 对 legacy AST2600 fallback 保持兼容启动，但输出 warning，并设置 `QEMU_LAUNCH_SOC_SOURCE=legacy-deploy`、`QEMU_LAUNCH_SOC_CONFIDENCE=legacy`。
  - 解析 QEMU machine name，设置 `QEMU_LAUNCH_MACHINE_NAME` 和 `QEMU_LAUNCH_MACHINE_NAME_SOURCE`。
  - AST2700 时解析并校验 bootloader 文件，设置 `QEMU_LAUNCH_REQUIRES_PCBIOS=yes` 和 `QEMU_LAUNCH_BOOTLOADER_*`；AST2600 设置 `QEMU_LAUNCH_REQUIRES_PCBIOS=no`。
  - 所有 exit 3 输出诊断行 + 恰好一行 remedy line；冲突输出清晰诊断并 exit 1。

#### Step 4: 运行并确认通过

- Run: `bash tests/orchestration/qemu_launch_profile.sh`
- Expected: 测试通过；FAIL=0；legacy fallback 用例能观察到 warning。

### Task 3: 切换 `cmd_start_qemu` 到 profile interface

- 目标：`cmd_start_qemu` 只通过 `resolve_qemu_launch_profile` 获取 QEMU 启动画像。
- Files
  - Modify: `lib/commands.sh` (`cmd_start_qemu`)
  - Modify: `lib/qemu.sh` (`derive_qemu_paths`, `ensure_qemu_binary`, `ensure_qemu_firmware`, `build_qemu_cmd` 相关变量读取)
  - Inspect/Modify: `tests/protocol/start_qemu_remedy.sh`
- 验证范围：`bash tests/protocol/start_qemu_remedy.sh` 与结构扫描命令。

#### Step 1: 写当前状态检查或失败检查

- Run: `awk '/^cmd_start_qemu\(\)/,/^cmd_stop_qemu\(\)/ { print }' lib/commands.sh | rg 'resolve_qb_vars\s*$|detect_soc_type\s*$|derive_qemu_machine_name\s*$|find_ast2700_bootloaders\s*'`
- Expected: 当前有匹配，说明旧 public 调用仍在 `cmd_start_qemu` 区段内。

#### Step 2: 运行并确认当前失败

- Run: `awk '/^cmd_start_qemu\(\)/,/^cmd_stop_qemu\(\)/ { print }' lib/commands.sh | rg 'resolve_qb_vars\s*$|detect_soc_type\s*$|derive_qemu_machine_name\s*$|find_ast2700_bootloaders\s*'`
- Expected: `rg` 退出码为 0，并显示旧调用名。

#### Step 3: 写最小实现

- Change:
  - 将 `cmd_start_qemu` 中 `resolve_qb_vars`、`detect_soc_type`、`derive_qemu_machine_name` 替换为单次 `resolve_qemu_launch_profile "$MACHINE"`。
  - 将启动展示中的 SoC、QEMU machine、binary arch、mem 等读取改为 `QEMU_LAUNCH_*`。
  - 调整 `derive_qemu_paths` 和 `ensure_qemu_binary` 的输入，使它们使用 `QEMU_LAUNCH_SYSTEM_NAME`，不再读 `QB_SYSTEM_NAME`。
  - 调整 `ensure_qemu_firmware` 的输入，使它优先消费 `QEMU_LAUNCH_REQUIRES_PCBIOS`，不再从 `QEMU_LAUNCH_SOC_TYPE` 或裸 `SOC_TYPE` 重新推导 pc-bios 需求。
  - 保持 existing QEMU instance 检测、端口解析、confirm、dry-run 和 launch 流程顺序不变。

#### Step 4: 运行并确认通过

- Run: `bash tests/protocol/start_qemu_remedy.sh`
- Expected: 测试通过；缺 init-done 与缺 firmware image 的 exit 3/remedy 行为保持不变。
- Run: `awk '/^cmd_start_qemu\(\)/,/^cmd_stop_qemu\(\)/ { print }' lib/commands.sh | rg 'resolve_qb_vars\s*$|detect_soc_type\s*$|derive_qemu_machine_name\s*$|find_ast2700_bootloaders\s*'`
- Expected: 无匹配，`rg` 退出码为 1。

### Task 4: 简化 QEMU launch consumers

- 目标：`build_qemu_cmd` 不再查找 AST2700 bootloader，也不再判断 SoC 来源；`ensure_qemu_firmware` 只根据 `QEMU_LAUNCH_REQUIRES_PCBIOS` 决定是否检查 pc-bios。
- Files
  - Modify: `lib/qemu.sh` (`build_qemu_cmd`, `ensure_qemu_firmware`, AST2700 bootloader helper)
  - Create: `tests/unit/qemu_launch_consumers.sh`
  - Test: `tests/orchestration/qemu_launch_profile.sh`
- 验证范围：`bash tests/unit/qemu_launch_consumers.sh`、`bash tests/orchestration/qemu_launch_profile.sh` 与 `bash tests/protocol/qemu_launch_profile_structure.sh`。Task 4 不手写跨函数 `awk` range；结构条件统一由 Task 6 的结构测试脚本验证。

#### Step 1: 写当前状态检查或失败检查

- Change:
  - 新建 `tests/unit/qemu_launch_consumers.sh`。
  - 直接设置 `QEMU_LAUNCH_MACHINE_NAME`、`QEMU_LAUNCH_MEM_FLAG`、`QEMU_LAUNCH_SOC_TYPE`、`QEMU_LAUNCH_BOOTLOADER_*`、`QEMU_LAUNCH_REQUIRES_PCBIOS`、`QEMU_BIN_FILE`、`QEMU_PCBIOS_DIR` 和 image/port/serial fixture。
  - 调用 `build_qemu_cmd`，断言 `QEMU_CMD` 包含正确 `-machine`、`-m`、AST2700 loader 参数；AST2600 case 不包含 AST2700 loader 参数。
  - 调用 `ensure_qemu_firmware`，断言 `QEMU_LAUNCH_REQUIRES_PCBIOS=yes` 时检查 `ast27x0_bootrom.bin`，`no` 时即使 pc-bios 缺失也跳过。
- Run: `bash tests/unit/qemu_launch_consumers.sh`
- Expected: 当前失败，失败信号指向测试文件不存在，或 consumer 仍未读取 `QEMU_LAUNCH_*`。
- Run: `bash tests/protocol/qemu_launch_profile_structure.sh`
- Expected: 当前失败，失败原因包含 `build_qemu_cmd` / `ensure_qemu_firmware` 仍有旧决策变量或 bootloader discovery 调用，或结构测试脚本尚未创建。

#### Step 2: 运行并确认当前失败

- Run: `bash tests/unit/qemu_launch_consumers.sh`
- Expected: 非零退出；至少一个断言说明 consumer 尚未消费 `QEMU_LAUNCH_*` 或 pc-bios gating 仍从 SoC 推导。
- Run: `bash tests/protocol/qemu_launch_profile_structure.sh`
- Expected: 非零退出；至少一个断言说明 `build_qemu_cmd` / `ensure_qemu_firmware` 尚未完成 consumer 化或结构测试脚本尚未创建。

#### Step 3: 写最小实现

- Change:
  - 将 `build_qemu_cmd` 中 SoC 判断改为 `QEMU_LAUNCH_SOC_TYPE`。
  - AST2700 loader 参数只读取 `QEMU_LAUNCH_BOOTLOADER_*` 和 `QEMU_LAUNCH_BOOTLOADER_UBOOT_SIZE`。
  - 内存参数只读取 `QEMU_LAUNCH_MEM_FLAG`。
  - `ensure_qemu_firmware` 只读取 `QEMU_LAUNCH_REQUIRES_PCBIOS` 判断是否检查 pc-bios。
  - 将 `find_ast2700_bootloaders` 删除或改为 profile 内部 helper，确保 `build_qemu_cmd` 不再调用它。

#### Step 4: 运行并确认通过

- Run: `bash tests/unit/qemu_launch_consumers.sh`
- Expected: 测试通过；`build_qemu_cmd` 产出的 `QEMU_CMD` 正确包含 `QEMU_LAUNCH_*` 对应的 machine/mem/loader 参数；`ensure_qemu_firmware` 按 `QEMU_LAUNCH_REQUIRES_PCBIOS` yes/no 分支执行。
- Run: `bash tests/orchestration/qemu_launch_profile.sh`
- Expected: 测试通过；AST2700 bootloader 成功/失败都在 profile interface 测试中被覆盖。
- Run: `bash tests/protocol/qemu_launch_profile_structure.sh`
- Expected: 测试通过；`build_qemu_cmd` 和 `ensure_qemu_firmware` 的结构条件由统一结构测试脚本验证，不在 Task 4 中复制跨函数 `awk` range。

### Task 5: 建立 exit-code/remedy protocol 测试

- 目标：profile 相关 exit 3 都满足诊断行 + 恰好一行 remedy line。
- Files
  - Create: `tests/protocol/qemu_launch_profile_remedy.sh`
  - Modify: `lib/qemu.sh`
- 验证范围：`bash tests/protocol/qemu_launch_profile_remedy.sh`

#### Step 1: 写失败测试或失败检查

- Change:
  - 覆盖 build dir/setup 缺失、无法判断 SoC、AST2700 bootloader 缺失、QEMU machine name fallback 失败。
  - 每个用例断言退出码为 3。
  - 每个用例断言存在诊断行。
  - 每个用例断言 remedy line 恰好一行，且不串接第二条命令。
  - 断言配置类 remedy 可以是 `Define QB_SYSTEM_NAME...` 或 `Define QB_MACHINE...`，不强行要求 `ob` 命令。
  - 覆盖冲突用例 exit 1，并断言不输出 `Run 'ob init` / `Run 'ob build` 这类误导 remedy。
- Run: `bash tests/protocol/qemu_launch_profile_remedy.sh`
- Expected: 当前失败，失败原因是脚本不存在或 profile remedy 行为尚未满足契约。

#### Step 2: 运行并确认当前失败

- Run: `bash tests/protocol/qemu_launch_profile_remedy.sh`
- Expected: 非零退出；失败指向 remedy 数量、退出码或诊断行不匹配。

#### Step 3: 写最小实现

- Change:
  - 在 `resolve_qemu_launch_profile` 的 exit 3 路径统一输出诊断行和恰好一行 remedy line。
  - 对 build dir/setup 缺失输出 `Run 'ob init <machine>' first.`。
  - 对无法判断 SoC 输出 `Define QB_SYSTEM_NAME or include an ast2600/ast2700 machine conf fragment, then retry.`。
  - 对 AST2700 bootloader 缺失输出 `Run 'ob build <machine>' first.`。
  - 对 QEMU machine name 缺失输出 `Define QB_MACHINE in the machine conf, then retry.`。
  - 对 conflict 保持 exit 1，不输出 forward remedy line。

#### Step 4: 运行并确认通过

- Run: `bash tests/protocol/qemu_launch_profile_remedy.sh`
- Expected: 测试通过；所有 exit 3 用例均恰好一条 remedy line；conflict 用例 exit 1。

### Task 6: 建立结构与调用次数回归锁

- 目标：防止旧 shallow 调用回流，并防止 `bitbake -e` 被重复调用；结构扫描只在本测试脚本内封装，不在最终验证里复制脆弱的跨函数 `awk` range。
- Files
  - Create: `tests/protocol/qemu_launch_profile_structure.sh`
  - Modify: `tests/run_all.sh` 不需要手动登记；默认会跑 `tests/protocol/*.sh`。
- 验证范围：`bash tests/protocol/qemu_launch_profile_structure.sh`

#### Step 1: 写失败测试或失败检查

- Change:
  - 在 `tests/protocol/qemu_launch_profile_structure.sh` 内封装 `extract_shell_function <file> <function>` 或等价 helper，用目标函数头开始、下一个顶层函数定义结束来提取函数体；目标函数不存在时测试必须失败。
  - 断言 `cmd_start_qemu` 函数体必须出现 `resolve_qemu_launch_profile`。
  - 断言 `cmd_start_qemu` 函数体不得直接出现 `resolve_qb_vars`、`detect_soc_type`、`derive_qemu_machine_name`、`find_ast2700_bootloaders`。
  - 断言 `build_qemu_cmd` 函数体不得直接出现 `find_ast2700_bootloaders`、`machine_conf_chain_contains`、`detect_soc_type`、裸 `QB_MEM_SIZE_FLAG`、裸 `SOC_TYPE`；不得误杀 `QEMU_LAUNCH_SOC_TYPE` 或 `QEMU_LAUNCH_BOOTLOADER_*`。
  - 断言 `derive_qemu_paths`、`check_jenkins_update`、`ensure_qemu_binary_community`、`ensure_qemu_binary_custom` 函数体不得读取 `QB_SYSTEM_NAME` 或裸 `SOC_TYPE`，只能通过 `QEMU_LAUNCH_SYSTEM_NAME` 获得 QEMU binary name。
  - 断言 `ensure_qemu_firmware` 函数体不得读取 `QB_SYSTEM_NAME`、裸 `SOC_TYPE` 或 `QEMU_LAUNCH_SOC_TYPE`，只能通过 `QEMU_LAUNCH_REQUIRES_PCBIOS` 判断 pc-bios 需求。
  - 用 fake `bitbake` 调用日志跑一个 profile success path，断言 `bitbake` 调用次数恰好为 1。
- Run: `bash tests/protocol/qemu_launch_profile_structure.sh`
- Expected: 当前失败，失败原因是旧调用仍存在，或测试脚本尚未创建。

#### Step 2: 运行并确认当前失败

- Run: `bash tests/protocol/qemu_launch_profile_structure.sh`
- Expected: 非零退出；至少一个断言显示旧调用仍存在或 `bitbake` 调用次数不是 1。

#### Step 3: 写最小实现

- Change:
  - 删除或私有化旧 public helper，使 `commands.sh` 无法继续直接调用旧 interface。
  - 确保 `resolve_qemu_launch_profile` 内部只执行一次 BitBake 解析，并把解析结果传递给后续 profile 逻辑。
  - 如果保留 `resolve_qb_vars` 作为内部 helper，结构测试不得允许 `cmd_start_qemu` 直接调用它；如果删除该函数，同步清理旧测试。
  - 结构测试中的函数体提取不得依赖“当前相邻函数名”作为结束锚点，例如不得写死 `check_jenkins_update -> download_and_replace_community_qemu` 或 `ensure_qemu_firmware -> resolve_qb_vars` 这类会随函数顺序/删改失效的跨函数 range。

#### Step 4: 运行并确认通过

- Run: `bash tests/protocol/qemu_launch_profile_structure.sh`
- Expected: 测试通过；旧调用清零；profile success path 的 fake `bitbake` 调用次数恰好为 1；QEMU helper 区段不再读取 `QB_SYSTEM_NAME`、裸 `SOC_TYPE` 或从 SoC 推导 pc-bios 需求。

### Task 7: 清理旧测试 surface 与命名漂移

- 目标：测试体系只把 `resolve_qemu_launch_profile` 当核心 test surface，不继续扩大旧函数测试。
- Files
  - Modify: `tests/unit/soc.sh`
  - Modify: `tests/orchestration/resolve_qb_vars.sh`
  - Inspect: `tests/unit/*.sh`, `tests/orchestration/*.sh`, `tests/protocol/*.sh`
- 验证范围：旧函数名扫描与分层测试。

#### Step 1: 写当前状态检查或失败检查

- Run: `rg 'detect_soc_type|derive_qemu_machine_name|find_ast2700_bootloaders|resolve_qb_vars' tests/unit tests/orchestration tests/protocol -g '!qemu_launch_profile_structure.sh'`
- Expected: 当前可能有匹配；需要逐项判断是否仍是允许的内部 helper 测试，或应迁移到 profile surface。

#### Step 2: 运行并确认当前状态

- Run: `rg 'detect_soc_type|derive_qemu_machine_name|find_ast2700_bootloaders|resolve_qb_vars' tests/unit tests/orchestration tests/protocol -g '!qemu_launch_profile_structure.sh'`
- Expected: 若有匹配，记录具体文件；匹配不得来自 `cmd_start_qemu` public surface 测试。

#### Step 3: 写最小实现

- Change:
  - 将 `tests/orchestration/resolve_qb_vars.sh` 的核心断言迁移到 `tests/orchestration/qemu_launch_profile.sh`；如果 `resolve_qb_vars` 删除，则删除或改写该测试文件，使默认 `tests/run_all.sh` 不失败。
  - `tests/unit/soc.sh` 可以保留纯 helper 测试，但用例必须服务 profile implementation，不能要求 `cmd_start_qemu` 调用旧 helper。
  - 所有新断言使用 `QEMU_LAUNCH_*` 命名，不新增 `QB_*` / `SOC_TYPE` 外部依赖。

#### Step 4: 运行并确认通过

- Run: `tests/run_all.sh`
- Expected: protocol/unit/orchestration 默认快速测试全部通过；无旧 public surface 失败。

### Task 8: 运行仓库配套自检并收口文档引用

- 目标：完成 ob/lib 改动后的仓库门禁，并确认 docs/glossary/ADR 与实现命名一致。
- Files
  - Inspect: `CONTEXT.md`
  - Inspect: `docs/adr/0007-qemu-launch-profile-start-qemu-decision-seam.md`
  - Inspect: `lib/qemu.sh`, `lib/commands.sh`, `tests/**`
- 验证范围：`tools/ob_check.sh`

#### Step 1: 写当前状态检查或失败检查

- Run: `rg 'QEMU launch profile|resolve_qemu_launch_profile|QEMU_LAUNCH_' CONTEXT.md docs/adr/0007-qemu-launch-profile-start-qemu-decision-seam.md lib/qemu.sh lib/commands.sh tests`
- Expected: 能看到 glossary、ADR、实现和测试都使用同一命名；如果没有实现命名，说明前序任务未完成。

#### Step 2: 运行并确认当前状态

- Run: `rg 'QEMU metadata|QEMU 启动配置' lib/qemu.sh lib/commands.sh tests docs/adr/0007-qemu-launch-profile-start-qemu-decision-seam.md`
- Expected: 无不应出现的新命名；`QEMU metadata` 只允许在 `CONTEXT.md` Avoid 或旧报告中出现，不应进入实现和新测试。

#### Step 3: 写最小实现

- Change:
  - 修正命名漂移、文案中多条 remedy line、旧 public 调用残留、shellcheck 或 exit_contract 报出的本次改动问题。
  - 不修复与本次无关的历史问题；如 `tools/ob_check.sh` 暴露历史 baseline 外的新问题，先定位是否由本次改动引入。

#### Step 4: 运行并确认通过

- Run: `tools/ob_check.sh`
- Expected: ob/lib 配套自检通过，包括结构检查、函数登记、shellcheck baseline、exit-contract 和默认测试聚合。

## 执行纪律

- 开始实现前先批判性复查整份计划；如果发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 如果当前就在 `main` 或 `master`，且用户没有明确同意，开始实现前先确认。
- 按任务顺序执行，不要无声跳步、合并步或改变任务目标。
- 每完成一个任务，都运行该任务定义的验证。
- 旧 public 调用清零是本次完成标准，不允许以“后续阶段清理”收尾。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下来说明，不要猜。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `bash tests/unit/qemu_launch_consumers.sh`
- Expected: QEMU launch consumer 单测通过，覆盖 `build_qemu_cmd` 和 `ensure_qemu_firmware` 的 `QEMU_LAUNCH_*` 消费行为。
- Run: `bash tests/protocol/qemu_launch_profile_structure.sh`
- Expected: 结构测试通过；旧调用清零；QEMU helper 函数体不再读取 `QB_SYSTEM_NAME`、裸 `SOC_TYPE` 或从 SoC 推导 pc-bios；profile success path 的 fake `bitbake` 调用次数恰好为 1。
- Run: `tests/run_all.sh`
- Expected: protocol/unit/orchestration 默认快速测试全部通过，输出 `ALL GREEN`。
- Run: `tools/ob_check.sh`
- Expected: ob/lib 配套自检通过；无本次改动引入的结构、shellcheck、exit-contract 或测试失败。

## Inline 自检结果

- 设计覆盖度：已覆盖命名、函数 interface、不新增 profile 文件、不拆新 lib 文件、入口 reset、ADR-0002/0007 决策所有权拆分、deploy evidence 判据、partial AST2700 evidence 与强 AST2600 证据关系、`QEMU_LAUNCH_REQUIRES_PCBIOS` firmware 决策入口、QEMU helper 旧变量结构锁、consumer 行为测试、legacy fallback + warning、AST2700 bootloader 收进 profile、一次完成最终结构、exit 3 remedy、4 层测试矩阵。
- 占位符扫描：无 `TODO`、`TBD`、`later` 或未展开的错误处理占位。
- 正文格式与任务粒度：文档从标题开始；任务按测试、实现切换、结构锁、最终验证拆分，每个任务有明确命令和预期。
- 命名一致性：统一使用 `QEMU launch profile`、`resolve_qemu_launch_profile`、`QEMU_LAUNCH_*`。
- 可执行性：路径和命令均来自现有仓库结构；验证命令使用 Linux/bash 环境和仓库现有测试入口。
- 验证完整性：每个任务都有当前失败检查、实现动作和通过验证；最终验证包含 consumer 单测、结构测试、`tests/run_all.sh` 与 `tools/ob_check.sh`，不再手写脆弱的跨函数 `awk` range。

## 审阅 Checkpoint

实施计划写好后先审阅。审阅通过前，不进入实现。
