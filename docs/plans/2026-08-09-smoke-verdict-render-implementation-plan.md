# ob smoke verdict render 深化实施计划

## 目标

从 `lib/qemu_commands.sh` 的 `cmd_smoke` 抽出 verdict 渲染段为私有 helper `_smoke_render_verdict`（与 `_smoke_probe_*` 同居），把 verdict/bookkeeping 逻辑从「只被 integration（真实 QEMU）覆盖」下沉到 fast 测试层（新增 `tests/unit/smoke_verdict.sh`），并用 ADR 记录「runner/spec 抽取暂缓」决策以防未来循环推荐。

## 架构快照

- `cmd_smoke` 现状：末尾一段 inline verdict 渲染（`# ── α verdict` → `exit 1`）——summary 行 + 失败 breakdown 循环 + α-banner warn + return/exit。这段是纯呈现逻辑，但没有独立 seam，fast 层测不到（`smoke_exit_contract.sh` 只在合并流里验存在性，不验渲染内部 / 不验 stderr 通道）。
- 本次：把该段抽成 `_smoke_render_verdict <total> <passed> <failed_names_ref> <failed_raws_ref> <machine>`，**return 0=all-pass / 1=any-fail**（leaf-pure 风格，不 exit），`cmd_smoke` 收口 `return 0` / `exit 1`。函数落在 `qemu_commands.sh` 内、`_smoke_probe_*` 旁（同属 cmd_smoke 私有呈现胶水族）。
- 不动：`cmd_smoke` 仍在 `qemu_commands.sh` 定义、`smoke_assertions.sh` 仍「只判」、5 段 probe→judge→accumulate 编排维持内联（非同构，runner 暂缓）。

## 全局约束

- **co-location 不变量（S1）**：`cmd_smoke` 必须仍定义在 `lib/qemu_commands.sh`（被 `tests/protocol/smoke_surface.sh (4)` 与 `tests/protocol/smoke_substep_isolation.sh (1)(2)(3a)` 锁定）。本次只加 helper + 改 callsite，不挪文件、不新建 lib 文件、不改 `qemu_commands.sh` header / `CONTEXT.md` `ob smoke` 同族定位 / `rules/03_WORKSPACE.md` 路由。
- **exit 收口（S3）**：`_smoke_render_verdict` 绝不 `exit`，只 `return 0/1`；`exit 1` / `return 0` 留 `cmd_smoke`（exit-seam 独占）。
- **行为保持（双层回归锁）**：(a) Task 2 Step 1 在 `smoke_exit_contract.sh` 新增 callsite verdict 输出锁（`Smoke summary: 5/5` / `4/5`、`Failed assertions (1)`、RAW 块计数），refactor 前后均须绿——证 `cmd_smoke` 接线（total/passed/machine 透传）不变；(b) 既有 protocol 锁：`smoke_exit_contract.sh`（exit 0/1 + 恰好 5 ✓ + α-banner fail 出现/pass 不出现）、`smoke_surface.sh (5)` cmd_smoke body-grep（不引用 `qemu_prepare_launch`/`qemu_execute_launch`、无 `trap`、调 `qemu_instance_is_alive`/`qemu_instance_load`/`PIDFILE_SSH_PORT`）、`smoke_substep_isolation.sh` trio。refactor 后全部必须仍绿。
- **命名**：`_smoke_render_verdict`（`_` 前缀私有，对齐 `_smoke_probe_*`）；测试文件 `tests/unit/smoke_verdict.sh`。
- **通道契约**（见 `lib/util.sh:6-14`：`log`/`info`/`warn`→stdout，`error`/`notice`→stderr）：`_smoke_render_verdict` 的 `echo`（summary/✗/RAW）与 `info`（all-pass 成功行）走 stdout；`error`（`Failed assertions` / failed-for 诊断行）与 `warn` α-banner 走 stderr（α-banner 经 `>&2` 强制，因 `warn` 默认 stdout）。单测按此分通道断言。

## 输入工件

- 设计共识：本会话 `/pick-one-arch-task` → 独立评审（已吸收 F1/F2/F5 + Rec A/C）→ `/grill-with-docs` 三轮确认的决策树（Q1→b 在 qemu_commands.sh；Q2→仅 render；Q3→a return 0/1；Q4→a nameref；Q5→a render 拥有 banner；Q6→加 coverage_matrix smoke 段；Q7→defer-runner ADR；Q8→3 case assert_contains+rc+stderr-banner；Q9→a 文件名）。
- 既有事实依据：`tools/exit_contract.py:79`（`smoke_assertions.sh` leaf-pure，本次不动它）、`tests/lib/ob_loader.sh:10`（`set +e`）、`tests/protocol/smoke_exit_contract.sh:144/155`（banner 存在性已锁）。

