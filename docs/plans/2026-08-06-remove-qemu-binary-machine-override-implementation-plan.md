# 删除 QEMU binary machine override 实施计划

## 目标

- 移除 `QEMU launch profile` 的 "QEMU binary 机型覆盖" 子能力（`qemu_launch_profile_apply_binary_machine_override` 及其 helper `qemu_binary_supports_machine`），让 QEMU machine 名解析链单一化为：`QB_MACHINE`（qemuboot.conf deploy 产物 > `bitbake -e`）→ 两者皆缺时 legacy machine-name fallback 派生 `<prefix>-bmc`。
- ob 不再依据已安装 binary 支持的机型改写 machine 名；机型事实源单一化为 recipe 的 `QB_MACHINE`，binary 不认的值由 QEMU 的 unsupported-machine 直接暴露（fail-loud）。

## 架构快照

- `resolve_qemu_launch_profile` 之后，`qemu_prepare_launch` 不再调用 `apply_binary_machine_override`；`QEMU_LAUNCH_MACHINE_NAME` 由 `apply_machine_name`（`QB_MACHINE` 或 legacy fallback）一锤定音，`build_qemu_cmd` 原样消费。
- `QEMU_LAUNCH_MACHINE_NAME_SOURCE` 取值集合收敛为 `qemuboot` / `bitbake` / `legacy-name`，不再产生 `qemu-binary`。
- `apply_machine_name` 上方补设计注释，记录"为何 ob 不做 binary 机型适配"（替代 ADR，推理贴实现）。
- 三层防 override 复活：(1) `tests/orchestration/qemu_prepare_launch.sh` 新增 prepare-level 行为测试——声明机型 + binary `-machine help` 暴露 `<prefix>-bmc`，断言 prepare 不改写（覆盖任意形式的 binary 改写，含"换名实现"）；(2) `tests/protocol/qemu_launch_profile_structure.sh` 新增结构锁——锁住两个旧函数名不在 `qemu_prepare_launch` 复活（防照搬）；(3) `tests/unit/qemu_launch_consumers.sh` 重写——`build_qemu_cmd` 原样消费层回归。
- `ensure_qemu_binary` 保留不变（`build_qemu_cmd` / verify / pgrep 仍依赖 `QEMU_BIN_FILE`）。

## 全局约束

- 机型事实源单一化为 recipe 的 `QB_MACHINE`：不得重新引入任何"据 binary 支持的机型改写 `QEMU_LAUNCH_MACHINE_NAME`"的逻辑。
- `apply_machine_name` 的 legacy fallback 行为（空 `QB_MACHINE` → `<prefix>-bmc`；nodash → exit 3 + remedy）保持不变。
- 非 bytedance 的 b865g8 变体（`b865g8` / `b865g8-a2` / `b865g8-iec`）若未在 recipe 显式设 `QB_MACHINE`，将使用 include 链继承的通用机型（如 `ast2700a1-evb`）而非 `<prefix>-bmc`——这是已认可的副作用，不在本计划修复范围。
- 不新增 ADR；设计推理落 `apply_machine_name` 代码注释 + commit message。
- `CONTEXT.md` 的 `QEMU launch profile` 术语条目已在 grill 阶段更新（描述当前正确行为，无 ADR 链接），本计划不再改动它。
- 验证命令直接执行、由退出码判读，不得用 `; echo "exit=$?"` 之类让 echo 吞掉真实退出码。
- "无残留" grep 只扫生产代码 `lib/ ob`——`tests/protocol/qemu_launch_profile_structure.sh` 的结构锁文本预期保留两个旧函数名（用于封口），不计为残留。

## 输入工件

- grill 共识（`/grill-with-docs` 达成）：删除 override 而非"仅兜底"或"整名探测"；穷举机型取值路径后，删除与"仅兜底"运行时仅在"`QB_MACHINE` 给了 binary 不认的值"一种情况下不同，删除更符合 fail-loud 与事实源单一化。
- `CONTEXT.md` `QEMU launch profile` / `QB variable` 术语条目（已更新）。
- 历史背景：override 由 commit `0cae680` 引入，ADR-0007 全文未记录该决策（属实现细节）。

