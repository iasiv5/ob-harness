# GNU PREMIRRORS 注入 ob init 实施计划

## 目标

让 `ob init` 在生成 `externalsrc-<machine>.inc` 时注入 `PREMIRRORS`（GNU 源重定向到清华 tuna mirror），仅当 local.conf **无 `PREMIRRORS` 赋值行**时注入；并把 DL_DIR / SSTATE_DIR / PREMIRRORS 三个变量的"用户是否配置"判定，从 `-n`（值非空）统一改为 `read_local_conf_var` 的 **exit code**（有赋值行=用户接管，含空值；无赋值行=ob 写默认）。

完成后：国内网络下 `ob build` 不再因 GNU 源（gcc/glibc 等）从 ftpmirror 慢速拉取而卡死；用户可在 local.conf 写 `PREMIRRORS = ""` 禁用、或写自定义值接管。

## 架构快照

- `PREMIRRORS` 注入走**静态写 inc**（`generate_build_config`，`ob` Step 7/8），与 DL_DIR/SSTATE_DIR 同源管理；不走 `BB_ENV_PASSTHROUGH` 动态注入（PREMIRRORS 空值不破坏 bitbake，无需动态）。
- 机制选 PREMIRRORS 而非 GNU_MIRROR 变量覆盖：空值禁用语义安全 + 来源透明（fetcher 层重写，不改 SRC_URI/SPDX 记录）。scheme 只一条 `ftpmirror.gnu.org → tuna`（oe-core 的 `GNU_MIRROR` 就是 ftpmirror，`ftp.gnu.org`/`ftp://` 冗余）。
- 判定统一到 exit code：`read_local_conf_var`（[ob:152-193](../../ob#L152-L193)）已返回正确 exit code（有赋值行 exit 0 含空值，无赋值行 exit 1），不改它，只改 `generate_build_config` 里调用点的 `-n`/`-z` 判断。
- `read_local_conf_var` 是 ob 现有函数（DL_DIR/SSTATE_DIR 已用），PREMIRRORS 复用，无新依赖。

## 输入工件

- 设计决策：[docs/adr/0004-gnu-mirror-via-premirrors.md](../adr/0004-gnu-mirror-via-premirrors.md)、[docs/adr/0005-local-conf-var-detection-exit-code.md](../adr/0005-local-conf-var-detection-exit-code.md)
- 术语：[CONTEXT.md](../../CONTEXT.md) `ob-managed variable`
- 关键代码坐标：`ob:152-193`（read_local_conf_var，不改）、`ob:2714` 起的 `generate_build_config`（改）、`ob:2747-2787`（DL_DIR/SSTATE_DIR 检测+条件写）、`ob:2789` 起的 BB_HASHSERVE 块（PREMIRRORS 插在其前）

## 文件结构与职责

- Create: `tests/protocol/premirrors_injection.sh` — protocol 测试，断言 `generate_build_config` 在四场景下生成的 inc 内容（PREMIRRORS 注入 + exit code 判定）。
- Modify: `ob` — `generate_build_config` 函数：(1) DL_DIR/SSTATE_DIR 检测与条件写从 `-n`/`-z` 改 exit code；(2) 新增 PREMIRRORS 检测与注入段；(3) 注入/跳过时 `info` log。
- 不改：`ob:152-193` `read_local_conf_var`、已落的 ADR/CONTEXT。

## 任务清单

### Task 1: 写 protocol 测试（失败先行）

- 目标：新建 `tests/protocol/premirrors_injection.sh`，覆盖四场景，并在 ob 未改时跑出红色 FAIL（证明测试能捕获未实现）。
- Files
  - Test: `tests/protocol/premirrors_injection.sh`
- 验证范围：测试文件存在；`bash tests/protocol/premirrors_injection.sh` 退出码非 0、`FAIL=N (N>0)`。

- [ ] Step 1: 确认当前状态——测试不存在，且 ob 当前不注入 PREMIRRORS、DL_DIR 用 `-n`/`-z`。
- Run: `test ! -f tests/protocol/premirrors_injection.sh && ! grep -q 'PREMIRRORS' ob && grep -q '\[\[ -z "\$_user_dl_dir" \]\]' ob; echo "rc=$?"`
- Expected: `rc=0`（三条件全成立：测试不存在、ob 无 PREMIRRORS、ob DL_DIR 仍用 `-z` 判定）。

- [ ] Step 2: 写测试文件。
- Create `tests/protocol/premirrors_injection.sh`，内容：

```bash
#!/usr/bin/env bash
# tests/protocol/premirrors_injection.sh — 断言 ob init 注入 PREMIRRORS + local.conf 变量判定用 exit code。
# 覆盖 ADR-0004（PREMIRRORS 注入）与 ADR-0005（exit code 判定，空值=用户接管）。
set -uo pipefail

source "$(dirname "$0")/../lib/ob_loader.sh"   # source ob 函数, $OB; 内部 set +e
set +u   # generate_build_config 可能引用测试未设的全局; 容忍以聚焦 inc 输出断言
source "$(dirname "$0")/../lib/assert.sh"
assert_reset

MACHINE="t"
WORKSPACE_DIR="$(mktemp -d)"
BUILD_DIR="$WORKSPACE_DIR/build"
mkdir -p "$BUILD_DIR/conf"
INC="$BUILD_DIR/conf/externalsrc-$MACHINE.inc"

gen_inc() {
    rm -f "$INC"
    DRY_RUN=0 generate_build_config >/dev/null 2>&1
    cat "$INC" 2>/dev/null
}

# 场景1: local.conf 无 PREMIRRORS/DL_DIR/SSTATE_DIR → ob 注入全部默认
printf 'MACHINE ??= "t"\n' > "$BUILD_DIR/conf/local.conf"
inc=$(gen_inc)
assert_contains "s1 PREMIRRORS injected" "$inc" "mirrors.tuna.tsinghua.edu.cn"
assert_contains "s1 DL_DIR default"       "$inc" 'DL_DIR = "'

# 场景2: local.conf 有自定义 PREMIRRORS → ob 不注入(注释跳过)
printf 'MACHINE ??= "t"\nPREMIRRORS = "https://mirrors.ustc.edu.cn/gnu/"\n' > "$BUILD_DIR/conf/local.conf"
inc=$(gen_inc)
if [[ "$inc" == *"mirrors.tuna.tsinghua.edu.cn"* ]]; then _assert_bad "s2 自定义 PREMIRRORS 时不应注入 tuna"; else _assert_ok "s2 自定义时跳过"; fi

# 场景3: local.conf PREMIRRORS="" (空) → ob 不注入(exit code 判定=用户接管)
printf 'MACHINE ??= "t"\nPREMIRRORS = ""\n' > "$BUILD_DIR/conf/local.conf"
inc=$(gen_inc)
if [[ "$inc" == *"mirrors.tuna.tsinghua.edu.cn"* ]]; then _assert_bad "s3 空值应禁用(被当接管)"; else _assert_ok "s3 空值=禁用"; fi

# 场景4: local.conf DL_DIR="" (空) → ob 不写默认(exit code 判定, 验证三变量统一)
printf 'MACHINE ??= "t"\nDL_DIR = ""\n' > "$BUILD_DIR/conf/local.conf"
inc=$(gen_inc)
if [[ "$inc" == *"$WORKSPACE_DIR/downloads"* ]]; then _assert_bad "s4 空DL_DIR应被尊重(不补默认)"; else _assert_ok "s4 空DL_DIR尊重"; fi

assert_summary
rc=$?
rm -rf "$WORKSPACE_DIR"
exit $rc
```

- 赋可执行权限：`chmod +x tests/protocol/premirrors_injection.sh`

- [ ] Step 3: 运行并确认红色 FAIL。
- Run: `bash tests/protocol/premirrors_injection.sh; echo "exit=$?"`
- Expected: `FAIL=N (N>0)`、退出码非 0。失败应集中在 s1（ob 未注入 PREMIRRORS）、s3（空值被旧逻辑当未设→注入）、s4（DL_DIR 空被 `-z` 当未设→补默认）；s2 可能恰好通过（ob 本就不写 PREMIRRORS）。若测试自身报语法错而非断言 FAIL，先修测试。

### Task 2: ob 的 DL_DIR/SSTATE_DIR 判定改为 exit code

- 目标：把 `generate_build_config` 里 DL_DIR/SSTATE_DIR 的检测与条件写，从 `-n`/`-z`（值非空）改为基于 `read_local_conf_var` 的 exit code（有赋值行=用户接管）。
- Files
  - Modify: `ob`（`generate_build_config`，DL_DIR/SSTATE_DIR 检测段 + 条件写段）
- 验证范围：`bash tests/protocol/premirrors_injection.sh` 中 s4（DL_DIR 空被尊重）与 s1（DL_DIR 默认注入）通过；s1 的 PREMIRRORS 断言、s2/s3 仍 FAIL（下一个 Task 处理）。

- [ ] Step 1: 确认当前 `-z` 判定存在。
- Run: `grep -nE '_user_dl_dir=\$\(read_local_conf_var|\[\[ -z "\$_user_dl_dir" \]\]|\[\[ -n "\$_user_dl_dir" \]\]' ob`
- Expected: 命中检测行（`_user_dl_dir=$(read_local_conf_var ...)`）、`-z` 条件写行、`-n` info log 行。

- [ ] Step 2: 确认 s4 当前 FAIL。
- Run: `bash tests/protocol/premirrors_injection.sh 2>&1 | grep -E 's4|FAIL='`
- Expected: `s4 空DL_DIR应被尊重` 的 FAIL 行。

- [ ] Step 3: 改 `generate_build_config` 的 DL_DIR/SSTATE_DIR 部分。
- Change：把 DL_DIR/SSTATE_DIR 的"检测用户已设"从取值+`-n` 改为 exit code（设一个 `_set` 标志），条件写用 `_set` 判断。

  检测段（原 `_user_dl_dir=$(read_local_conf_var ...)` + `[[ -n ... ]] && info`）替换为：

```bash
    local _user_dl_dir="" _user_dl_set=0
    local _user_sstate_dir="" _user_sstate_set=0
    if read_local_conf_var "$local_conf" "DL_DIR" >/dev/null 2>&1; then
        _user_dl_set=1
        _user_dl_dir=$(read_local_conf_var "$local_conf" "DL_DIR" 2>/dev/null || true)
    fi
    if read_local_conf_var "$local_conf" "SSTATE_DIR" >/dev/null 2>&1; then
        _user_sstate_set=1
        _user_sstate_dir=$(read_local_conf_var "$local_conf" "SSTATE_DIR" 2>/dev/null || true)
    fi
    [[ "$_user_dl_set" -eq 1 ]] && info "DL_DIR set in local.conf (${_user_dl_dir:-<empty>}) — not overriding in .inc"
    [[ "$_user_sstate_set" -eq 1 ]] && info "SSTATE_DIR set in local.conf (${_user_sstate_dir:-<empty>}) — not overriding in .inc"
```

  条件写段（原 `if [[ -z "$_user_dl_dir" ]]; then ... echo DL_DIR=...; else 注释; fi`）替换为：

```bash
        if [[ "$_user_dl_set" -eq 0 ]]; then
            echo "DL_DIR = \"$WORKSPACE_DIR/downloads\""
        else
            echo "# DL_DIR defined in local.conf (${_user_dl_dir:-<empty>}) — not overridden."
        fi
        if [[ "$_user_sstate_set" -eq 0 ]]; then
            echo "SSTATE_DIR = \"$WORKSPACE_DIR/sstate-cache\""
        else
            echo "# SSTATE_DIR defined in local.conf (${_user_sstate_dir:-<empty>}) — not overridden."
        fi
```

- [ ] Step 4: 运行并确认 s4、s1(DL_DIR 部分) 通过。
- Run: `bash tests/protocol/premirrors_injection.sh 2>&1 | tail -8`
- Expected: `s1 DL_DIR default` ok、`s4 空DL_DIR尊重` ok；`s1 PREMIRRORS injected` 仍 FAIL（Task 3 处理），`FAIL=` 仍 >0 但比 Task 1 少。

### Task 3: ob 注入 PREMIRRORS（含 info log）

- 目标：在 `generate_build_config` 的 SSTATE_DIR 条件写块之后、BB_HASHSERVE 块之前，新增 PREMIRRORS 检测与注入段，用 exit code 判定，注入时 `info` log。
- Files
  - Modify: `ob`（`generate_build_config`，SSTATE_DIR 块与 BB_HASHSERVE 块之间）
- 验证范围：`bash tests/protocol/premirrors_injection.sh` 全部通过（`FAIL=0`、退出码 0）。

- [ ] Step 1: 确认 PREMIRRORS 尚未注入、并定位插入点。
- Run: `grep -nE 'PREMIRRORS|BB_HASHSERVE_DB_DIR' ob | head`
- Expected: 无 PREMIRRORS 行；命中 `BB_HASHSERVE_DB_DIR =` 行（PREMIRRORS 段插在它之前）。

- [ ] Step 2: 确认 PREMIRRORS 场景当前 FAIL。
- Run: `bash tests/protocol/premirrors_injection.sh 2>&1 | grep -E 's1 PREMIRRORS|s2|s3|FAIL='`
- Expected: `s1 PREMIRRORS injected` FAIL；s2 可能 ok；s3 FAIL（空值被当未设）。

- [ ] Step 3: 在 SSTATE_DIR 条件写块之后、`echo "BB_HASHSERVE_DB_DIR = ..."` 块之前，插入 PREMIRRORS 段。
- Change：新增下面这段（沿用同函数内 DL_DIR/SSTATE_DIR 的检测+条件写模式与注释风格）：

```bash
        echo ""
        echo "# GNU source mirror acceleration (see ADR-0004). Fetcher tries tuna first;"
        echo "# falls back to upstream ftpmirror on miss. Empty/local.conf-defined PREMIRRORS"
        echo "# = user-managed (see ADR-0005): set PREMIRRORS = \"\" to disable, or your own to customize."
```

  并在生成逻辑里（检测段，紧跟 `_user_sstate_set` 之后）加 PREMIRRORS 检测 + 条件写（紧跟 SSTATE_DIR 条件写之后）：

```bash
    local _user_premirrors_set=0
    if read_local_conf_var "$local_conf" "PREMIRRORS" >/dev/null 2>&1; then
        _user_premirrors_set=1
    fi
    [[ "$_user_premirrors_set" -eq 1 ]] && info "PREMIRRORS set in local.conf — not overriding in .inc"
```

  条件写（紧跟 SSTATE_DIR 条件写 `fi` 之后）：

```bash
        if [[ "$_user_premirrors_set" -eq 0 ]]; then
            info "PREMIRRORS: GNU → tuna (Tsinghua mirror); disable with PREMIRRORS=\"\" in local.conf"
            echo "PREMIRRORS = \"https://ftpmirror.gnu.org/gnu/ https://mirrors.tuna.tsinghua.edu.cn/gnu/\""
        else
            echo "# PREMIRRORS defined in local.conf — not overridden."
        fi
```

- [ ] Step 4: 运行并确认全部通过。
- Run: `bash tests/protocol/premirrors_injection.sh; echo "exit=$?"`
- Expected: 全部 `ok`，`PASS=N FAIL=0`，退出码 0。

- [ ] Step 5: 可选 checkpoint commit。
- Run: `git add ob tests/protocol/premirrors_injection.sh && git commit -m "feat(ob): inject PREMIRRORS (GNU→tuna) + exit-code local.conf detection (ADR-0004/0005)"`
- Expected: commit 成功。

### Task 4: 跑 ob_check.sh 配套自检（最终验证）

- 目标：改 ob 后跑一站式自检，确认结构/函数登记/shellcheck baseline/exit-contract/全测试未回归。
- Files
  - 验证：`tools/ob_check.sh`
- 验证范围：`tools/ob_check.sh` 全绿；新 protocol 测试被 `run_all` 纳入并过。

- [ ] Step 1: 确认 ob 改动已落、protocol 测试单测通过。
- Run: `bash tests/protocol/premirrors_injection.sh > /dev/null 2>&1; echo "rc=$?"`
- Expected: `rc=0`（测试单独通过）。

- [ ] Step 2: 跑 ob_check.sh。
- Run: `bash tools/ob_check.sh`
- Expected: 全绿——extract_funcs（§1-§7 物理分层）、reorder、shellcheck baseline、exit-contract（X/Y/Z）、`run_all`（含新 `premirrors_injection.sh` 的 protocol 层）全部通过。若 shellcheck 报新告警，按 baseline 约定处理（修代码或更新 baseline，遵循 `rules/03_WORKSPACE.md` 对 ob_check 的说明）。

- [ ] Step 3: 确认 exit-contract 未回归（ob 的 0/1/2/3 退出码语义没被本次改动碰到）。
- Run: `bash tools/ob_check.sh 2>&1 | grep -iE 'exit.contract|exit_code' | head`
- Expected: exit-contract 检查通过（无新增违规）。本次改动只在 `generate_build_config` 内改判定逻辑，不碰 `cmd_*` 的 exit，预期不回归。

- [ ] Step 4: 确认改动范围干净（无意外文件/行被改）。
- Run: `git status --short && git diff --stat`
- Expected: 本次代码改动仅 `ob` 与 `tests/protocol/premirrors_injection.sh` 两项（`docs/adr/0004`、`docs/adr/0005`、`CONTEXT.md` 已先行落地，若在同一分支则一并确认其内容正是本计划对应的 PREMIRRORS 决策 + ob-managed variable 术语）。注意：功能正确性已由 protocol 测试（Task 1-3，调真实 `generate_build_config` 于 `DRY_RUN=0` 并断言 inc）覆盖，无需再实跑 `ob init`（那会拉源码，过重；且 `ob init -d` 是 dry-run、`generate_build_config` 在 `DRY_RUN=1` 直接 return 不生成 inc，看不到 PREMIRRORS）。

## 执行纪律

- 开始实现前，先批判性复查整份计划；发现缺项、矛盾、命名不一致或验证命令无效，先修计划再动手。
- 按任务顺序执行，不无声跳步、不合并步。
- 每完成一个任务，运行该任务定义的验证；没通过不算完成。
- 遇阻塞、重复失败或计划与仓库现实不符（如 `generate_build_config` 有未预期的前置依赖导致测试无法独立调用），立即停下说明，不要猜路径或猜命令。
- 若当前在 `main`/`master` 且用户未明确同意，开始实现前先确认是否开分支。
- 全部任务完成后，运行最终验证并输出修改摘要。

## 最终验证

- Run: `bash tests/protocol/premirrors_injection.sh && bash tools/ob_check.sh`
- Expected: protocol 测试 `PASS=N FAIL=0`、退出码 0；`ob_check.sh` 全绿（含新 protocol 测试纳入 run_all）。
- 修改摘要应包含：`ob` 的 `generate_build_config` 改了 DL_DIR/SSTATE_DIR/PREMIRRORS 三处判定（统一 exit code）+ 新增 PREMIRRORS 注入段与 info log；新增 `tests/protocol/premirrors_injection.sh`；ADR-0004/0005 与 CONTEXT.md 术语已先行落地（本计划不改它们）。

## 审阅 Checkpoint

实施计划已写好并保存到 `docs/plans/2026-06-22-premirrors-injection-implementation-plan.md`。请先确认这份计划；如果没问题，下一步可以按计划由普通编码 agent 或人工继续执行。