## 文件结构与职责

- **Modify** `lib/qemu_commands.sh`：新增 `_smoke_render_verdict`（落在 `_smoke_probe_ssh_tcp` 之后、`cmd_smoke()` 之前的 `_smoke_*` helper 区）；改写 `cmd_smoke` 末尾 verdict 段为 callsite。
- **Test** `tests/unit/smoke_verdict.sh`（新建）：纯函数单测，3 case + α-banner stderr-only 断言。
- **Modify** `tools/coverage_matrix.md`：新增 `## smoke` section。
- **Create** `docs/adr/0023-defer-smoke-assertion-runner.md`：defer-runner 决策记录。
- **Modify** `CONTEXT.md`（1 行交叉引用，mandatory）：`ob smoke` 条目末尾指向 ADR-0023，镜像 ADR-0016 之于 `ob init command intake` 的引用方式——ADR 的目的就是防未来循环推荐，入口引用不可让执行者跳过。
- 稳定边界：`lib/smoke_assertions.sh`（不改）、`cmd_smoke` 的前置 exit-3 路径与 probe→judge 5 段编排（不改）。

## 任务清单

### Task 1: 抽出 `_smoke_render_verdict` helper（TDD red→green）

- 目标：新增 `_smoke_render_verdict` 纯函数并通过 `tests/unit/smoke_verdict.sh` 三 case。
- 涉及文件：Create `tests/unit/smoke_verdict.sh`；Modify `lib/qemu_commands.sh`（加 helper，先不动 cmd_smoke）。
- 验证范围：`bash tests/unit/smoke_verdict.sh` 退出 0（全部 assert 通过）。
- 接口契约：
  - Consumes：`ob_loader.sh` 提供的 `info/error/warn` 与颜色全局（`${GREEN}/${RED}/${NC}`）；`assert.sh` 的 `assert_eq/assert_contains/assert_true/assert_false/assert_summary`。
  - Produces：函数 `_smoke_render_verdict <total> <passed> <failed_names_ref> <failed_raws_ref> <machine>`，`return 0`（all-pass）/ `return 1`（any-fail）；后续 Task 2 消费。

- [ ] **Step 1：写失败单测** `tests/unit/smoke_verdict.sh`：