## 文件结构与职责

- Modify: `lib/qemu_launch_profile.sh`
  - 删除 `qemu_binary_supports_machine`（约 104-109 行）与 `qemu_launch_profile_apply_binary_machine_override`（约 111-129 行）。
  - 在 `qemu_launch_profile_apply_machine_name` 定义上方补设计注释。
- Modify: `lib/qemu.sh`
  - 删除 `qemu_prepare_launch` 内的 `qemu_launch_profile_apply_binary_machine_override` 调用（约 93 行）；`ensure_qemu_binary` 调用（92 行）保留。
- Modify: `tests/unit/qemu_launch_consumers.sh`
  - 重写 65-85 行的 override 专属测试块，替换为"`build_qemu_cmd` 原样消费声明机型"回归断言（consumer 层回归，不覆盖 prepare 改写——那是 orchestration 层职责）。
- Modify: `tests/orchestration/qemu_prepare_launch.sh`
  - 新增一个 prepare-level 行为测试 case：声明机型 + fake binary `-machine help` 暴露 `<prefix>-bmc`，断言 `qemu_prepare_launch` 不改写（真正经过 override 原位置的端到端覆盖）。
- Modify: `tests/protocol/qemu_launch_profile_structure.sh`
  - 新增一条 `assert_function_not_match` 结构锁，封口 `qemu_prepare_launch` 不再做 binary 机型改写。
- 可能 Modify: `tests/.shellcheck-baseline`（由 `tools/ob_check.sh` 判定；当前 baseline 无 override 相关条目，大概率无差异）。
- 不改动：`tests/unit/soc.sh`（`apply_machine_name` 的 legacy fallback / nodash 测试仍有效）、`tools/extract_funcs.py`（无函数清单 baseline，删函数不触发结构检查）。

## 任务清单

### Task 1: 重写 consumers 测试，解除对 override 函数的依赖

- 目标
  - 把 `tests/unit/qemu_launch_consumers.sh` 的 override 专属块（65-85 行）替换为"`build_qemu_cmd` 原样消费声明机型"回归断言，使该测试不再调用 `qemu_launch_profile_apply_binary_machine_override`，为 Task 2 删除该函数扫清依赖。
  - 注意：本任务只覆盖 consumer 层（`build_qemu_cmd` 不改写），**不**覆盖 `qemu_prepare_launch` 的 binary 改写——后者由 Task 2 的 prepare-level 行为测试覆盖。
- Files
  - Modify: `tests/unit/qemu_launch_consumers.sh`（替换 65-85 行整块，含 66-73 行的 `STUB_QEMU` 与 74-85 行的两段 override 断言）
- 接口契约
  - Consumes: `build_qemu_cmd`（`lib/qemu.sh`，原样消费 `QEMU_LAUNCH_MACHINE_NAME`）、文件头已声明的 `$QEMU_BIN_FILE` / `$QEMU_PCBIOS_DIR` / `$image_file` / `$serial_log` / `$serial_sock`
  - Produces: 一个不引用 `qemu_launch_profile_apply_binary_machine_override` 的 consumers 测试（Task 2 删除该函数的前置）
- 验证范围
  - `bash tests/unit/qemu_launch_consumers.sh` 退出码 0；且 `tests/unit/qemu_launch_consumers.sh` 不再含 `apply_binary_machine_override` 调用。

- [ ] Step 1: 确认当前测试块仍依赖 override 函数
- Run: `grep -n "apply_binary_machine_override" tests/unit/qemu_launch_consumers.sh`
- Expected: 命中 `:77` 与 `:84` 两行调用（当前状态——测试依赖待删函数）。

- [ ] Step 2: 替换 override 测试块为"声明机型原样消费"回归断言
- Change: 将 65-85 行整块（从 `# --- QEMU binary-supported platform machine overrides generic qemuboot machine ---` 到 `assert_eq "binary machine override keeps no-prefix machine" ...` 一行）替换为：

```bash
# --- build_qemu_cmd consumes QEMU_LAUNCH_MACHINE_NAME verbatim (consumer-layer guard) ---
# Note: this only proves build_qemu_cmd does not rewrite; prepare-level binary rewrite
# is covered by tests/orchestration/qemu_prepare_launch.sh.
QEMU_LAUNCH_MACHINE_NAME="b865g8-bytedance"
QEMU_LAUNCH_SOC_TYPE="ast2700"
QEMU_LAUNCH_MEM_FLAG="-m 1G"
QEMU_LAUNCH_REQUIRES_PCBIOS="yes"
QEMU_CMD=()
build_qemu_cmd "$image_file" 2222 2443 2623 "" "$serial_log" "$serial_sock"
cmd="${QEMU_CMD[*]}"
assert_contains "declared machine consumed verbatim" "$cmd" "-machine b865g8-bytedance"
```

- [ ] Step 3: 运行并确认通过
- Run: `bash tests/unit/qemu_launch_consumers.sh`
- Expected: 退出码 0；输出含通过汇总（此时 override 函数仍在，但测试已不再调用它）。

- [ ] Step 4: 确认测试不再引用 override 函数
- Run: `! grep -q "apply_binary_machine_override" tests/unit/qemu_launch_consumers.sh`
- Expected: 命令成功（退出码 0，无匹配）。

### Task 2: 新增 prepare 行为测试（红灯）→ 删除 override → 转绿 → 封口

- 目标
  - 先在 `tests/orchestration/qemu_prepare_launch.sh` 新增 prepare-level 行为测试，确认当前红灯（override 仍在时会改写）；再从 `lib/qemu_launch_profile.sh` 删除 `qemu_binary_supports_machine` 与 `qemu_launch_profile_apply_binary_machine_override`、从 `lib/qemu.sh` 删除调用点，使 prepare 测试转绿；最后在 `apply_machine_name` 上方补设计注释、在 `structure.sh` 加结构锁封口。
- Files
  - Modify: `tests/orchestration/qemu_prepare_launch.sh`（新增 prepare-level 行为测试 case）
  - Modify: `lib/qemu_launch_profile.sh`（删两个函数；`apply_machine_name` 上方加注释）
  - Modify: `lib/qemu.sh`（删 `qemu_prepare_launch` 内约 93 行的调用）
  - Modify: `tests/protocol/qemu_launch_profile_structure.sh`（新增一条 `assert_function_not_match` 锁）
- 接口契约
  - Consumes: Task 1 产出的"consumers 测试不再引用 override"；`tests/orchestration/qemu_prepare_launch.sh` 既有的 stub 工具链（`mkfake_bin` / `make_qemu_curl_fake` / `make_bitbake_env_fake`，来自 `tests/lib/qemu_stubs.sh`）
  - Produces: 无 override 的 launch profile；prepare-level 行为测试（覆盖任意形式 binary 改写）；`qemu_prepare_launch` 结构锁封口；`QEMU_LAUNCH_MACHINE_NAME_SOURCE` 取值集合收敛为 `qemuboot` / `bitbake` / `legacy-name`
- 验证范围
  - prepare 行为测试先红后绿；全仓生产代码（`lib/ ob`）无 override / supports 函数残留；两 lib 文件 source 不报错；结构锁新增条目通过；`qemu_launch_consumers.sh` / `soc.sh` / `qemu_launch_profile_structure.sh` / `qemu_prepare_launch.sh` 均通过。

- [ ] Step 1: 确认当前残留引用范围
- Run: `grep -rn "qemu_launch_profile_apply_binary_machine_override\|qemu_binary_supports_machine" lib/ tests/ ob`
- Expected: 命中 4 处（Task 1 已解除 consumers 依赖，故 `tests/unit/qemu_launch_consumers.sh` 不再命中）——`lib/qemu.sh` 的调用点、`lib/qemu_launch_profile.sh` 的 `qemu_binary_supports_machine` 定义、`apply_binary_machine_override` 定义、及其内部对 `qemu_binary_supports_machine` 的调用。参照：Task 1 前 6 处 → Task 1 后 4 处 → Task 2 后 0 处。若仍命中 `tests/unit/qemu_launch_consumers.sh`，说明 Task 1 未完成。