```bash
#!/usr/bin/env bash
# tests/unit/smoke_verdict.sh — _smoke_render_verdict 单测(unit 层)。
# 纯 verdict 渲染(无 curl/ipmitool/tcp),无 stub。锁 return 0/1 + summary 行 + 失败
# breakdown 计数 + 通道契约。ob_loader 已 set +e(关 errexit)。
#
# 通道契约(见 lib/util.sh: log/info/warn→stdout; error→stderr; α-banner 经 >&2 强制 stderr):
#   stdout = echo summary 行 + ✗ breakdown + RAW 块 + info(all-pass 成功行)
#   stderr = error 诊断行(Failed assertions / failed for) + warn α-banner
source "$(dirname "$0")/../lib/ob_loader.sh"
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

ERR="$(mktemp)"

# --- (1) all-pass: total==passed, 空 failed arrays → return 0, 绿 summary, 无 ✗, 无 banner ---
fn=(); fr=()
rc=9; out=$(_smoke_render_verdict 5 5 fn fr romulus 2>"$ERR"); rc=$?
err="$(cat "$ERR")"
assert_eq    "(1) all-pass return 0"            "$rc" 0
assert_contains "(1) 绿 summary 5/5(stdout)"    "$out" "5/5"
assert_contains "(1) info 成功行带 machine(stdout)" "$out" "romulus"
assert_false "(1) 无 ✗ 行(stdout)"             grep -q "✗" <<<"$out"
assert_false "(1) 无 Failed assertions(stdout)" grep -q "Failed assertions" <<<"$out"
assert_false "(1) 无 α-banner(stdout)"         grep -q "truth-reporter" <<<"$out"
assert_false "(1) 无 α-banner(stderr)"         grep -q "truth-reporter" "$ERR"

# --- (2) all-fail: passed=0, 5 failed → return 1; stdout 红 0/5 + 5✗ + 5RAW; stderr Failed(5) + banner ---
fn=("Redfish root" "Redfish Managers" "SoftwareVersion" "IPMI over LAN" "System ready")
fr=("iface: root"$'\n'"RAW: r1" "iface: mgr"$'\n'"RAW: r2" "iface: swv"$'\n'"RAW: r3" \
    "iface: ipmi"$'\n'"RAW: r4" "iface: ssh"$'\n'"RAW: r5")
rc=9; out=$(_smoke_render_verdict 5 0 fn fr romulus 2>"$ERR"); rc=$?
err="$(cat "$ERR")"
assert_eq    "(2) all-fail return 1"            "$rc" 1
assert_contains "(2) 红 summary 0/5(stdout)"    "$out" "0/5"
assert_contains "(2) Failed assertions (5)(stderr)" "$err" "Failed assertions (5)"
assert_false "(2) Failed assertions 不在 stdout" grep -q "Failed assertions" <<<"$out"
_n=$(grep -cE $'^[[:space:]]*(\033\\[[0-9;]*m)*✗ ' <<<"$out" || true); assert_eq "(2) 恰好 5 ✗ 行(stdout)" "$_n" 5
_n=$(grep -c "RAW response" <<<"$out" || true);    assert_eq "(2) 恰好 5 RAW 块(stdout)" "$_n" 5
assert_true  "(2) α-banner 在 stderr"           grep -q "truth-reporter" "$ERR"
assert_false "(2) α-banner 不在 stdout"         grep -q "truth-reporter" <<<"$out"
assert_contains "(2) failed-for 诊断行(stderr)" "$err" "smoke assertions failed for 'romulus'"
assert_false "(2) failed-for 诊断行不在 stdout" grep -q "smoke assertions failed for" <<<"$out"

# --- (3) mixed: passed=3, 2 failed → return 1; stdout 3/5 + 2✗ + 2RAW; stderr Failed(2) + banner ---
fn=("IPMI over LAN" "System ready")
fr=("iface: ipmi"$'\n'"RAW: ipmi" "iface: ssh"$'\n'"RAW: ssh")
rc=9; out=$(_smoke_render_verdict 5 3 fn fr romulus 2>"$ERR"); rc=$?
err="$(cat "$ERR")"
assert_eq    "(3) mixed return 1"               "$rc" 1
assert_contains "(3) summary 3/5(stdout)"       "$out" "3/5"
assert_contains "(3) Failed assertions (2)(stderr)" "$err" "Failed assertions (2)"
_n=$(grep -cE $'^[[:space:]]*(\033\\[[0-9;]*m)*✗ ' <<<"$out" || true); assert_eq "(3) 恰好 2 ✗ 行(stdout)" "$_n" 2
assert_true  "(3) α-banner 在 stderr"           grep -q "truth-reporter" "$ERR"
assert_contains "(3) failed-for 诊断行(stderr)" "$err" "smoke assertions failed for 'romulus'"

rm -f "$ERR"
assert_summary
```

- [ ] **Step 2：运行并确认失败**（helper 未定义 → 调用返回 127/异常 → assert 失败）。
- Run: `bash tests/unit/smoke_verdict.sh; echo "exit=$?"`
- Expected: 退出非 0，assert_summary 报失败（`_smoke_render_verdict: command not found` 类信号）。

- [ ] **Step 3：在 `lib/qemu_commands.sh` 加 `_smoke_render_verdict`**（插在 `_smoke_probe_ssh_tcp` 函数之后、`cmd_smoke()` 之前的 `_smoke_*` helper 区）：

```bash
# _smoke_render_verdict <total> <passed> <failed_names_ref> <failed_raws_ref> <machine>
#   cmd_smoke 私有 verdict 渲染(leaf-pure 风格: 不 exit, return 0=all-pass / 1=any-fail;
#   exit 收口留 cmd_smoke)。消费 total/passed + failed_names[]/failed_raws[](nameref 只读),
#   打 summary 行 + 失败 breakdown(✗ + RAW) + α-banner(>&2)。
#   前置(lockstep): total/passed/failed_names 由 cmd_smoke 维护——每次 fail 同时 total++ 与
#   failed_names+=, 故 ${#failed_names[@]} == total-passed(本函数不另做 mismatch 校验)。
_smoke_render_verdict() {
    local total="$1" passed="$2"
    local -n _srv_fn="$3"     # failed_names (只读消费)
    local -n _srv_fr="$4"     # failed_raws (只读消费)
    local machine="$5"
    echo ""
    if [[ "$passed" -eq "$total" ]]; then
        echo -e "${GREEN}Smoke summary: $passed/$total assertions passed${NC}"
        info "ob smoke: all smoke assertions passed for '$machine'."
        return 0
    fi
    echo -e "${RED}Smoke summary: $passed/$total assertions passed${NC}"
    echo ""
    error "Failed assertions (${#_srv_fn[@]}):"
    local i
    for (( i=0; i<${#_srv_fn[@]}; i++ )); do
        echo -e "  ${RED}✗ ${_srv_fn[$i]}${NC}"
        echo    "----- RAW response (for localization) -----"
        echo    "${_srv_fr[$i]}"
        echo    "-------------------------------------------"
    done
    echo ""
    error "ob smoke: smoke assertions failed for '$machine' (see ✗ rows + RAW responses above)."
    # α 重申: exit 1 当下向 stderr 喂一行 α 语义, 防 caller 据全局 "1 = broken" 误判 smoke 坏。
    # warn 默认走 stdout, 显式 >&2 落 stderr(不污染 stdout 真相报告)。
    warn "exit 1 here is the α truth-reporter contract: the ✗ rows above report the BMC interface's ACTUAL state, NOT a smoke command failure — read the ✗ rows to see which interface and why (debug the BMC interface, not smoke)." >&2
    return 1
}
```

- Change: 新增 helper；不改 cmd_smoke、不动 5 段编排。
- [ ] **Step 4：运行并确认通过**。
- Run: `bash tests/unit/smoke_verdict.sh; echo "exit=$?"`
- Expected: 退出 0，`assert_summary` 全绿（3 case 的 rc + summary + ✗/RAW 计数 + α-banner stderr-only 全通过）。

### Task 2: 改写 `cmd_smoke` verdict 段为 callsite（行为保持，先加 callsite 锁）

- 目标：先在 `smoke_exit_contract.sh` 加 callsite 级 verdict 输出锁（锁住当前 inline 行为），再用 `_smoke_render_verdict` 替换 `cmd_smoke` 末尾 inline verdict 段（exit/return 收口留 cmd_smoke），最后确认那些锁仍绿——这是「refactor 行为不变」的硬证据。Task 1 的单测证 helper 自身渲染正确，Task 2 的 protocol 锁证 `cmd_smoke` 接线正确（total/passed/machine 透传）。
- 涉及文件：Modify `tests/protocol/smoke_exit_contract.sh`（加 callsite 锁）；Modify `lib/qemu_commands.sh`（`cmd_smoke` 内 `# ── α verdict` 段）。
- 验证范围：callsite 锁 refactor 前后均绿 + smoke 相关全套绿（行为不变 + co-location 不变量不破）。
- 接口契约：
  - Consumes：Task 1 产出的 `_smoke_render_verdict`；`smoke_exit_contract.sh` 现有 (3) all-pass / (4) IPMI-fail 用例（合并 `2>&1` 捕获，stdout+stderr 内容均可见）。
  - Produces：无（末态）。

- [ ] **Step 1：在 `smoke_exit_contract.sh` 加 callsite verdict 输出锁**（TDD：先锁当前 inline 行为）。在现有 (3) all-pass 块（`_check_5` / `assert_false … truth-reporter` 附近）追加一行：

```bash
assert_contains "(3) prints Smoke summary 5/5" "$out" "Smoke summary: 5/5 assertions passed"
assert_contains "(3) all-pass machine passthrough" "$out" "all smoke assertions passed for 'romulus'"
```

在现有 (4) IPMI-fail 块（`assert_true "(4) emits α truth-reporter …"` 附近）追加三行：

```bash
assert_contains "(4) prints Smoke summary 4/5" "$out" "Smoke summary: 4/5 assertions passed"
assert_contains "(4) prints Failed assertions (1)" "$out" "Failed assertions (1)"
assert_contains "(4) fail machine passthrough" "$out" "smoke assertions failed for 'romulus'"
_raw4=$(grep -c "RAW response (for localization)" <<<"$out" || true); assert_eq "(4) exactly 1 RAW block" "$_raw4" 1
```