- [ ] Step 2: 新增 prepare-level 行为测试，确认红灯
- Change: 在 `tests/orchestration/qemu_prepare_launch.sh` 现有 romulus case 的 `rm -rf "$TMP" "$DB"`（约 79 行）**之前**插入一个新 case block：

```bash
# ── regression: declared machine not rewritten by binary -machine help (override removed) ──
# MACHINE 带连字符(prefix != MACHINE) + fake binary 的 -machine help 暴露 <prefix>-bmc。
# 原 override 会把声明的 romulus-declared 改写成 romulus-bmc; 删除后 prepare 必须保留声明值。
TMP2="$(mktemp -d)"; DB2="$(mktemp -d)"
O2="$TMP2/openbmc"; B2="$O2/build/romulus-extra"; W2="$TMP2/workspace"; C2="$W2/configs"
mkdir -p "$B2" "$C2/qemu-bin" "$W2/qemu-bin/community"
: > "$O2/setup"
printf 'source_label=community\n' > "$C2/openbmc-source.manifest"
d2="$B2/tmp/deploy/images/romulus-extra"; mkdir -p "$d2"
cat > "$d2/romulus-extra.qemuboot.conf" <<QB
[config_bsp]
qb_machine = -machine romulus-declared
qb_mem = -m 512
qb_system_name = qemu-system-arm
QB
img2="$d2/obmc-phosphor-image-romulus-extra.static.mtd"; : > "$img2"

# fake QEMU binary(arm): -machine help 暴露 romulus-bmc(<prefix>-bmc), 触发原 override 改写路径
cat > "$W2/qemu-bin/community/qemu-system-arm" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == "-machine help" ]]; then
    echo "romulus-bmc OpenBMC Romulus"
    exit 0
fi
echo fake-qemu
STUB
chmod +x "$W2/qemu-bin/community/qemu-system-arm"

mkfake_bin "$DB2" ss
make_qemu_curl_fake "$DB2"
make_bitbake_env_fake "$DB2"

# scoped subshell: 显式切换 prepare 依赖的全部全局目录变量, 与前一个 romulus case 隔离。
# 漏设任一项都会让 prepare 跑到旧 romulus 环境(找不到 romulus-extra.qemuboot.conf / 旧 binary)。
(
    OPENBMC_DIR="$O2"
    BUILD_DIR="$B2"
    WORKSPACE_DIR="$W2"
    CONFIGS_DIR="$C2"
    SOURCE_MANIFEST_FILE="$C2/openbmc-source.manifest"
    MACHINE=romulus-extra
    PATH="$DB2:$PATH"

    qemu_prepare_launch romulus-extra "$img2"
    echo "RC=$?"
    echo "MACHINE_NAME=[$QEMU_LAUNCH_MACHINE_NAME]"
    printf 'QEMU_CMD=[%s]\n' "${QEMU_CMD[*]}"
) > "$TMP2/out" 2>&1
rc2=$?
out2=$(cat "$TMP2/out")

assert_eq "prepare declared-machine case rc" "$rc2" "0"
assert_match "declared machine kept, not rewritten" "$out2" 'MACHINE_NAME=\[romulus-declared\]'
assert_false "QEMU_CMD not rewritten to prefix-bmc" grep -Fq "romulus-bmc" <<< "$out2"

rm -rf "$TMP2" "$DB2"
```

- Run: `bash tests/orchestration/qemu_prepare_launch.sh`
- Expected: **失败（红灯）**——prepare 本身成功（`prepare declared-machine case rc` 断言通过，`RC=0`；override 是 return 0 的 helper，不改变 prepare 的 exit code），但 override 仍在会把 `MACHINE_NAME` 改写成 `romulus-bmc`，导致 `declared machine kept` 与 `not rewritten to prefix-bmc` 两条断言失败。红灯纯粹来自 machine 改写断言，证明 override 改写行为存在——这是本任务要消除的目标。