- Change: 仅加断言，不改 cmd_smoke。锁住 callsite 接线（total=5；passed=5 all-pass / passed=4 IPMI-fail；machine 透传 → summary/failed 行含语义）。合并 `2>&1` 捕获下 stdout+stderr 内容都到 `$out`，故内容断言无需分通道。
- Run: `bash tests/protocol/smoke_exit_contract.sh && echo LOCKS_GREEN`
- Expected: 末行 `LOCKS_GREEN`（新锁对**当前 inline** 代码即通过——证明锁的是真实行为、不是空锁；这是 refactor 后「仍绿 = 行为不变」的基线）。

- [ ] **Step 2：改动前检查**——确认现状 verdict 段锚点。
- Run: `awk '/# ── α verdict/{f=1} f{print} /^}$/{if(f)exit}' lib/qemu_commands.sh`
- Expected: 打印当前 inline verdict 段（`if [[ $passed -eq $total ]]` … `warn … >&2` … `exit 1`），作为替换前的字节基线。

- [ ] **Step 3：替换**——把 `cmd_smoke` 内 verdict 段整段换成下面 callsite。**精确边界**：从注释行 `    # ── α verdict: 纯 truth-reporter。ALL pass → return 0; ANY fail → 打 breakdown + RAW, exit 1 ──` 起，到 `    exit 1                       # smoke 不拥有 QEMU → 无 EXIT trap, 直接 exit 1` 止（含这两行之间的所有行：空 echo、`if passed==total` 分支、红 summary、Failed assertions 循环、末尾 error + warn α-banner + exit 1）。**保留**该 `exit 1` 行之后的 `}`（cmd_smoke 函数闭合）。Step 2 的 awk 输出即待替换的精确原文，逐字对照替换：

```bash
    # ── α verdict: 渲染经 _smoke_render_verdict(leaf-pure 风格, return 0/1); exit 收口留本 cmd_smoke ──
    # 无 --allow-fail / 无 per-machine expected-profile / 无 baseline: 回归检测是 caller 的事(零 per-machine 知识)。
    local _vrc=0
    _smoke_render_verdict "$total" "$passed" failed_names failed_raws "$MACHINE" || _vrc=$?
    case "$_vrc" in
        0) return 0 ;;            # smoke 不拥有 QEMU → 不 teardown, 直接 return
        *) exit 1 ;;              # smoke 不拥有 QEMU → 无 EXIT trap, 直接 exit 1
    esac
```

- Change: 删除 inline summary/breakdown/banner/return/exit 段，改为一次 helper 调用 + `case` 收口。`failed_names`/`failed_raws`/`$total`/`$passed`/`$MACHINE` 均为 cmd_smoke 既有局部量，nameref 直传。

- [ ] **Step 4：跑 smoke 相关全套，确认行为保持 + 不变量不破**。
- Run: `bash tests/protocol/smoke_exit_contract.sh && bash tests/protocol/smoke_surface.sh && bash tests/protocol/smoke_substep_isolation.sh && bash tests/orchestration/smoke_orchestration.sh && bash tests/unit/smoke_verdict.sh && echo ALL_GREEN`
- Expected: 末行 `ALL_GREEN`。重点是 Step 1 新加的 callsite 锁（5/5、4/5、`Failed assertions (1)`、1 RAW）与既有 exit 0/1 + 5 ✓ + banner 存在性 + body-grep 不变量 + trio co-location + probe→judge 链 + render 单测全过——**callsite 锁 refactor 前后都绿 = 行为保持的证据**。

> 不在本任务加 checkpoint commit：commit 仅在用户明确要求时执行（见「执行纪律」）。

### Task 3: 在 `tools/coverage_matrix.md` 注册 `## smoke` section

- 目标：补上 smoke 在 coverage_matrix 的空白（当前无 smoke section），登记新 helper + 既有 judges/probes/cmd_smoke verdict。
- 涉及文件：Modify `tools/coverage_matrix.md`（在 `## deploy-to-qemu` section 之后、`## 横切(通用)` 之前插入）。
- 验证范围：grep 到新 section + cross-check 不报新 out-of-scope。

- [ ] **Step 1：插入 section**（表头沿用既有 `功能点 | 涉及函数 | 覆盖 test | 备注`）：

```markdown
## smoke

| 功能点 | 涉及函数 | 覆盖 test | 备注 |
|---|---|---|---|
| probe-only 命令编排(前置 exit 3 + 读实例端口 + 5 断言 + verdict) | cmd_smoke | protocol/smoke_exit_contract.sh;protocol/smoke_surface.sh;protocol/smoke_substep_isolation.sh;integration/smoke_e2e.sh | exit 函数,radar 低估;exit 0/1/3 + 5 ✓ 行 + α-banner 存在性锁 |
| verdict 渲染(summary + 失败 breakdown + α-banner) | _smoke_render_verdict | unit/smoke_verdict.sh | leaf-pure 风格(return 0/1,不 exit);3 case + 通道锁(error 诊断行/α-banner→stderr,summary/✗/RAW/info→stdout) |
| 断言判定(Redfish root/Managers/SoftwareVersion + IPMI + system-ready) | smoke_judge_redfish_root;smoke_judge_redfish_managers;smoke_judge_redfish_swversion;smoke_judge_ipmi_lan;smoke_judge_system_ready | protocol/smoke_assertions_judgment.sh;orchestration/smoke_orchestration.sh | leaf-pure(lib/smoke_assertions.sh) |
| probe 采集(curl/ipmitool/tcp → nameref outvars) | _smoke_probe_redfish;_smoke_probe_redfish_managers;_smoke_probe_ipmi;_smoke_probe_ssh_tcp;_smoke_tcp_probe;_smoke_wait_ssh_tcp | orchestration/smoke_orchestration.sh | cmd_smoke 私有,PATH-stub 单测 |
```

- [ ] **Step 2：验证 section 落位 + cross-check 一致性**。
- Run: `grep -nE '^## smoke$' tools/coverage_matrix.md && grep -c '_smoke_render_verdict' tools/coverage_matrix.md`
- Expected: 命中 `## smoke` 标题行；`_smoke_render_verdict` 计数 ≥ 1（已登记）。
- Run（可选，informational 非 gate）: `tools/trace_collect.sh 2>/dev/null | python3 tools/coverage_radar.py - --cross-check` （若 trace_collect 跑不了则跳过）
- 注意：`coverage_radar.py` 只解析「涉及函数」列、不校验测试路径字段，故本步仅信息参考、**不作通过判据**；通过判据是上面第一条 grep（section 标题 + 函数登记）。人工确认输出里「matrix 声明但不在 radar 全集」段（中文标题，`coverage_radar.py:88`）不出现 smoke 相关函数（`_smoke_render_verdict` 是 ob+lib 真实函数，应在 radar 全集内、不进该段）。勿 grep `out-of-scope`——summary 行 `coverage_radar.py:74` 恒含该串，会假命中。

### Task 4: 写 defer-runner ADR-0023（+ CONTEXT 交叉引用）

- 目标：记录「smoke 断言 runner/spec 抽取暂缓」决策，防未来 explorer 看到 5 段重复编排循环推荐。
- 涉及文件：Create `docs/adr/0023-defer-smoke-assertion-runner.md`；Modify `CONTEXT.md`（`ob smoke` 条目末尾加一句指向 ADR-0023）。
- 验证范围：ADR 文件存在且格式对齐 ADR-0016；CONTEXT 引用可点。

- [ ] **Step 1：写 ADR** `docs/adr/0023-defer-smoke-assertion-runner.md`：