- [ ] Step 3: 删除 override 函数与 helper，补设计注释
- Change:
  1. 在 `lib/qemu_launch_profile.sh` 的 `qemu_launch_profile_apply_machine_name() {`（约 81 行）**上方**插入设计注释：

     ```bash
     # QEMU machine 名解析链：QB_MACHINE（qemuboot.conf deploy 产物 > bitbake -e）→ 缺失时
     # 走下方 legacy <prefix>-bmc fallback。ob 不依据已安装 binary 支持的机型改写此值——
     # 机型事实源单一化为 recipe 的 QB_MACHINE；binary 不认的值由 QEMU 的 unsupported-machine
     # 直接暴露（fail-loud），不被兜底掩盖。（binary machine override 已移除。）
     ```
  2. 删除 `lib/qemu_launch_profile.sh` 中的 `qemu_binary_supports_machine`（约 104-109 行）与 `qemu_launch_profile_apply_binary_machine_override`（约 111-129 行）两个函数定义整体（含其上方空行）。
  3. 删除 `lib/qemu.sh` 中 `qemu_prepare_launch` 内的 `qemu_launch_profile_apply_binary_machine_override` 调用行（约 93 行），保留其上 `ensure_qemu_binary`（92 行）与其下 `ensure_qemu_firmware`（95 行）。

- [ ] Step 4: 增加结构锁，封口 qemu_prepare_launch 不再做 binary 机型改写
- Change: 在 `tests/protocol/qemu_launch_profile_structure.sh` 现有 `assert_function_not_match` 断言组（约 74-79 行的 build_qemu_cmd / derive_qemu_paths / ensure_qemu_* 系列之后）追加一行：

  ```bash
  assert_function_not_match "qemu_prepare_launch no binary machine rewrite" "$QEMU_SH" qemu_prepare_launch 'apply_binary_machine_override|qemu_binary_supports_machine'
  ```

  说明：只锁这两个已删函数名（防照搬复活），**不**锁 `-machine help` 等行为模式——prepare-level 的"任意形式 binary 改写"已由 `tests/orchestration/qemu_prepare_launch.sh` 的行为测试覆盖（Step 2），结构锁无需重复且避免误伤未来正当的 binary 诊断。遵循本结构锁文件"锁符号名、不锁行为模式"的既有风格（参见 72/74 行锁 `resolve_qb_vars` / `QB_MEM_SIZE_FLAG` 等符号名）。

- [ ] Step 5: 确认 prepare 转绿、生产代码无残留、两文件 source 不报错
- Run: `bash tests/orchestration/qemu_prepare_launch.sh`
- Expected: 退出码 0（红灯转绿——override 已删，`MACHINE_NAME` 保留 `romulus-declared`，`QEMU_CMD` 不含 `romulus-bmc`）。
- Run: `! grep -rn "qemu_launch_profile_apply_binary_machine_override\|qemu_binary_supports_machine" lib/ ob`
- Expected: 命令成功（退出码 0，无输出）——生产代码无残留。注：`tests/protocol/qemu_launch_profile_structure.sh` 的结构锁文本预期保留这两个符号名（封口用），故 grep 只扫 `lib/ ob`。
- Run: `bash -n lib/qemu_launch_profile.sh && bash -n lib/qemu.sh`
- Expected: 退出码 0（语法检查通过）。

- [ ] Step 6: 运行全部受影响测试确认通过
- Run: `bash tests/unit/qemu_launch_consumers.sh && bash tests/unit/soc.sh && bash tests/protocol/qemu_launch_profile_structure.sh && bash tests/orchestration/qemu_prepare_launch.sh`
- Expected: 退出码 0；四个测试均输出通过汇总。`soc.sh` 验证 `apply_machine_name` legacy fallback / nodash 不变；`qemu_launch_consumers.sh` 验证 consumer 层原样消费；`qemu_launch_profile_structure.sh` 验证调用链结构锁 + 新增 override 封口锁；`qemu_prepare_launch.sh` 验证 prepare 端到端不改写。

- [ ] Step 7: checkpoint commit
- Run: `git add lib/qemu_launch_profile.sh lib/qemu.sh tests/unit/qemu_launch_consumers.sh tests/orchestration/qemu_prepare_launch.sh tests/protocol/qemu_launch_profile_structure.sh && git commit -m "refactor(qemu): remove binary machine override from launch profile"`
- Expected: commit 成功。

### Task 3: 配套自检（ob_check + run_all 全量回归）