```markdown
# smoke 断言 runner / spec 抽取暂缓——等第二个 adapter

`cmd_smoke`（[lib/qemu_commands.sh](../../lib/qemu_commands.sh)）内 5 条断言的编排（probe → judge → accumulate(total/passed/failed_*) → RAW 格式化）看似 5 个 adapter，但**非同构**：stanza 3（SoftwareVersion）复用 stanza 2（Managers）的 probe body；stanza 4（IPMI）有条件追加 RAW（"possible cause: …RMCP+/LAN responder"）。`/pick-one-arch-task` + 独立评审 + `/grill-with-docs` 考虑过抽 spec-driven runner（声明每条断言的 probe/judge/name/raw 模板，循环聚合 verdict），**现暂缓**——避免未来 explorer 看到 5 段重复编排、想"为什么 smoke 不抽 runner"而循环推荐。verdict **渲染**（summary + breakdown + α-banner）已单独抽成 `_smoke_render_verdict`（深一层接口 + fast-test 覆盖），runner 仅指 probe→judge→accumulate 的聚合循环。

Status: accepted

## Considered Options

1. **现在抽 runner（拒绝，现阶段）** —— 5 条非同构 → spec 须表达 probe 共享（swversion 借 managers body）与条件 RAW 分支（IPMI cause），spec interface 复杂度 ≈ inline 5 段，deletion test fail（spec 自己变成复杂度而非集中它）。当前仅 1 个 caller（`cmd_smoke`），无第二个 adapter 驱动；codebase-design「one adapter = hypothetical seam, two = real」未满足。

2. **暂缓（接受）** —— 先抽 `_smoke_render_verdict`（纯 verdict 渲染，return 0/1，fast-test 覆盖）拿 testability 收益；5 段 probe→judge→accumulate→RAW 编排维持内联（非同构部分）。runner 留第二个 adapter 出现时再 design-it-twice。

3. **永不抽 runner（拒绝）** —— 太绝对。第二个 target adapter（如真机 BMC target）或第 6 条断言出现时 runner 收益可能成立，保留重开口子（见 Consequences 触发条件）。

## Consequences

- `cmd_smoke` 内 5 段 probe→judge→accumulate→RAW 编排维持**内联**；`_smoke_render_verdict` 已抽出 verdict 渲染（见 `tests/unit/smoke_verdict.sh`）。
- **重新评估触发条件**（任一成立即重开本 ADR）：
  - 出现**第 6 条断言或新的 probe/judge 类型**（如 PLDM、HTTPS）——更多同形断言累积，spec 的 dedup 收益开始可衡量。
  - 出现**第二个 target adapter**（如真机 BMC target，不再只是 QEMU PID-file 端口模型）——codebase-design「two adapters = real seam」满足，spec 表达力 vs interface 复杂度的取舍才有第二条 driver 可判（与本 ADR 主论点对齐）。
  - 5 段编排**进入高频改动区**（反复改 → dedup 收益出现）。
- 未来 explorer 看到 `cmd_smoke` 内 5 段重复编排、未抽 runner，**不应视为待办疏漏**：见本 ADR。
- 可逆性：本 ADR 是判断记录，无强制代码约束；前提改变时直接重开评审，无需"撤销"。
```

- [ ] **Step 1b：验证 ADR 落位 + 格式**。
- Run: `test -f docs/adr/0023-defer-smoke-assertion-runner.md && grep -q '^Status: accepted' docs/adr/0023-defer-smoke-assertion-runner.md && grep -q '^## Considered Options' docs/adr/0023-defer-smoke-assertion-runner.md && echo ADR_OK`
- Expected: 末行 `ADR_OK`（文件存在 + 含 Status / Considered Options 段，对齐 ADR-0016 骨架）。

- [ ] **Step 2：CONTEXT 交叉引用**——在 `CONTEXT.md` `**ob smoke**:` 条目末尾追加一句（镜像 ADR-0016 之于 `ob init command intake` 的引用方式）：
- Change: 追加 `runner/spec 抽取暂缓（非同构 5 段，等第二个 adapter），见 [ADR-0023](docs/adr/0023-defer-smoke-assertion-runner.md)。`
- Run: `grep -n "ADR-0023" CONTEXT.md`
- Expected: 命中 1 行（`ob smoke` 条目内）。

## 执行纪律

- 开始实现前先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划。
- 按任务顺序执行，不无声跳步、合并步或改目标。
- 每完成一个任务，运行该任务的验证命令确认通过再进下一个。
- 遇阻塞、重复失败或计划与仓库现实不符，立即停下说明，不猜。
- 若当前在 `main`/`master` 且用户未明确同意，开始实现前先确认（当前分支 `main`）。
- commit 仅在用户明确要求时执行；本计划不设自动 checkpoint commit（Task 流程中无 commit 步骤）。
- 全部任务完成后运行最终验证并输出修改摘要。

## 最终验证

- Run: `tools/ob_check.sh`（一站式自检：结构 / 函数登记 / know-how TL;DR 门禁 / shellcheck baseline / exit-contract / run_all）
- Expected: 全绿（含新增 `tests/unit/smoke_verdict.sh` 进 run_all 默认 .sh 套件、`exit_contract` 对 `qemu_commands.sh` 仍 exit-seam 判定不变、`_smoke_render_verdict` 不在 leaf-pure basename 故无纯度约束）。
- Run: `bash tests/run_all.sh`（默认 protocol/unit/orchestration .sh 子集）
- Expected: 全绿，`smoke_verdict.sh` 计入 unit 层、既有 smoke 测试无回归。
- 输出修改摘要：列出 4 个改动文件 + 1 个新建测试 + 1 个新建 ADR + 验证结果。

## 审阅 Checkpoint

- 计划正文结束。审阅通过前不进入实现。