- 目标
  - 确认改动通过仓库门禁：`extract_funcs` 结构检查、shellcheck baseline、exit-contract、分层测试全量。
- Files
  - 可能 Modify: `tests/.shellcheck-baseline`（仅当 `ob_check.sh` 报 shellcheck 差异且经人工确认为良性时更新）
- 接口契约
  - Consumes: Task 2 产出的无 override lib 与通过的各层测试
  - Produces: 无
- 验证范围
  - `tools/ob_check.sh` 全段通过；`tests/run_all.sh` FAIL=0。

- [ ] Step 1: 跑配套自检
- Run: `tools/ob_check.sh`
- Expected: 退出码 0；`extract_funcs lib 三段全清` / `shellcheck baseline 一致`（或良性差异） / `exit-contract` / `run_all` 各段 `ok`。
- 备注：若 `shellcheck baseline` 段报差异——当前 baseline 无 override 相关条目（已核实 `grep -c` 为 0），预期无差异；若仍报良性差异（行号平移/告警减少），按 `ob_check.sh` 输出的 flat 合成命令重生成 `tests/.shellcheck-baseline`，`git diff` 确认后纳入本任务 commit。不得为绕过门禁而手动篡改 baseline。

- [ ] Step 2: 跑分层全量回归
- Run: `tests/run_all.sh`
- Expected: 退出码 0；输出无 `FAIL` 行，仅 `ok`/`skip`。

- [ ] Step 3: checkpoint commit（仅当有 baseline 更新）
- Run:
  ```bash
  if ! git diff --exit-code -- tests/.shellcheck-baseline; then
      git add tests/.shellcheck-baseline
      git commit -m "chore(shellcheck): regenerate baseline after override removal"
  fi
  ```
- Expected: 无 baseline 差异时 `git diff --exit-code` 成功（退出码 0），不进入 then 块、不产生 commit；有差异时进入 then 块，`git add` + `git commit` 成功。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行（Task 1 → Task 2 → Task 3），不要无声跳步、合并步或改变任务目标。Task 1 必须先于 Task 2——否则 Task 2 Step 1 残留计数不准、且 consumers 测试会引用已删函数。
- Task 2 是红绿一体循环：Step 2 新增 prepare 测试后**预期红灯**（override 仍在），Step 3 删除后才转绿（Step 5）。Step 2 到 Step 5 之间勿跑 `run_all.sh` 全量（prepare 测试预期红），Step 5/Task 3 再跑全量。
- 每完成一个任务，都运行该任务定义的验证。
- 验证命令以 `! grep` / `bash <test>` / `tools/ob_check.sh` 收尾判读退出码，不要用 `echo` / `cp` / `tail` 吞掉返回码。
- "无残留" grep 只扫 `lib/ ob`；`tests/protocol/qemu_launch_profile_structure.sh` 的结构锁文本预期保留两个旧函数名。
- 遇到阻塞、重复失败或计划与仓库现实不符，立即停下说明，不要猜。
- 若当前在 `main` / `master` 且用户未明确同意，开始实现前先确认分支策略。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `bash tests/unit/qemu_launch_consumers.sh && bash tests/unit/soc.sh && bash tests/protocol/qemu_launch_profile_structure.sh && bash tests/orchestration/qemu_prepare_launch.sh && tools/ob_check.sh && tests/run_all.sh`
- Expected: 退出码 0；全部通过。
- Run: `! grep -rn "qemu_launch_profile_apply_binary_machine_override\|qemu_binary_supports_machine" lib/ ob`
- Expected: 命令成功（退出码 0，无输出）——override 能力已从生产代码彻底移除（结构锁文本在 tests/ 预期保留，不扫）。
- Run: `! grep -rn '"qemu-binary"' lib/`
- Expected: 命令成功（退出码 0，无匹配）——`QEMU_LAUNCH_MACHINE_NAME_SOURCE` 不再产生 `qemu-binary` 值（删除 override 后 `lib/qemu_launch_profile.sh` 的 `="qemu-binary"` 赋值已移除）。

## 审阅 Checkpoint

- 计划正文结束。请先审阅这份计划；如无问题，下一步可按计划由普通编码 agent 或人工继续执行。
